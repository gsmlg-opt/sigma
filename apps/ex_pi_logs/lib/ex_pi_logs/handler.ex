defmodule PiLogs.Handler do
  @handler_id "ex_pi_logs"

  @events [
    [:ex_pi, :llm, :request, :start],
    [:ex_pi, :llm, :request, :stop],
    [:ex_pi, :tool, :call, :start],
    [:ex_pi, :tool, :call, :stop],
    [:ex_pi, :permission, :check, :start],
    [:ex_pi, :permission, :check, :stop]
  ]

  def attach_all do
    :telemetry.detach(@handler_id)
    :telemetry.attach_many(@handler_id, @events, &handle_event/4, nil)
  end

  def handle_event(event_name, measurements, metadata, _config) do
    session_id = metadata[:session_id]

    if session_id do
      {category, event} = parse_event(event_name)
      full_metadata = Map.merge(metadata, measurements)
      entry = PiLogs.Entry.new(session_id, category, event, full_metadata)
      PiLogs.Buffer.push(session_id, entry)
      broadcast(session_id, entry)
    end
  end

  defp broadcast(session_id, entry) do
    pubsub = Application.get_env(:ex_pi_logs, :pubsub)

    if pubsub do
      Phoenix.PubSub.broadcast(pubsub, "ex_pi:logs:#{session_id}", {:log_entry, entry})
    end
  end

  defp parse_event([:ex_pi, :llm, :request, :start]), do: {:llm, :request_start}
  defp parse_event([:ex_pi, :llm, :request, :stop]), do: {:llm, :request_stop}
  defp parse_event([:ex_pi, :tool, :call, :start]), do: {:tool, :call_start}
  defp parse_event([:ex_pi, :tool, :call, :stop]), do: {:tool, :call_stop}
  defp parse_event([:ex_pi, :permission, :check, :start]), do: {:permission, :check_start}
  defp parse_event([:ex_pi, :permission, :check, :stop]), do: {:permission, :check_stop}
end
