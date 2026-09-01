defmodule Sigma.Agent.ProtocolEventMapper do
  @moduledoc "Pure mapping from Agent domain events to bounded Protocol V1 events."

  alias Sigma.Protocol.{Codec, Envelope, Error}

  @max_text_bytes 16_384
  @max_parts 100

  def map({:prompt_admitted, status, info}, session_id, active_turn_id) do
    event_turn_id = info.turn_id
    next_active_turn_id = if status == :queued_as_follow_up, do: active_turn_id, else: event_turn_id

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
    Error.new(code, error_message(code))
  end

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

  def snapshot_payload(snapshot) do
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
      "diagnostics" => snapshot.diagnostics |> Enum.take(10) |> Enum.map(&snapshot_value/1)
    }

    fit_snapshot_payload(payload, snapshot.session_id)
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
    do: value |> Enum.take(5) |> Map.new(fn {key, item} -> {key, snapshot_value(item, depth + 1)} end)

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

  defp public_map(map), do: Map.new(map, fn {key, value} -> {Atom.to_string(key), public_value(value)} end)

  defp public_value(nil), do: nil
  defp public_value(value) when is_boolean(value) or is_number(value), do: value
  defp public_value(value) when is_binary(value), do: bounded_text(value)
  defp public_value(value) when is_atom(value), do: Atom.to_string(value)

  defp public_value(value) when is_list(value) do
    value |> Enum.take(@max_parts) |> Enum.map(&public_value/1)
  end

  defp public_value(%_struct{} = value), do: value |> Map.from_struct() |> public_value()

  defp public_value(value) when is_map(value) do
    value
    |> Enum.take(@max_parts)
    |> Map.new(fn {key, item} -> {public_key(key), public_value(item)} end)
  end

  defp public_value(_value), do: nil

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

  defp error_message("approval_required"), do: "Approval is required before execution can continue."
  defp error_message("session_busy"), do: "The session is busy."
  defp error_message("session_not_running"), do: "The session is not running."
  defp error_message("no_active_turn"), do: "There is no active turn."
  defp error_message(_code), do: "The session command failed."
end
