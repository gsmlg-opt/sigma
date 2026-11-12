defmodule Sigma.Web.SamgitaHost.Translate do
  @moduledoc """
  Pure mapping from Sigma Protocol V1 events and errors to samgita_protocol
  1.0 native notifications and `SamgitaProtocol.Error`.

  Notifications are returned without `stream_id` / `cursor`; the stream adds them.
  """

  alias Sigma.Protocol.{Envelope, Error}
  alias SamgitaProtocol.Error, as: HostError

  @turn_status %{
    "turn.completed" => "completed",
    "turn.failed" => "failed",
    "turn.cancelled" => "interrupted"
  }

  @spec notification(Envelope.t(), String.t()) :: {:ok, map()} | :skip
  def notification(%Envelope{turn_id: turn_id}, _thread_id) when not is_binary(turn_id),
    do: :skip

  def notification(%Envelope{turn_id: turn_id} = event, thread_id) do
    case map_event(event.type, event.payload, %{"thread_id" => thread_id, "turn_id" => turn_id}) do
      {method, params} -> {:ok, build(turn_id, method, params)}
      :skip -> :skip
    end
  end

  @spec thread_started(String.t()) :: map()
  def thread_started(thread_id),
    do: build(thread_id, "thread/started", %{"thread_id" => thread_id})

  @spec error(term()) :: HostError.t()
  def error(%Envelope{error: %Error{} = error}), do: error(error)

  def error(%Error{code: "prompt_rejected", details: %{"reason" => reason}})
      when reason in ["turn_active", "turn_mismatch"],
      do: HostError.new("conflict")

  def error(%Error{code: code}) when code in ["turn_mismatch"], do: HostError.new("conflict")

  def error(%Error{code: code}) when code in ["not_found", "session_not_found"],
    do: HostError.new("not_found")

  def error(%Error{code: code}) when code in ["model_unavailable", "invalid_admission", "invalid_params"],
    do: HostError.new("invalid_params")

  def error(%Error{}), do: HostError.new("handler_error")

  def error(reason) when reason in [:not_found, :session_not_found], do: HostError.new("not_found")

  def error({:prompt_rejected, reason}) when reason in [:turn_active, :turn_mismatch],
    do: HostError.new("conflict")

  def error(:turn_mismatch), do: HostError.new("conflict")

  def error(reason) when reason in [:model_unavailable, :invalid_admission, :invalid_params],
    do: HostError.new("invalid_params")

  def error(_reason), do: HostError.new("handler_error")

  defp map_event("turn.started", _payload, ids), do: {"turn/started", ids}

  defp map_event(type, _payload, ids) when is_map_key(@turn_status, type),
    do: {"turn/completed", Map.put(ids, "status", @turn_status[type])}

  defp map_event("message.started", %{"message" => message}, ids),
    do: {"item/started", message_item(message, ids)}

  defp map_event("message.completed", %{"message" => message}, ids),
    do: {"item/completed", message_item(message, ids)}

  defp map_event("message.delta", %{"deltaKind" => "text", "messageId" => id, "delta" => delta}, ids)
       when is_binary(delta),
       do: {"item/delta", Map.merge(ids, %{"item_id" => id, "delta" => delta})}

  defp map_event("tool.started", %{"toolCallId" => id} = payload, ids) do
    item = %{"type" => "tool", "name" => payload["name"], "arguments" => payload["arguments"]}
    {"item/started", Map.merge(ids, %{"item_id" => id, "item" => item})}
  end

  defp map_event("tool.completed", %{"toolCallId" => id} = payload, ids) do
    item = %{
      "type" => "tool",
      "name" => payload["name"],
      "content" => payload["content"],
      "is_error" => payload["isError"] == true
    }

    {"item/completed", Map.merge(ids, %{"item_id" => id, "item" => item})}
  end

  defp map_event(_type, _payload, _ids), do: :skip

  defp message_item(%{"id" => id} = message, ids) do
    item = %{"type" => "message", "role" => message["role"], "content" => message["content"]}
    Map.merge(ids, %{"item_id" => id, "item" => item})
  end

  defp build(correlation_id, method, params) do
    %{
      "schema_version" => "1.0",
      "type" => "notification",
      "correlation_id" => correlation_id,
      "method" => method,
      "params" => params
    }
  end
end
