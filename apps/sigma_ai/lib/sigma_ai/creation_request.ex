defmodule Sigma.Ai.CreationRequest do
  @moduledoc "Safety boundary for non-idempotent provider creation requests."

  alias Sigma.Ai.ProviderError

  def reject_responses_recovery!(options) do
    if (options[:responses_cancel] != nil or options[:responses_recovery] not in [nil, false] or
          options[:background] == true or
          options[:response_id]) || options[:starting_after] do
      raise ProviderError,
        kind: :invalid_request,
        message: "Background stream recovery requires a configured OpenAI Responses adapter.",
        retryable: false
    end
  end

  # A caller may disable retries, but cannot opt a creation POST into ambiguous
  # transport/status retries. There is no provider idempotency contract here.
  def retry_policy(options) do
    if Keyword.get(options, :retry) == false, do: false, else: &safe_retry?/2
  end

  def safe_retry?(_request, %Sigma.Ai.HTTP.TransportError{reason: reason})
      when reason in [:econnrefused, :nxdomain],
      do: true

  def safe_retry?(_request, _result), do: false

  def submission_error(%{reason: reason}) when reason in [:econnrefused, :nxdomain],
    do: ProviderError.from_reason(reason)

  def submission_error(%{reason: reason}) do
    %ProviderError{
      kind: :submission_uncertain,
      message:
        "Provider submission outcome is unknown (#{inspect(reason)}). " <>
          "The request may have been accepted; creating another response may duplicate work.",
      retryable: false,
      raw: %{reason: reason}
    }
  end

  def interrupted(reason, response_id) do
    %ProviderError{
      kind: :stream_interrupted,
      message:
        "Provider stream interrupted before completion (#{inspect(reason)}). " <>
          "Automatic recovery is unavailable; a new request may duplicate work.",
      retryable: false,
      raw: %{reason: reason, response_id: response_id}
    }
  end

  def http_error(status, body, retry_after) do
    error = ProviderError.from_http(status, body, retry_after: retry_after)
    # Status alone does not prove a gateway/upstream did not accept the POST.
    %{error | retryable: false}
  end
end
