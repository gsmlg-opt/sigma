defmodule Sigma.Agent.ProtocolEventMapper do
  @moduledoc "Pure mapping from Agent domain events to bounded Protocol V1 events."

  alias Sigma.Protocol.{Codec, Envelope, Error, Metrics, Subagents}

  @max_text_bytes 16_384
  @max_parts 100
  @max_metric_summaries 10
  @max_metric_summary_parts 32
  @max_metric_summary_text_bytes 128

  def map({:prompt_admitted, status, info}, session_id, active_turn_id) do
    event_turn_id = info.turn_id

    next_active_turn_id =
      if status == :queued_as_follow_up, do: active_turn_id, else: event_turn_id

    case Envelope.event(
           "prompt.admitted",
           session_id,
           public_map(Map.put(info, :status, status)),
           turn_id: event_turn_id
         ) do
      {:ok, protocol_event} -> {protocol_event, next_active_turn_id}
      {:error, _reason} -> {nil, active_turn_id}
    end
  end

  def map({:turn_start}, session_id, turn_id),
    do: event("turn.started", session_id, %{}, turn_id)

  def map({:message_start, message}, session_id, turn_id),
    do: event("message.started", session_id, %{"message" => public_message(message)}, turn_id)

  def map({:message_update, message, delta}, session_id, turn_id) do
    event(
      "message.delta",
      session_id,
      %{"messageId" => message.id, "delta" => public_delta(delta)},
      turn_id
    )
  end

  def map({:message_end, message}, session_id, turn_id),
    do: event("message.completed", session_id, %{"message" => public_message(message)}, turn_id)

  def map({:subagent, attrs}, session_id, turn_id) do
    case Subagents.event(attrs) do
      {:ok, fact} -> event("subagents.changed", session_id, Subagents.to_map(fact), turn_id)
      {:error, _} -> {nil, turn_id}
    end
  end

  def map({:metrics, fact, attrs}, session_id, turn_id)
      when fact in [
             :request_started,
             :request_finished,
             :request_usage,
             :turn_started,
             :turn_finished,
             :tool_finished,
             :compaction,
             :operation_started,
             :operation_finished
           ] and is_map(attrs) do
    attrs =
      if fact in [:request_started, :request_finished, :request_usage],
        do: Metrics.sanitize_request_fact(attrs),
        else: attrs

    event(
      "metrics.changed",
      session_id,
      %{
        "schemaVersion" => Metrics.version(),
        "fact" => Atom.to_string(fact),
        "data" => public_value(attrs)
      },
      turn_id
    )
  end

  def map({:tool_execution_start, id, name, arguments}, session_id, turn_id) do
    event(
      "tool.started",
      session_id,
      %{"toolCallId" => id, "name" => name, "arguments" => public_value(arguments)},
      turn_id
    )
  end

  def map({:tool_execution_update, id, name, _arguments, update}, session_id, turn_id) do
    event(
      "tool.update",
      session_id,
      %{
        "toolCallId" => id,
        "name" => name,
        "sequence" => Map.get(update, :sequence),
        "content" => public_value(Map.get(update, :content))
      },
      turn_id
    )
  end

  def map({:tool_execution_end, id, name, content, is_error}, session_id, turn_id) do
    event(
      "tool.completed",
      session_id,
      %{
        "toolCallId" => id,
        "name" => name,
        "content" => public_value(content),
        "isError" => is_error
      },
      turn_id
    )
  end

  def map({:ask_user_question, request_id, %{kind: :permission} = request}, session_id, turn_id) do
    event(
      "permission.required",
      session_id,
      %{"requestId" => request_id, "request" => public_value(request)},
      turn_id
    )
  end

  def map({:turn_completed, event_turn_id}, session_id, _turn_id),
    do: event("turn.completed", session_id, %{}, event_turn_id)

  def map({:turn_failed, event_turn_id}, session_id, _turn_id),
    do: event("turn.failed", session_id, %{}, event_turn_id)

  def map({:turn_cancelled}, session_id, turn_id),
    do: event("turn.cancelled", session_id, %{}, turn_id)

  def map({:prompt_consumed, :follow_up, %{turn_id: turn_id}}, _session_id, _active_turn_id),
    do: {nil, turn_id}

  def map({:approval_required, tool_call_id, tool_name}, session_id, turn_id) do
    error = Error.new("approval_required", "Approval is required before execution can continue.")

    case Envelope.event(
           "session.error",
           session_id,
           %{"toolCallId" => tool_call_id, "toolName" => tool_name},
           turn_id: turn_id,
           error: error
         ) do
      {:ok, event} -> {event, turn_id}
      {:error, _reason} -> {nil, turn_id}
    end
  end

  def map(_event, _session_id, turn_id), do: {nil, turn_id}

  def session_error(session_id, turn_id, reason) do
    error = public_error(reason)

    case Envelope.event("session.error", session_id, %{}, turn_id: turn_id, error: error) do
      {:ok, event} -> event
      {:error, _reason} -> nil
    end
  end

  def public_error(reason) do
    code = reason_code(reason)
    Error.new(code, error_message(code), public_error_details(reason))
  end

  defp public_error_details({_reason, details}) when is_map(details), do: public_value(details)
  defp public_error_details(_reason), do: %{}

  def public_message(message) do
    %{
      "id" => message.id,
      "role" => to_string(message.role),
      "content" => public_value(message.content),
      "timestamp" => message.timestamp,
      "provider" => message.provider,
      "model" => message.model,
      "stopReason" => atom_string(message.stop_reason),
      "toolCallId" => message.tool_call_id,
      "toolName" => message.tool_name,
      "isError" => message.is_error
    }
  end

  def snapshot_payload(snapshot, session_id \\ nil, capabilities \\ []) do
    message_count = length(snapshot.messages)
    messages = snapshot.messages |> Enum.take(-5) |> Enum.map(&snapshot_message/1)

    payload = %{
      "sessionId" => snapshot_value(snapshot.session_id),
      "cwd" => snapshot_value(snapshot.cwd),
      "activeLeafId" => snapshot_value(snapshot.active_leaf_id),
      "branchEntryIds" => Enum.take(snapshot.branch_entry_ids, -50),
      "messages" => messages,
      "messageCount" => message_count,
      "messagesTruncated" => message_count > length(messages),
      "providerId" => snapshot_value(snapshot.provider_id),
      "modelId" => snapshot_value(snapshot.model_id),
      "reasoningLevel" => snapshot_value(snapshot.reasoning_level),
      "serviceTier" => snapshot_value(snapshot.service_tier),
      "mcpServerIds" => snapshot.mcp_server_ids |> Enum.take(20) |> Enum.map(&snapshot_value/1),
      "mode" => snapshot_value(snapshot.mode),
      "modeData" => snapshot_value(snapshot.mode_data),
      "metrics" => metrics_snapshot(snapshot.metrics, session_id),
      "protocolVersion" => Envelope.version(),
      "capabilities" => Envelope.capabilities(),
      "diagnostics" => snapshot.diagnostics |> Enum.take(10) |> Enum.map(&snapshot_value/1)
    }

    payload
    |> maybe_subagents_snapshot(snapshot, capabilities)
    |> fit_snapshot_payload(snapshot.session_id)
  end

  defp maybe_subagents_snapshot(payload, snapshot, capabilities) do
    if "subagents.v1" in capabilities do
      case Subagents.snapshot(Map.get(snapshot, :subagents)) do
        {:ok, roster} ->
          payload
          |> Map.put("subagents", Subagents.to_map(roster))
          |> Map.put("subagentsAvailable", Map.get(snapshot, :subagents_available, false))

        {:error, _} ->
          payload
      end
    else
      payload
    end
  end

  defp fit_snapshot_payload(payload, session_id) do
    with {:ok, event} <- Envelope.event("session.snapshot", session_id || "unknown", payload),
         {:ok, _encoded} <- Codec.encode(event) do
      payload
    else
      _too_large ->
        payload
        |> Map.put("messages", [])
        |> Map.put("messagesTruncated", true)
        |> Map.put("branchEntryIds", [])
        |> Map.put("mcpServerIds", [])
        |> Map.put("diagnostics", [])
        |> Map.put("modeData", nil)
    end
  end

  defp snapshot_message(message) do
    message
    |> public_message()
    |> Map.update!("content", &snapshot_value/1)
  end

  def metrics_snapshot(metrics, session_id \\ nil)

  def metrics_snapshot(nil, _session_id),
    do: %{"schemaVersion" => Metrics.version(), "available" => false}

  def metrics_snapshot(%_struct{} = metrics, session_id) do
    metrics =
      if is_binary(session_id), do: Map.put(metrics, :session_id, session_id), else: metrics

    projection = apply(metrics.__struct__, :snapshot, [metrics])
    metrics_snapshot(projection, session_id)
  end

  def metrics_snapshot(metrics, session_id) when is_map(metrics) do
    %{
      "schemaVersion" => Metrics.version(),
      "available" => true,
      "sessionId" => session_id || metric_value(metrics, :session_id),
      "startedAt" => metric_value(metrics, :started_at),
      "ownUsage" => public_value(metric_value(metrics, :own_usage) || %{}),
      "activeLineageUsage" => public_value(metric_value(metrics, :active_lineage_usage) || %{}),
      "inheritedUsage" => public_value(metric_value(metrics, :inherited_usage) || %{}),
      "requestCount" => metric_value(metrics, :request_count),
      "coverage" => public_value(metric_value(metrics, :coverage) || %{}),
      "averageLlmTokS" => metric_value(metrics, :average_llm_tok_s),
      "successfulCompactions" => metric_value(metrics, :successful_compactions),
      "lastCompaction" => public_value(metric_value(metrics, :last_compaction)),
      "requestSummaries" => metric_summaries(metrics, :requests, "request_id"),
      "turnSummaries" => metric_summaries(metrics, :turns, "turn_id")
    }
  end

  defp metric_value(metrics, key),
    do: Map.get(metrics, key, Map.get(metrics, Atom.to_string(key)))

  defp metric_summaries(metrics, key, identity_field) do
    case metric_value(metrics, key) do
      summaries when is_map(summaries) ->
        summaries
        |> Enum.sort_by(
          fn {identity, summary} ->
            {metric_summary_timestamp(summary), to_string(identity)}
          end,
          :desc
        )
        |> Enum.take(@max_metric_summaries)
        |> Enum.map(fn {identity, summary} ->
          summary
          |> metric_summary_value()
          |> Map.put_new(identity_field, to_string(identity))
        end)

      _summaries ->
        []
    end
  end

  defp metric_summary_timestamp(summary) when is_map(summary),
    do:
      Map.get(summary, :finished_at) || Map.get(summary, "finished_at") ||
        Map.get(summary, :started_at) || Map.get(summary, "started_at") || ""

  defp metric_summary_timestamp(_summary), do: ""

  defp metric_summary_value(value), do: metric_summary_value(value, 0)

  defp metric_summary_value(value, _depth) when is_binary(value) do
    if byte_size(value) <= @max_metric_summary_text_bytes,
      do: value,
      else: utf8_prefix(value, @max_metric_summary_text_bytes)
  end

  defp metric_summary_value(value, _depth)
       when is_nil(value) or is_boolean(value) or is_number(value),
       do: value

  defp metric_summary_value(value, _depth) when is_atom(value), do: Atom.to_string(value)
  defp metric_summary_value(_value, depth) when depth >= 2, do: nil

  defp metric_summary_value(value, depth) when is_list(value),
    do:
      value
      |> Enum.take(@max_metric_summaries)
      |> Enum.map(&metric_summary_value(&1, depth + 1))

  defp metric_summary_value(%_struct{} = value, depth),
    do: value |> Map.from_struct() |> metric_summary_value(depth)

  defp metric_summary_value(value, depth) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _item} -> to_string(key) end)
    |> Enum.take(@max_metric_summary_parts)
    |> Map.new(fn {key, item} -> {public_key(key), metric_summary_value(item, depth + 1)} end)
  end

  defp metric_summary_value(_value, _depth), do: nil

  defp utf8_prefix(value, max_bytes) do
    case value |> binary_part(0, max_bytes) |> :unicode.characters_to_binary() do
      prefix when is_binary(prefix) -> prefix
      {:incomplete, prefix, _remainder} -> prefix
      {:error, prefix, _remainder} -> prefix
    end
  end

  defp snapshot_value(value), do: snapshot_value(value, 0)

  defp snapshot_value(value, _depth) when is_binary(value) do
    if byte_size(value) <= 256, do: value, else: String.slice(value, 0, 64)
  end

  defp snapshot_value(value, _depth) when is_nil(value) or is_boolean(value) or is_number(value),
    do: value

  defp snapshot_value(value, _depth) when is_atom(value), do: Atom.to_string(value)
  defp snapshot_value(_value, depth) when depth >= 2, do: nil

  defp snapshot_value(value, depth) when is_list(value),
    do: value |> Enum.take(5) |> Enum.map(&snapshot_value(&1, depth + 1))

  defp snapshot_value(value, depth) when is_map(value),
    do:
      value
      |> Enum.take(5)
      |> Map.new(fn {key, item} -> {key, snapshot_value(item, depth + 1)} end)

  defp snapshot_value(_value, _depth), do: nil

  defp event(type, session_id, payload, turn_id) do
    case Envelope.event(type, session_id, payload, turn_id: turn_id) do
      {:ok, event} -> {event, turn_id}
      {:error, _reason} -> {nil, turn_id}
    end
  end

  defp public_delta({:text_delta, _index, delta, _message}), do: bounded_text(delta)
  defp public_delta({:thinking_delta, _index, delta, _message}), do: bounded_text(delta)
  defp public_delta({:toolcall_delta, _index, delta, _message}), do: bounded_text(delta)
  defp public_delta(delta) when is_binary(delta), do: bounded_text(delta)
  defp public_delta(_delta), do: ""

  defp public_map(map),
    do: Map.new(map, fn {key, value} -> {Atom.to_string(key), public_value(value)} end)

  @doc "Converts domain values to bounded protocol-safe values without exposing processes or refs."
  def public_value(nil), do: nil
  def public_value(value) when is_boolean(value) or is_number(value), do: value
  def public_value(value) when is_binary(value), do: bounded_text(value)
  def public_value(value) when is_atom(value), do: Atom.to_string(value)

  def public_value(value) when is_list(value) do
    value |> Enum.take(@max_parts) |> Enum.map(&public_value/1)
  end

  def public_value(%_struct{} = value), do: value |> Map.from_struct() |> public_value()

  def public_value(value) when is_map(value) do
    value
    |> Enum.take(@max_parts)
    |> Map.new(fn {key, item} -> {public_key(key), public_value(item)} end)
  end

  def public_value(_value), do: nil

  defp public_key(key) when is_binary(key), do: key
  defp public_key(key) when is_atom(key), do: Atom.to_string(key)
  defp public_key(key), do: inspect(key, limit: 5)

  defp bounded_text(value) do
    if byte_size(value) <= @max_text_bytes,
      do: value,
      else: String.slice(value, 0, div(@max_text_bytes, 4))
  end

  defp atom_string(nil), do: nil
  defp atom_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_string(value) when is_binary(value), do: bounded_text(value)
  defp atom_string(_value), do: nil

  defp reason_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_code({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_code({reason, _one, _two}) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_code(_reason), do: "runtime_error"

  defp error_message("approval_required"),
    do: "Approval is required before execution can continue."

  defp error_message("session_busy"), do: "The session is busy."
  defp error_message("session_not_running"), do: "The session is not running."
  defp error_message("no_active_turn"), do: "There is no active turn."
  defp error_message("revision_conflict"), do: "The session changed; refresh before retrying."

  defp error_message("leaf_conflict"),
    do: "The conversation branch changed; refresh before retrying."

  defp error_message("resync_required"),
    do: "Updates were dropped; fetch a fresh session snapshot."

  defp error_message("unsupported_capabilities"),
    do: "The requested protocol capabilities are not supported."

  defp error_message(_code), do: "The session command failed."
end
