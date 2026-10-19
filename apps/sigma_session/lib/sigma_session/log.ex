defmodule Sigma.Session.Log do
  @moduledoc """
  Public API for session persistence and replay.
  """

  alias Sigma.Session.{EntryDecoder, EntryEncoder, Journal, Storage.JsonlFile}
  alias Sigma.Session.Journal.Index

  @default_branch_summary_length 160
  @max_branch_summary_length 500

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

  @doc "Returns durable operation completion records without replaying them as messages."
  def operation_results(storage_id, storage_mod \\ JsonlFile) do
    with {:ok, entries, _diagnostics} <- read_entries(storage_id, storage_mod) do
      {:ok,
       entries
       |> Enum.filter(&match?(%{"type" => "metrics", "fact" => "operation_finished"}, &1))
       |> Enum.reduce([], fn entry, acc ->
         case EntryDecoder.metrics(entry) do
           {:ok, {:operation_finished, attrs}} -> [normalize_operation_record(attrs) | acc]
           _ -> acc
         end
       end)
       |> Enum.reverse()}
    end
  end

  @doc "Returns durable operation starts that have no terminal completion record."
  def operation_interrupted?(storage_id, operation_id),
    do: operation_interrupted?(storage_id, operation_id, JsonlFile)

  def operation_interrupted?(storage_id, operation_id, storage_mod) do
    operation_interrupted?(storage_id, operation_id, nil, storage_mod)
  end

  def operation_interrupted?(storage_id, operation_id, expected_fingerprint, storage_mod) do
    if is_binary(operation_id) and operation_id != "" do
      with {:ok, entries, _diagnostics} <- read_entries(storage_id, storage_mod) do
        starts =
          entries
          |> Enum.filter(&match?(%{"type" => "metrics", "fact" => "operation_started"}, &1))
          |> Enum.filter(fn entry ->
            case EntryDecoder.metrics(entry) do
              {:ok, {:operation_started, attrs}} ->
                (attrs[:operation_id] || attrs["operation_id"]) == operation_id

              _ ->
                false
            end
          end)

        completed =
          entries
          |> Enum.filter(&match?(%{"type" => "metrics", "fact" => "operation_finished"}, &1))
          |> Enum.any?(fn entry ->
            case EntryDecoder.metrics(entry) do
              {:ok, {:operation_finished, attrs}} ->
                (attrs[:operation_id] || attrs["operation_id"]) == operation_id

              _ ->
                false
            end
          end)

        matching_start? =
          is_nil(expected_fingerprint) or
            Enum.any?(starts, fn entry ->
              case EntryDecoder.metrics(entry) do
                {:ok, {:operation_started, attrs}} ->
                  (attrs[:fingerprint] || attrs["fingerprint"]) == expected_fingerprint

                _ ->
                  false
              end
            end)

        cond do
          completed -> {:ok, false}
          starts == [] -> {:ok, false}
          matching_start? -> {:ok, true}
          true -> {:error, :operation_conflict}
        end
      end
    else
      {:ok, false}
    end
  end

  defp normalize_operation_record(attrs) do
    Map.new(attrs, fn {key, value} ->
      {normalize_operation_key(key), normalize_operation_value(value)}
    end)
  end

  defp normalize_operation_key("operation_id"), do: :operation_id
  defp normalize_operation_key("operation"), do: :operation
  defp normalize_operation_key("source_session_id"), do: :source_session_id
  defp normalize_operation_key("status"), do: :status
  defp normalize_operation_key("result"), do: :result
  defp normalize_operation_key("error"), do: :error
  defp normalize_operation_key(key), do: key

  defp normalize_operation_value(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, normalize_operation_value(item)} end)

  defp normalize_operation_value(value), do: value

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
  Returns bounded, display-safe summaries for every persisted conversation leaf.

  Metrics entries are operational siblings and never become branch alternatives.
  The result contains no raw entries, attachments, thinking, or tool arguments.
  """
  def branch_summaries(storage_id, opts \\ [], storage_mod \\ JsonlFile) do
    with {:ok, entries, storage_diagnostics} <- read_entries(storage_id, storage_mod),
         {:ok, index} <- fork_index(entries, storage_diagnostics),
         {:ok, {active_leaf_id, _nodes}} <- Index.path(index, :latest) do
      conversation_nodes = Enum.filter(index.ordered, &conversation_node?/1)
      conversation_parent_ids = conversation_parent_ids(conversation_nodes)
      child_counts = Enum.frequencies_by(conversation_nodes, & &1.parent_id)
      summary_length = branch_summary_length(opts)

      summaries =
        conversation_nodes
        |> Enum.reject(&MapSet.member?(conversation_parent_ids, &1.entry["id"]))
        |> Enum.reverse()
        |> Enum.map(&branch_summary(index, &1, active_leaf_id, child_counts, summary_length))

      {:ok, summaries}
    end
  end

  defp conversation_node?(%{entry: %{"type" => type}})
       when type in ["metrics", "subagent", "subagent_admission"],
    do: false

  defp conversation_node?(_node), do: true

  defp conversation_parent_ids(nodes) do
    Enum.reduce(nodes, MapSet.new(), fn
      %{parent_id: parent_id}, parents when is_binary(parent_id) ->
        MapSet.put(parents, parent_id)

      _node, parents ->
        parents
    end)
  end

  defp branch_summary(index, leaf, active_leaf_id, child_counts, summary_length) do
    {:ok, {_leaf_id, nodes}} = Index.path(index, leaf.entry["id"])
    conversation_path = Enum.filter(nodes, &conversation_node?/1)
    messages = decoded_messages(conversation_path)

    %{
      leaf_id: leaf.entry["id"],
      active?: leaf.entry["id"] == active_leaf_id,
      parent_leaf_id: parent_leaf_id(conversation_path),
      branch_point_id: branch_point_id(conversation_path, child_counts),
      last_user: last_message_summary(messages, :user, summary_length),
      last_assistant: last_message_summary(messages, :assistant, summary_length),
      turn_id: latest_metadata(messages, :turn_id),
      retry_of_turn_id: latest_metadata(messages, :retry_of_turn_id)
    }
  end

  defp decoded_messages(nodes) do
    Enum.reduce(nodes, [], fn %{entry: entry}, messages ->
      case EntryDecoder.message(entry) do
        {:ok, message} -> [message | messages]
        {:error, _reason} -> messages
      end
    end)
  end

  defp parent_leaf_id(conversation_path) do
    conversation_path
    |> Enum.reverse()
    |> Enum.drop(1)
    |> List.first()
    |> case do
      %{entry: %{"id" => id}} -> id
      nil -> nil
    end
  end

  defp branch_point_id(conversation_path, child_counts) do
    conversation_path
    |> Enum.reverse()
    |> Enum.drop(1)
    |> Enum.find_value(fn %{entry: %{"id" => id}} ->
      if Map.get(child_counts, id, 0) > 1, do: id
    end)
  end

  defp last_message_summary(messages, role, summary_length) do
    Enum.find_value(messages, fn
      %{role: ^role, id: message_id, content: content} ->
        %{message_id: message_id, text: bounded_text(content, summary_length)}

      _message ->
        nil
    end)
  end

  defp latest_metadata(messages, key) do
    Enum.find_value(messages, fn
      %{metadata: metadata} when is_map(metadata) ->
        value = Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
        if is_binary(value) and value != "", do: value

      _message ->
        nil
    end)
  end

  defp bounded_text(content, summary_length) when is_binary(content),
    do: content |> normalize_summary_text() |> String.slice(0, summary_length)

  defp bounded_text(content, summary_length) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{type: :text, text: text} when is_binary(text) -> [text]
      _item -> []
    end)
    |> Enum.join(" ")
    |> case do
      "" -> nil
      text -> text |> normalize_summary_text() |> String.slice(0, summary_length)
    end
  end

  defp bounded_text(_content, _summary_length), do: nil

  defp normalize_summary_text(text),
    do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp branch_summary_length(opts) when is_list(opts) do
    case Keyword.get(opts, :summary_length, @default_branch_summary_length) do
      length when is_integer(length) and length > 0 -> min(length, @max_branch_summary_length)
      _length -> @default_branch_summary_length
    end
  end

  defp branch_summary_length(_opts), do: @default_branch_summary_length

  @doc """
  Resolves the persisted checkpoint immediately before a user message.

  This is intentionally read-only. It provides the boundary a true Retry
  operation must use, without appending to the current active leaf or
  re-submitting the prompt as a Resend.
  """
  def retry_checkpoint(storage_id, message_id),
    do: retry_checkpoint(storage_id, message_id, JsonlFile)

  def retry_checkpoint(storage_id, message_id, storage_mod)
      when is_binary(message_id) and message_id != "" do
    with {:ok, entries, storage_diagnostics} <- read_entries(storage_id, storage_mod),
         {:ok, index} <- fork_index(entries, storage_diagnostics),
         {:ok, node} <- retry_message_node(index, message_id),
         {:ok, message} <- EntryDecoder.message(node.entry),
         :ok <- validate_retry_message(message),
         {:ok, {_leaf_id, branch}} <- Index.path(index, node.entry["id"]),
         {:ok, {source_leaf_id, source_branch}} <- Index.path(index, :latest),
         {:ok, source_snapshot} <-
           Journal.replay(entries, diagnostics: storage_diagnostics),
         {:ok, context_snapshot} <-
           Journal.replay(entries,
             leaf_id: node.parent_id,
             diagnostics: storage_diagnostics
           ),
         {:ok, retry_of_turn_id} <- retry_turn_id(message) do
      {:ok,
       %{
         message: message,
         message_id: message.id,
         content: message.content,
         attachments: message.attachments,
         source_entry_id: node.entry["id"],
         checkpoint_entry_id: node.parent_id,
         context_messages: context_snapshot.messages,
         provider_id: context_snapshot.provider_id,
         model_id: context_snapshot.model_id,
         current_provider_id: source_snapshot.provider_id,
         current_model_id: source_snapshot.model_id,
         retry_of_turn_id: retry_of_turn_id,
         source_leaf_id: source_leaf_id,
         source_revision: length(source_branch) + if(is_map(index.header), do: 1, else: 0),
         branch_entry_ids: Enum.map(branch, & &1.entry["id"])
       }}
    end
  end

  def retry_checkpoint(_storage_id, _message_id, _storage_mod),
    do: {:error, :invalid_message_id}

  defp retry_message_node(index, message_id) do
    case Enum.filter(index.ordered, fn node ->
           get_in(node, [:entry, "type"]) == "message" and
             get_in(node, [:entry, "message", "id"]) == message_id
         end) do
      [] -> {:error, :message_not_found}
      [node] -> {:ok, node}
      _nodes -> {:error, :ambiguous_message_id}
    end
  end

  defp validate_retry_message(%{role: :user, content: content})
       when is_binary(content) and byte_size(content) > 0,
       do: :ok

  defp validate_retry_message(%{role: :user, content: content}) when is_list(content) do
    if Enum.any?(content, fn
         %{type: :text, text: text} when is_binary(text) -> String.trim(text) != ""
         %{type: :image} -> true
         _ -> false
       end), do: :ok, else: {:error, :invalid_retry_boundary}
  end

  defp validate_retry_message(%{role: :user}), do: {:error, :invalid_retry_boundary}
  defp validate_retry_message(_message), do: {:error, :not_retryable}

  defp retry_turn_id(%{metadata: metadata}) when is_map(metadata) do
    case metadata[:turn_id] || metadata["turn_id"] do
      turn_id when is_binary(turn_id) and turn_id != "" -> {:ok, turn_id}
      _ -> {:error, :missing_retry_history}
    end
  end

  defp retry_turn_id(_message), do: {:error, :missing_retry_history}

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
  defp mutation_blocking_diagnostic?(%{kind: :message_repair}), do: false
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
         :ok <- validate_fork_boundary(nodes),
         {:ok, header} <- fresh_fork_header(index.header, cwd),
         :ok <-
           write_fork_entries(
             target_storage_id,
             [header | nodes |> Enum.filter(&conversation_node?/1) |> Enum.map(& &1.entry)],
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
         :ok <- validate_fork_boundary(nodes),
         {:ok, header} <- fresh_fork_header(index.header, cwd),
         fork_entries = fork_entries(entries, nodes),
         :ok <-
           write_fork_entries(
             target_storage_id,
             [header | fork_entries],
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

  defp validate_fork_boundary(nodes) do
    with {:ok, messages} <- decode_branch_messages(nodes),
         :ok <- validate_tool_pairs(messages),
         :ok <- validate_completed_turn(messages) do
      :ok
    end
  end

  defp decode_branch_messages(nodes) do
    nodes
    |> Enum.filter(&match?(%{entry: %{"type" => "message"}}, &1))
    |> Enum.reduce_while({:ok, []}, fn %{entry: entry}, {:ok, messages} ->
      case EntryDecoder.message(entry) do
        {:ok, message} -> {:cont, {:ok, [message | messages]}}
        {:error, reason} -> {:halt, {:error, {:invalid_fork_boundary, reason}}}
      end
    end)
    |> case do
      {:ok, messages} -> {:ok, Enum.reverse(messages)}
      {:error, _reason} = error -> error
    end
  end

  defp validate_tool_pairs(messages) do
    Enum.reduce_while(messages, {:ok, MapSet.new()}, fn message, {:ok, pending} ->
      case update_pending_tool_calls(message, pending) do
        {:ok, pending} -> {:cont, {:ok, pending}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, pending} ->
        case MapSet.to_list(pending) do
          [] ->
            :ok

          [tool_call_id | _rest] ->
            {:error, {:invalid_fork_boundary, {:unpaired_tool_call, tool_call_id}}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp update_pending_tool_calls(%{role: :assistant, content: content}, pending)
       when is_list(content) do
    tool_call_ids =
      for item <- content,
          tool_call_id = tool_call_id(item),
          is_binary(tool_call_id) and tool_call_id != "",
          do: tool_call_id

    {:ok, Enum.reduce(tool_call_ids, pending, &MapSet.put(&2, &1))}
  end

  defp update_pending_tool_calls(%{role: :tool_result, tool_call_id: tool_call_id}, pending)
       when is_binary(tool_call_id) and tool_call_id != "" do
    if MapSet.member?(pending, tool_call_id) do
      {:ok, MapSet.delete(pending, tool_call_id)}
    else
      {:error, {:invalid_fork_boundary, {:unmatched_tool_result, tool_call_id}}}
    end
  end

  defp update_pending_tool_calls(_message, pending), do: {:ok, pending}

  defp tool_call_id(%{type: :tool_call, id: id}), do: id
  defp tool_call_id(%{"type" => "tool_call", "id" => id}), do: id
  defp tool_call_id(_item), do: nil

  defp validate_completed_turn([]), do: :ok

  defp validate_completed_turn(messages) do
    case List.last(messages) do
      %{role: :assistant} -> :ok
      _message -> {:error, {:invalid_fork_boundary, :turn_not_completed}}
    end
  end

  defp fork_entries(entries, nodes) do
    selected_entries = nodes |> Enum.filter(&conversation_node?/1) |> Enum.map(& &1.entry)
    selected_entry_ids = MapSet.new(selected_entries, & &1["id"])

    selected_message_ids =
      selected_entries
      |> Enum.map(&get_in(&1, ["message", "id"]))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    selected_turn_ids =
      selected_entries
      |> Enum.map(&get_in(&1, ["message", "metadata", "turn_id"]))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    related_request_ids =
      entries
      |> Enum.filter(&metric_related_to_lineage?(&1, selected_message_ids, selected_turn_ids))
      |> Enum.map(&get_in(&1, ["data", "request_id"]))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.filter(entries, fn entry ->
      MapSet.member?(selected_entry_ids, entry["id"]) or
        inherited_metric?(entry, selected_message_ids, selected_turn_ids, related_request_ids)
    end)
  end

  defp inherited_metric?(
         %{"type" => "metrics", "fact" => fact, "data" => data} = entry,
         selected_message_ids,
         selected_turn_ids,
         related_request_ids
       )
       when fact in ["request_started", "request_finished", "request_usage", "tool_finished"] do
    metric_related_to_lineage?(entry, selected_message_ids, selected_turn_ids) or
      MapSet.member?(related_request_ids, data["request_id"])
  end

  defp inherited_metric?(_entry, _message_ids, _turn_ids, _request_ids), do: false

  defp metric_related_to_lineage?(%{"type" => "metrics", "data" => data}, message_ids, turn_ids) do
    MapSet.member?(message_ids, data["message_id"]) or MapSet.member?(turn_ids, data["turn_id"])
  end

  defp metric_related_to_lineage?(_entry, _message_ids, _turn_ids), do: false

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
      {type, _rest}
      when type in [
             :agent_start,
             :message_end,
             :request_started,
             :request_finished,
             :request_usage,
             :tool_finished,
             :compaction,
             :operation_started,
             :operation_finished
           ] ->
        encode_event_from_snapshot(storage_id, event, storage_mod)

      {:metrics, _fact, _attrs} ->
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
        %{kind: :message_repair} -> true
        _diagnostic -> false
      end)

    if blocking == [], do: :ok, else: {:error, {:invalid_journal, blocking}}
  end

  defp validate_compatible_append_snapshot(snapshot), do: validate_model_change_snapshot(snapshot)
end
