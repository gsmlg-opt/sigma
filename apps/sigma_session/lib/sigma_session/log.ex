defmodule Sigma.Session.Log do
  @moduledoc """
  Public API for session persistence and replay.
  """

  alias Sigma.Session.{Journal, Storage.JsonlFile}

  @doc """
  Lists all session files in the given directory.
  """
  def list_sessions(dir) do
    if File.dir?(dir) do
      files =
        dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.sort_by(
          fn file ->
            case File.stat(Path.join(dir, file)) do
              {:ok, stat} -> stat.mtime
              _ -> {{0, 0, 0}, {0, 0, 0}}
            end
          end,
          :desc
        )
        |> Enum.map(&Path.rootname/1)

      {:ok, files}
    else
      {:ok, []}
    end
  end

  @doc """
  Replays model-facing messages from the latest valid journal branch.
  """
  def replay(storage_id, storage_mod \\ JsonlFile) do
    with {:ok, snapshot} <- snapshot(storage_id, [], storage_mod) do
      {:ok, snapshot.messages}
    end
  end

  @doc """
  Reads and reduces a session journal into a deterministic snapshot.
  """
  def snapshot(storage_id, opts \\ [], storage_mod \\ JsonlFile) do
    with {:ok, entries, storage_diagnostics} <- read_entries(storage_id, storage_mod) do
      journal_opts =
        Keyword.update(opts, :diagnostics, storage_diagnostics, fn existing ->
          storage_diagnostics ++ existing
        end)

      Journal.replay(entries, journal_opts)
    end
  end

  defp read_entries(storage_id, storage_mod) do
    if Code.ensure_loaded?(storage_mod) and
         function_exported?(storage_mod, :read_with_diagnostics, 1) do
      storage_mod.read_with_diagnostics(storage_id)
    else
      with {:ok, entries} <- storage_mod.read(storage_id) do
        {:ok, entries, []}
      end
    end
  end

  @doc """
  Persists an Sigma.Agent event to the log.
  """
  def persist_event(storage_id, event, storage_mod \\ JsonlFile) do
    case event_to_entry(storage_id, event, storage_mod) do
      {:ok, entry} ->
        storage_mod.append(storage_id, entry)

      {:ignore} ->
        :ok
    end
  end

  @doc """
  Forks a session at the given index.
  """
  def fork(source_storage_id, target_storage_id, message_count, cwd, storage_mod \\ JsonlFile) do
    case storage_mod.read(source_storage_id) do
      {:ok, entries} ->
        # Take all non-message entries plus up to message_count message entries,
        # preserving order. This correctly skips compaction and other entry types.
        prefix = take_through_nth_message(entries, message_count)

        # Find the session header to get the parent ID
        parent_header = Enum.find(entries, fn e -> e["type"] == "session" end)
        parent_id = if parent_header, do: parent_header["id"], else: nil

        new_session_id = generate_session_id()

        new_header = %{
          "type" => "session",
          "version" => 3,
          "id" => new_session_id,
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "cwd" => cwd,
          "parentSession" => parent_id
        }

        case write_fork_entries(target_storage_id, prefix ++ [new_header], storage_mod) do
          :ok -> {:ok, new_session_id}
          {:error, _reason} = error -> error
        end

      _ ->
        {:error, "Could not fork session"}
    end
  end

  defp write_fork_entries(target_storage_id, entries, storage_mod) do
    with :ok <- ensure_absent(target_storage_id),
         {:ok, temp_storage_id} <- unused_temp_storage_id(target_storage_id) do
      case append_entries(temp_storage_id, entries, storage_mod) do
        :ok ->
          publish_temp_storage(temp_storage_id, target_storage_id)

        {:error, _reason} = error ->
          rm_optional(temp_storage_id)
          error
      end
    end
  end

  defp append_entries(temp_storage_id, entries, storage_mod) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case storage_mod.append(temp_storage_id, entry) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
        other -> {:halt, {:error, other}}
      end
    end)
  end

  defp publish_temp_storage(temp_storage_id, target_storage_id) do
    case File.ln(temp_storage_id, target_storage_id) do
      :ok ->
        rm_optional(temp_storage_id)
        :ok

      {:error, :eexist} ->
        rm_optional(temp_storage_id)
        {:error, :already_exists}

      {:error, reason} ->
        rm_optional(temp_storage_id)
        {:error, reason}
    end
  end

  defp unused_temp_storage_id(target_storage_id, attempts \\ 8)

  defp unused_temp_storage_id(_target_storage_id, 0), do: {:error, :eexist}

  defp unused_temp_storage_id(target_storage_id, attempts) do
    temp_storage_id = temp_storage_id(target_storage_id)

    case ensure_absent(temp_storage_id) do
      :ok -> {:ok, temp_storage_id}
      {:error, :already_exists} -> unused_temp_storage_id(target_storage_id, attempts - 1)
      {:error, _reason} = error -> error
    end
  end

  defp temp_storage_id(target_storage_id) do
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    Path.join(
      Path.dirname(target_storage_id),
      ".#{Path.basename(target_storage_id)}.#{suffix}.tmp"
    )
  end

  defp ensure_absent(path) do
    case File.lstat(path) do
      {:ok, _stat} -> {:error, :already_exists}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp rm_optional(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Forks a session at the message with the given ID (inclusive), or forks all messages
  when `:all` is passed as the message_id.
  """
  def fork_at_message(
        source_storage_id,
        target_storage_id,
        message_id,
        cwd,
        storage_mod \\ JsonlFile
      ) do
    case storage_mod.read(source_storage_id) do
      {:ok, entries} ->
        msg_entries = Enum.filter(entries, fn e -> e["type"] == "message" end)

        count =
          case message_id do
            :all ->
              length(msg_entries)

            id ->
              msg_entries
              |> Enum.take_while(fn e -> get_in(e, ["message", "id"]) != id end)
              |> length()
              |> Kernel.+(1)
          end

        fork(source_storage_id, target_storage_id, count, cwd, storage_mod)

      _ ->
        {:error, "Could not fork session"}
    end
  end

  @doc """
  Appends a compaction entry to the log.
  """
  def compact(storage_id, summary, first_kept_id, storage_mod \\ JsonlFile) do
    parent_id =
      case storage_mod.read(storage_id) do
        {:ok, entries} -> find_leaf_id(entries)
        _ -> nil
      end

    entry = %{
      "type" => "compaction",
      "id" => generate_short_id(),
      "parentId" => parent_id,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "summary" => summary,
      "firstKeptId" => first_kept_id
    }

    storage_mod.append(storage_id, entry)
  end

  defp event_to_entry(storage_id, event, storage_mod) do
    case event do
      {:message_end, message} ->
        # We need parent_id. For now we read the storage to find the last entry.
        parent_id =
          case storage_mod.read(storage_id) do
            {:ok, entries} -> find_leaf_id(entries)
            _ -> nil
          end

        entry = %{
          "type" => "message",
          "id" => generate_short_id(),
          "parentId" => parent_id,
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "message" => message_to_map(message)
        }

        {:ok, entry}

      {:compact, summary_msg, first_kept_id} ->
        parent_id =
          case storage_mod.read(storage_id) do
            {:ok, entries} -> find_leaf_id(entries)
            _ -> nil
          end

        entry = %{
          "type" => "compaction",
          "id" => generate_short_id(),
          "parentId" => parent_id,
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "summary" => summary_msg.content,
          "firstKeptId" => first_kept_id
        }

        {:ok, entry}

      {:agent_start, cwd} ->
        case storage_mod.read(storage_id) do
          {:ok, entries} ->
            if Enum.any?(entries, fn e -> e["type"] == "session" end) do
              {:ignore}
            else
              header = %{
                "type" => "session",
                "version" => 3,
                "id" => generate_session_id(),
                "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
                "cwd" => cwd
              }

              {:ok, header}
            end

          _ ->
            {:ignore}
        end

      _ ->
        {:ignore}
    end
  end

  defp take_through_nth_message(entries, n) do
    {prefix, _} =
      Enum.reduce(entries, {[], 0}, fn entry, {acc, msg_count} ->
        if msg_count >= n do
          {acc, msg_count}
        else
          new_count = if entry["type"] == "message", do: msg_count + 1, else: msg_count
          {[entry | acc], new_count}
        end
      end)

    Enum.reverse(prefix)
  end

  defp find_leaf_id(entries) do
    entries
    |> Enum.reverse()
    |> Enum.find(fn e -> e["type"] != "session" end)
    |> case do
      nil -> nil
      entry -> entry["id"]
    end
  end

  defp generate_short_id() do
    :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
  end

  defp generate_session_id() do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp message_to_map(message) do
    message
    |> Map.from_struct()
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
  end
end
