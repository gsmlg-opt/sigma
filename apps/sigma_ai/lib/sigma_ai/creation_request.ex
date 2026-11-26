defmodule Sigma.Ai.CreationRequest do
  @moduledoc "Request retry classification; repeated POSTs remain potentially billable submissions."

  alias Sigma.Ai.ProviderError

  @connection_errors [
    :econnrefused,
    :nxdomain,
    :closed,
    :econnreset,
    :econnaborted,
    :enetdown,
    :enetunreach,
    :ehostdown,
    :ehostunreach
  ]
  @timeout_errors [:timeout, :await_timeout, :connect_timeout, :response_stream_idle_timeout]

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

  def retry_policy(options) do
    if Keyword.get(options, :retry) == false, do: false, else: &safe_retry?/2
  end

  def safe_retry?(_request, %Sigma.Ai.HTTP.TransportError{reason: reason}),
    do: reason in @connection_errors or reason in @timeout_errors

  def safe_retry?(_request, %Sigma.Ai.HTTP.Response{status: status}), do: status in 500..599

  def safe_retry?(_request, _result), do: false

  def submission_error(%{reason: :cancelled}), do: ProviderError.from_reason(:cancelled)

  def submission_error(%{reason: reason} = error) do
    %ProviderError{
      kind:
        if(reason in [:econnrefused, :nxdomain],
          do: :transport_unavailable,
          else: :submission_uncertain
        ),
      message:
        "Provider submission outcome is unknown (#{inspect(reason)}). " <>
          "The request may have been accepted; creating another response may duplicate work.",
      retryable: not is_nil(submission_class(reason)),
      retry_class: submission_class(reason),
      raw: %{reason: reason, submission_attempts: Map.get(error, :attempts, [])}
    }
  end

  def interrupted(reason, response_id) do
    retry? =
      reason in @connection_errors or reason in @timeout_errors or reason == :truncated_stream

    %ProviderError{
      kind: :stream_interrupted,
      message:
        "Provider stream interrupted before completion (#{inspect(reason)}). " <>
          "A replacement request may duplicate upstream generation.",
      retryable: retry?,
      retry_class: if(retry?, do: :stream),
      raw: %{reason: reason, response_id: response_id}
    }
  end

  defp submission_class(reason) when reason in @connection_errors, do: :connection
  defp submission_class(reason) when reason in @timeout_errors, do: :stream
  defp submission_class(_), do: nil

  def http_error(%Sigma.Ai.HTTP.Response{} = resp, body, provider) do
    opts = [
      provider: provider,
      content_type: List.first(List.wrap(resp.headers["content-type"])),
      retry_after: List.first(List.wrap(resp.headers["retry-after"]))
    ]

    error = classify_http_error(resp.status, body, opts)
    %{error | raw: %{provider_error: error.raw, submission_attempts: resp.attempts}}
  end

  def http_error(status, body, retry_after),
    do: classify_http_error(status, body, retry_after: retry_after)

  defp classify_http_error(status, body, opts) do
    error = ProviderError.from_http(status, body, opts)
    retry? = status in 500..599
    %{error | retryable: retry?, retry_class: if(retry?, do: :stream)}
  end
end
