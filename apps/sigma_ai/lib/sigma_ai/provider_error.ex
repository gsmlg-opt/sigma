defmodule Sigma.Ai.ProviderError do
  @moduledoc "Classified provider failure suitable for Agent, UI, and protocol clients."

  defexception [:kind, :message, :status, :code, :retry_after_ms, :raw, retryable: false]

  def from_http(status, error, opts \\ []) do
    code = map_value(error, "code") || map_value(error, "type")
    message = map_value(error, "message") || "Provider HTTP #{status}"
    kind = http_kind(status, code, message)

    %__MODULE__{
      kind: kind,
      message: bounded(message),
      status: status,
      code: code,
      retryable: kind in [:rate_limit, :timeout, :server_error],
      retry_after_ms: retry_after_ms(Keyword.get(opts, :retry_after)),
      raw: error
    }
  end

  def from_reason(:timeout),
    do: new(:timeout, "Provider request timed out", retryable: true)

  def from_reason(:cancelled), do: new(:cancelled, "Provider request cancelled")

  def from_reason(reason),
    do: new(:transport_unavailable, reason, retryable: true)

  def malformed(reason), do: new(:malformed_stream, reason)

  def from_exception(%__MODULE__{} = error), do: error

  def from_exception(exception) when is_exception(exception) do
    exception
    |> Exception.message()
    |> classify_message()
  end

  def from_exception(reason), do: classify_message(inspect(reason))

  defp new(kind, message, opts \\ []) do
    %__MODULE__{
      kind: kind,
      message: message |> to_string() |> bounded(),
      retryable: Keyword.get(opts, :retryable, false),
      raw: Keyword.get(opts, :raw)
    }
  end

  defp classify_message(message) do
    downcased = String.downcase(message)

    cond do
      String.contains?(downcased, ["api key", "authentication", "unauthorized"]) ->
        new(:authentication, message)

      String.contains?(downcased, ["rate limit", "too many requests"]) ->
        new(:rate_limit, message, retryable: true)

      String.contains?(downcased, ["context", "token limit", "too long"]) ->
        new(:context_limit, message)

      String.contains?(downcased, ["timeout", "timed out"]) ->
        new(:timeout, message, retryable: true)

      String.contains?(downcased, "cancel") ->
        new(:cancelled, message)

      true ->
        new(:transport_unavailable, message, retryable: true)
    end
  end

  defp http_kind(status, _code, _message) when status in [401, 403], do: :authentication
  defp http_kind(429, _code, _message), do: :rate_limit
  defp http_kind(status, _code, _message) when status in [408, 504], do: :timeout
  defp http_kind(status, _code, _message) when status >= 500, do: :server_error

  defp http_kind(400, code, message) do
    if String.contains?(String.downcase(to_string(code || message)), ["context", "token"]) do
      :context_limit
    else
      :invalid_request
    end
  end

  defp http_kind(_status, _code, _message), do: :invalid_request

  defp retry_after_ms(value) when is_integer(value) and value >= 0, do: value * 1_000

  defp retry_after_ms(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds * 1_000
      _invalid -> nil
    end
  end

  defp retry_after_ms(_value), do: nil

  defp map_value(map, "code") when is_map(map), do: Map.get(map, "code", Map.get(map, :code))
  defp map_value(map, "type") when is_map(map), do: Map.get(map, "type", Map.get(map, :type))

  defp map_value(map, "message") when is_map(map),
    do: Map.get(map, "message", Map.get(map, :message))

  defp map_value(_map, _key), do: nil

  defp bounded(message) when byte_size(message) <= 8_192, do: message
  defp bounded(message), do: binary_part(message, 0, 8_192) <> "…"
end
