defmodule Sigma.Ai.CancellationFeedback do
  @moduledoc "Public cancellation feedback independent of local turn settlement."

  def message(scope, result) do
    target = scope[:target] || "Turn"

    detail =
      case result[:outcome] do
        :pending ->
          "local cancellation requested; waiting for upstream confirmation."

        :confirmed ->
          "upstream confirmed cancellation."

        :already_terminal ->
          "upstream was already #{result[:status] || "terminal"}."

        :unsupported ->
          "local cancellation only; upstream cancellation is not enabled. Generation may continue."

        :failed ->
          "local cancellation requested; upstream cancel request failed. Upstream stop is unconfirmed."

        _ ->
          "local cancellation requested; upstream stop is unconfirmed (missing state, interrupted request or restart). Generation may continue."
      end

    "#{target}: #{detail}"
  end

  def payload(scope, result) do
    %{
      "target" => scope[:target],
      "outcome" => to_string(result[:outcome] || :unknown),
      "status" => result[:status],
      "reason" => stringify(result[:reason]),
      "responseId" => result[:response_id],
      "httpStatus" => result[:http_status],
      "message" => message(scope, result)
    }
  end

  defp stringify(nil), do: nil
  defp stringify(value), do: to_string(value)
end
