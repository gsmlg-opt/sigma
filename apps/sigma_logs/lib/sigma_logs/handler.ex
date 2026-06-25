defmodule Sigma.Logs.Handler do
  @handler_id "sigma_logs"

  @events [
    [:sigma, :llm, :request, :start],
    [:sigma, :llm, :request, :stop],
    [:sigma, :tool, :call, :start],
    [:sigma, :tool, :call, :stop],
    [:sigma, :permission, :check, :start],
    [:sigma, :permission, :check, :stop]
  ]

  def attach_all do
    :telemetry.detach(@handler_id)
    :telemetry.attach_many(@handler_id, @events, &handle_event/4, nil)
  end

  def handle_event(event_name, measurements, metadata, _config) do
    log_session_id = metadata[:log_session_id] || metadata[:session_id]

    if log_session_id do
      {category, event} = parse_event(event_name)
      full_metadata = Map.merge(metadata, measurements)
      entry = Sigma.Logs.Entry.new(log_session_id, category, event, full_metadata)
      Sigma.Logs.Buffer.push(log_session_id, entry)
      broadcast(log_session_id, entry)
    end
  end

  defp broadcast(log_session_id, entry) do
    pubsub = Application.get_env(:sigma_logs, :pubsub)

    if pubsub do
      Phoenix.PubSub.broadcast(pubsub, "sigma:logs:#{log_session_id}", {:log_entry, entry})
    end
  end

  defp parse_event([:sigma, :llm, :request, :start]), do: {:llm, :request_start}
  defp parse_event([:sigma, :llm, :request, :stop]), do: {:llm, :request_stop}
  defp parse_event([:sigma, :tool, :call, :start]), do: {:tool, :call_start}
  defp parse_event([:sigma, :tool, :call, :stop]), do: {:tool, :call_stop}
  defp parse_event([:sigma, :permission, :check, :start]), do: {:permission, :check_start}
  defp parse_event([:sigma, :permission, :check, :stop]), do: {:permission, :check_stop}
end
