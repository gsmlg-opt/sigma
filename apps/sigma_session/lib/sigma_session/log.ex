defmodule Sigma.Session.Log do
  @moduledoc """
  Public API for session persistence and replay.
  """

  alias Sigma.Session.{EntryEncoder, Journal, Storage.JsonlFile}
  alias Sigma.Session.Journal.Index

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

  @doc "Returns bounded session summaries without replaying complete journals."
  def list_session_summaries(dir, opts \\ []) do
    Sigma.Session.Operations.list_summaries(dir, opts)
  end

  @doc "Publishes a stable-length machine-readable session dump."
  def dump(storage_id, output_path, opts \\ []) do
    Sigma.Session.Operations.dump(storage_id, output_path, opts)
  end

  @doc "Publishes a stable-length Markdown export of the active branch."
  def export(storage_id, output_path, opts \\ []) do
    Sigma.Session.Operations.export(storage_id, output_path, opts)
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

      :ignored ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Ensures an empty journal has a valid session header before its first state change.
  """
  def ensure_session_header(storage_id, cwd, storage_mod \\ JsonlFile) do
    with :ok <- validate_session_cwd(cwd),
         {:ok, snapshot} <- mutation_snapshot(storage_id, storage_mod) do
      case snapshot do
        %{header: header} when is_map(header) ->
          :ok

        %{header: nil, diagnostics: []} ->
          append_session_header(storage_id, cwd, storage_mod)

        %{header: nil, diagnostics: diagnostics} ->
          {:error, {:invalid_journal, diagnostics}}
      end
    end
  end

  @doc """
  Appends the selected provider and model to the active journal branch.
  """
  def append_model_change(storage_id, provider_id, model_id, storage_mod \\ JsonlFile) do
    with :ok <- validate_model_change_id(provider_id, :provider_id),
         :ok <- validate_model_change_id(model_id, :model_id),
         {:ok, snapshot} <- mutation_snapshot(storage_id, storage_mod),
         :ok <- validate_model_change_snapshot(snapshot) do
      {:ok, entry} =
        EntryEncoder.encode(
          {:model_change, provider_id, model_id},
          snapshot.active_leaf_id,
          true
        )

      case storage_mod.append(storage_id, entry) do
        :ok -> {:ok, entry["id"]}
        {:error, reason} -> {:error, {:storage_append_failed, reason}}
        other -> {:error, {:storage_append_failed, other}}
      end
    end
  end

  defp validate_session_cwd(cwd) when is_binary(cwd) and cwd != "", do: :ok

  defp validate_session_cwd(_cwd),
    do: {:error, {:invalid_session_header, :cwd}}

  defp append_session_header(storage_id, cwd, storage_mod) do
    with {:ok, header} <- EntryEncoder.encode({:agent_start, cwd}, nil, false) do
      case storage_mod.append(storage_id, header) do
        :ok -> :ok
        {:error, reason} -> {:error, {:storage_append_failed, reason}}
        other -> {:error, {:storage_append_failed, other}}
      end
    end
  end

  defp validate_model_change_id(value, _field) when is_binary(value) and value != "", do: :ok

  defp validate_model_change_id(_value, field),
    do: {:error, {:invalid_model_change, field}}

  defp mutation_snapshot(storage_id, storage_mod) do
    case snapshot(storage_id, [], storage_mod) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, reason} -> {:error, {:storage_read_failed, reason}}
    end
  end

  defp validate_model_change_snapshot(%{header: nil}),
    do: {:error, {:invalid_journal, :missing_session_header}}

  defp validate_model_change_snapshot(%{diagnostics: diagnostics}) do
    case Enum.filter(diagnostics, &mutation_blocking_diagnostic?/1) do
      [] -> :ok
      blocking -> {:error, {:invalid_journal, blocking}}
    end
  end

  defp mutation_blocking_diagnostic?(%{kind: :invalid_payload}), do: false
  defp mutation_blocking_diagnostic?(_diagnostic), do: true

  @doc """
  Forks a session at the given index.
  """
  def fork(source_storage_id, target_storage_id, message_count, cwd, storage_mod \\ JsonlFile)

  def fork(source_storage_id, target_storage_id, message_count, cwd, storage_mod)
      when is_integer(message_count) and message_count >= 0 do
    with {:ok, entries, storage_diagnostics} <- read_entries(source_storage_id, storage_mod),
         {:ok, index} <- fork_index(entries, storage_diagnostics),
         {:ok, nodes} <- branch_for_message_count(index, message_count),
         {:ok, header} <- fresh_fork_header(index.header, cwd),
         :ok <-
           write_fork_entries(
             target_storage_id,
             [header | Enum.map(nodes, & &1.entry)],
             storage_mod
           ) do
      {:ok, header["id"]}
    end
  end

  def fork(_source_storage_id, _target_storage_id, _message_count, _cwd, _storage_mod),
    do: {:error, :invalid_message_count}

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
    with {:ok, entries, storage_diagnostics} <- read_entries(source_storage_id, storage_mod),
         {:ok, index} <- fork_index(entries, storage_diagnostics),
         {:ok, nodes} <- branch_for_message(index, message_id),
         {:ok, header} <- fresh_fork_header(index.header, cwd),
         :ok <-
           write_fork_entries(
             target_storage_id,
             [header | Enum.map(nodes, & &1.entry)],
             storage_mod
           ) do
      {:ok, header["id"]}
    end
  end

  defp fork_index(entries, storage_diagnostics) do
    index = Index.build(entries)

    cond do
      is_nil(index.header) ->
        {:error, {:invalid_journal, :missing_session_header}}

      true ->
        {:ok, %{index | diagnostics: storage_diagnostics ++ index.diagnostics}}
    end
  end

  defp branch_for_message(index, :all) do
    case Index.path(index, :latest) do
      {:ok, {_leaf_id, nodes}} -> {:ok, nodes}
      {:error, _reason} = error -> error
    end
  end

  defp branch_for_message(index, message_id) when is_binary(message_id) do
    matches =
      Enum.filter(index.ordered, fn node ->
        get_in(node, [:entry, "message", "id"]) == message_id
      end)

    case matches do
      [] ->
        {:error, :message_not_found}

      [%{entry: %{"id" => entry_id}}] ->
        branch_for_entry(index, entry_id)

      [_first, _second | _rest] ->
        {:error, :ambiguous_message_id}
    end
  end

  defp branch_for_message(_index, _message_id), do: {:error, :message_not_found}

  defp branch_for_message_count(_index, 0), do: {:ok, []}

  defp branch_for_message_count(index, message_count) do
    with {:ok, {_leaf_id, nodes}} <- Index.path(index, :latest) do
      message_nodes = Enum.filter(nodes, &match?(%{entry: %{"type" => "message"}}, &1))

      case Enum.at(message_nodes, message_count - 1) do
        nil -> {:ok, nodes}
        %{entry: %{"id" => entry_id}} -> branch_for_entry(index, entry_id)
      end
    end
  end

  defp branch_for_entry(index, entry_id) do
    case Index.path(index, entry_id) do
      {:ok, {_leaf_id, nodes}} -> {:ok, nodes}
      {:error, _reason} = error -> error
    end
  end

  defp fresh_fork_header(source_header, cwd) do
    with {:ok, header} <- EntryEncoder.encode({:agent_start, cwd}, nil, false) do
      {:ok, Map.put(header, "parentSession", source_header["id"])}
    end
  end

  @doc """
  Appends a compaction entry to the log.
  """
  def compact(storage_id, summary, first_kept_id, storage_mod \\ JsonlFile) do
    summary_message = %{content: summary}

    with {:ok, snapshot} <- mutation_snapshot(storage_id, storage_mod),
         :ok <- validate_model_change_snapshot(snapshot),
         {:ok, entry} <-
           EntryEncoder.encode(
             {:compact, summary_message,
              Map.get(snapshot.message_entry_ids, first_kept_id, first_kept_id)},
             snapshot.active_leaf_id,
             is_map(snapshot.header)
           ) do
      storage_mod.append(storage_id, entry)
    end
  end

  defp event_to_entry(storage_id, event, storage_mod) do
    case event do
      {type, _rest} when type in [:agent_start, :message_end] ->
        encode_event_from_snapshot(storage_id, event, storage_mod)

      {:compact, _summary_msg, _first_kept_id} ->
        encode_event_from_snapshot(storage_id, event, storage_mod)

      _ ->
        :ignored
    end
  end

  defp encode_event_from_snapshot(storage_id, event, storage_mod) do
    with {:ok, snapshot} <- mutation_snapshot(storage_id, storage_mod),
         :ok <- validate_compatible_append_snapshot(snapshot),
         result <-
           EntryEncoder.encode(
             normalize_compatible_event(event, snapshot),
             snapshot.active_leaf_id,
             is_map(snapshot.header)
           ) do
      result
    end
  end

  defp normalize_compatible_event({:compact, summary, first_kept_id}, snapshot) do
    {:compact, summary, Map.get(snapshot.message_entry_ids, first_kept_id, first_kept_id)}
  end

  defp normalize_compatible_event(event, _snapshot), do: event

  defp validate_compatible_append_snapshot(%{header: nil, diagnostics: diagnostics}) do
    blocking =
      Enum.reject(diagnostics, fn
        %{kind: :invalid_payload} -> true
        %{kind: :invalid_header, reason: :missing_header} -> true
        _diagnostic -> false
      end)

    if blocking == [], do: :ok, else: {:error, {:invalid_journal, blocking}}
  end

  defp validate_compatible_append_snapshot(snapshot), do: validate_model_change_snapshot(snapshot)

end
