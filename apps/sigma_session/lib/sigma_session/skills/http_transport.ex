defmodule Sigma.Session.Skills.HTTPTransport do
  @moduledoc """
  `Backplane.SkillProtocol.Client` transport over `Sigma.Ai.HTTP` (http_fetch).

  Honors the Client request contract: GET `url` with `headers`, stop at
  `deadline`, when `cancelled?.()` turns true, or once the body exceeds
  `max_bytes`. Returns `{:ok, %{status, headers, body}}` with single-valued
  lowercase headers, or `{:error, reason}`.
  """

  alias Sigma.Ai.HTTP

  @spec request(map()) :: {:ok, map()} | {:error, term()}
  def request(request) do
    case HTTP.stream(
           url: request.url,
           headers: request.headers,
           receive_timeout: request.timeout_ms
         ) do
      {:ok, response} ->
        result = collect(response, request, [], 0)
        if match?({:error, _}, result), do: HTTP.cancel(response)
        result

      {:error, %HTTP.TransportError{reason: reason}} ->
        {:error, reason}
    end
  end

  defp collect(response, request, chunks, size) do
    remaining = request.deadline - System.monotonic_time(:millisecond)

    cond do
      request.cancelled?.() ->
        {:error, :cancelled}

      remaining <= 0 ->
        {:error, :timeout}

      true ->
        stream = response.stream
        monitor = response.monitor

        # Selective: only this response's stream messages; others stay queued.
        receive do
          message
          when (is_tuple(message) and elem(message, 0) in [:stream_chunk, :stream_end, :stream_trailers, :stream_error] and
                  elem(message, 1) == stream) or
                 (is_tuple(message) and tuple_size(message) == 5 and elem(message, 0) == :DOWN and
                    elem(message, 1) == monitor) ->
            case HTTP.parse_message(response, message) do
              {:ok, [{:data, chunk}]} ->
                size = size + byte_size(chunk)

                if size > request.max_bytes,
                  do: {:error, :response_too_large},
                  else: collect(response, request, [chunks, chunk], size)

              {:ok, [:done]} ->
                {:ok,
                 %{
                   status: response.status,
                   headers: Map.new(response.headers, fn {name, [value | _]} -> {name, value} end),
                   body: IO.iodata_to_binary(chunks)
                 }}

              {:ok, []} ->
                collect(response, request, chunks, size)

              {:error, %HTTP.TransportError{reason: reason}} ->
                {:error, reason}

              :unknown ->
                collect(response, request, chunks, size)
            end
        after
          min(remaining, 50) -> collect(response, request, chunks, size)
        end
    end
  end
end
