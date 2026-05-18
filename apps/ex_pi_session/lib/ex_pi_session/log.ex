defmodule ExPiSession.Log do
  @moduledoc """
  Public API for session persistence and replay.
  """

  alias ExPiSession.Storage.JsonlFile
  alias ExPiAgent.Message

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
  Replays messages from the session log.
  """
  def replay(storage_id, storage_mod \\ JsonlFile) do
    case storage_mod.read(storage_id) do
      {:ok, entries} ->
        # Find the last compaction if any
        compaction =
          entries
          |> Enum.filter(fn e -> e["type"] == "compaction" end)
          |> List.last()

        messages =
          if compaction do
            # Filter messages before compaction, but keep ones after firstKeptId
            first_kept_id = compaction["firstKeptId"]

            # Convert compaction to a summary message
            summary_msg = reconstruct_compaction(compaction)

            # Get messages after compaction, or ones that should be kept
            kept_messages =
              entries
              |> Enum.drop_while(fn e ->
                e["id"] != first_kept_id and
                  (is_nil(e["message"]) or e["message"]["id"] != first_kept_id)
              end)
              |> Enum.filter(fn e -> e["type"] == "message" end)
              |> Enum.map(&reconstruct_message/1)

            [summary_msg | kept_messages]
          else
            entries
            |> Enum.filter(fn entry -> entry["type"] == "message" end)
            |> Enum.map(&reconstruct_message/1)
          end

        {:ok, messages}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Persists an ExPiAgent event to the log.
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

        # Write prefix + new header to target
        File.rm(target_storage_id)

        Enum.each(prefix, fn entry ->
          storage_mod.append(target_storage_id, entry)
        end)

        storage_mod.append(target_storage_id, new_header)
        {:ok, new_session_id}

      _ ->
        {:error, "Could not fork session"}
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

  defp reconstruct_message(entry) do
    data = entry["message"]

    # 1. Map top-level keys to atoms
    atom_data =
      for {k, v} <- data, into: %{} do
        {String.to_atom(k), v}
      end

    # 2. Fix specific fields that should be atoms
    atom_data =
      atom_data
      |> fix_atom_field(:role)
      |> fix_atom_field(:stop_reason)
      |> fix_atom_field(:level)
      |> fix_atom_field(:status_type)

    # 3. Handle nested content if it's a list of maps
    atom_data = Map.update(atom_data, :content, nil, &fix_content/1)

    # 4. Handle usage map
    atom_data = Map.update(atom_data, :usage, nil, &fix_usage/1)

    struct(Message, atom_data)
  end

  defp reconstruct_compaction(entry) do
    {:ok, dt, _} = DateTime.from_iso8601(entry["timestamp"])

    %Message{
      role: :compaction_summary,
      content: entry["summary"],
      timestamp: DateTime.to_unix(dt, :millisecond),
      id: entry["id"]
    }
  end

  defp fix_atom_field(map, field) do
    case Map.get(map, field) do
      nil -> map
      val when is_binary(val) -> Map.put(map, field, String.to_atom(val))
      _ -> map
    end
  end

  defp fix_content(content) when is_list(content) do
    Enum.map(content, fn
      item when is_map(item) ->
        for {k, v} <- item, into: %{} do
          {String.to_atom(k), v}
        end
        |> Map.update(:type, nil, fn
          nil -> nil
          type -> String.to_atom(type)
        end)

      item ->
        item
    end)
  end

  defp fix_content(content), do: content

  defp fix_usage(nil), do: nil

  defp fix_usage(usage) when is_map(usage) do
    for {k, v} <- usage, into: %{} do
      case k do
        "cost" -> {:cost, fix_cost(v)}
        _ -> {String.to_atom(k), v}
      end
    end
  end

  defp fix_cost(nil), do: nil

  defp fix_cost(cost) when is_map(cost) do
    for {k, v} <- cost, into: %{} do
      {String.to_atom(k), v}
    end
  end
end
