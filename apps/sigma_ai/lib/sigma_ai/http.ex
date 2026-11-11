defmodule Sigma.Ai.HTTP do
  @moduledoc """
  Sigma's HTTP boundary, built on `http_fetch` (ExSSL TLS, no OTP `:ssl`).

  Two shapes are offered:

    * `request/1` performs a buffered request and returns status, lowercase
      headers (`%{name => [values]}`) and the body, JSON-decoded when the
      response declares JSON (`decode_json: false` keeps the raw binary).
    * `stream/1` and `post_stream!/2` start a streamed request whose body
      chunks are delivered to the calling process. Feed every mailbox message
      to `parse_message/2`, which acknowledges each chunk and returns
      `{:ok, [{:data, chunk}]}`, `{:ok, [:done]}`, `{:error, error}` or
      `:unknown`. `cancel/1` aborts and confirms request cleanup.

  `:transport` (a function receiving the normalized request map) replaces the
  network for hermetic tests and must return `{:ok, %{status: _, body: _}}`
  (optionally `headers`) or `{:error, reason}`.
  """

  defmodule TransportError do
    @moduledoc "A request that failed before a complete HTTP response."
    defexception [:reason]

    @impl true
    def message(%{reason: reason}), do: "HTTP transport error: #{inspect(reason)}"
  end

  defmodule Response do
    @moduledoc false
    defstruct [:status, :body, :stream, :monitor, :promise, :controller, headers: %{}]
  end

  @cleanup_timeout 5_000

  @doc "Performs a buffered request. Options: method, url, headers, body | json, params, receive_timeout, decode_json, transport."
  def request(opts) when is_list(opts) do
    request = normalize(opts)

    case opts[:transport] do
      transport when is_function(transport, 1) ->
        transport.(request) |> injected_response(request)

      nil ->
        with {:ok, response} <- start(request, stream_response: false) do
          body = HTTP.Response.read_all(response.raw)
          finish(response)

          {:ok,
           %Response{
             status: response.status,
             headers: response.headers,
             body: decode(body, response.headers, request)
           }}
        end
    end
  end

  @doc "Starts a streamed request; body chunks arrive in the caller's mailbox."
  def stream(opts) when is_list(opts) do
    request = normalize(opts)

    with {:ok, response} <- start(request, stream_response: true) do
      {:ok, attach_stream(response)}
    end
  end

  @doc """
  Streams a POST, retrying only when `retry` approves a transport error (for
  creation requests: failures before the request left this host).
  Raises `TransportError` when the request cannot be started.
  """
  def post_stream!(url, opts) do
    retry = Keyword.get(opts, :retry, false)
    attempts = 1 + if(retry, do: Keyword.get(opts, :max_retries, 3), else: 0)
    post_stream(url, opts, retry, attempts, 0)
  end

  defp post_stream(url, opts, retry, attempts, attempt) do
    case stream(Keyword.merge(opts, method: :post, url: url)) do
      {:ok, response} ->
        response

      {:error, error} ->
        if attempt + 1 < attempts and is_function(retry, 2) and retry.(nil, error) do
          Process.sleep(retry_delay(opts, attempt))
          post_stream(url, opts, retry, attempts, attempt + 1)
        else
          raise error
        end
    end
  end

  defp retry_delay(opts, attempt) do
    case Keyword.get(opts, :retry_delay) do
      fun when is_function(fun, 1) -> fun.(attempt)
      ms when is_integer(ms) and ms >= 0 -> ms
      _ -> Integer.pow(2, attempt) * 1_000
    end
  end

  @doc "Interprets one mailbox message for a streamed response (Req-compatible shape)."
  def parse_message(%Response{stream: stream} = response, message) when is_pid(stream) do
    case message do
      {:stream_chunk, ^stream, chunk, ref} ->
        send(stream, {:stream_chunk_ack, ref})
        {:ok, [{:data, chunk}]}

      {:stream_end, ^stream} ->
        finish(response)
        {:ok, [:done]}

      {:stream_trailers, ^stream, _headers} ->
        {:ok, []}

      {:stream_error, ^stream, reason} ->
        {:error, %TransportError{reason: reason(reason)}}

      {:DOWN, monitor, :process, ^stream, reason} when monitor == response.monitor ->
        {:error, %TransportError{reason: {:stream_down, reason}}}

      _other ->
        :unknown
    end
  end

  def parse_message(%Response{}, _message), do: :unknown

  @doc "Aborts a streamed response and confirms request cleanup."
  def cancel(%Response{} = response) do
    if response.controller && Process.alive?(response.controller),
      do: HTTP.AbortController.abort(response.controller)

    if response.promise do
      _ =
        response.promise
        |> HTTP.Promise.completion()
        |> HTTP.RequestCompletion.abort_and_await(@cleanup_timeout)

      _ = Task.shutdown(response.promise.task, :brutal_kill)
    end

    if response.monitor, do: Process.demonitor(response.monitor, [:flush])
    stop_stream(response.stream)
    :ok
  catch
    :exit, _ -> :ok
  end

  def cancel(_response), do: :ok

  # -- request lifecycle ---------------------------------------------------------

  defp start(request, mode) do
    controller = HTTP.AbortController.new()
    timeout = request.receive_timeout

    options =
      [
        method: request.method |> to_string() |> String.upcase(),
        headers: request.headers,
        http_version: :http1,
        tls_backend: :ex_ssl,
        error_mode: :structured,
        redirect: :manual,
        decode_body: true,
        signal: controller,
        connect_timeout: min(timeout, 30_000),
        timeout: if(mode[:stream_response], do: :infinity, else: timeout),
        response_stream_idle_timeout: timeout
      ] ++ mode ++ if(request.body, do: [body: request.body], else: [])

    promise = HTTP.fetch(request.url, options)

    case HTTP.Promise.await(promise, timeout) do
      %HTTP.Response{} = response ->
        {:ok,
         %{
           raw: response,
           status: response.status,
           headers: headers(response.headers),
           promise: promise,
           controller: controller
         }}

      {:error, reason} ->
        abort(promise, controller)
        {:error, %TransportError{reason: reason(reason)}}
    end
  catch
    :exit, reason -> {:error, %TransportError{reason: {:exit, reason}}}
  end

  defp attach_stream(%{raw: %HTTP.Response{body: stream}} = response) when is_pid(stream) do
    monitor = Process.monitor(stream)
    send(stream, {:read_chunk, self(), :ack})

    %Response{
      status: response.status,
      headers: response.headers,
      stream: stream,
      monitor: monitor,
      promise: response.promise,
      controller: response.controller
    }
  end

  # A short or empty body may arrive buffered; replay it through the mailbox so
  # callers keep a single streaming code path.
  defp attach_stream(%{raw: %HTTP.Response{body: body}} = response) do
    {:ok, stream} = Agent.start(fn -> nil end)
    Agent.stop(stream)
    ref = make_ref()
    if body not in [nil, ""], do: send(self(), {:stream_chunk, stream, body, ref})
    send(self(), {:stream_end, stream})

    %Response{
      status: response.status,
      headers: response.headers,
      stream: stream,
      promise: response.promise,
      controller: response.controller
    }
  end

  defp finish(%{promise: promise} = response) when not is_nil(promise) do
    _ = HTTP.RequestCompletion.await(HTTP.Promise.completion(promise), @cleanup_timeout)
    if Map.get(response, :monitor), do: Process.demonitor(response.monitor, [:flush])
    :ok
  catch
    :exit, _ -> :ok
  end

  defp finish(_response), do: :ok

  defp abort(promise, controller) do
    if Process.alive?(controller), do: HTTP.AbortController.abort(controller)
    _ = HTTP.RequestCompletion.abort_and_await(HTTP.Promise.completion(promise), @cleanup_timeout)
    _ = Task.shutdown(promise.task, :brutal_kill)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp stop_stream(stream) when is_pid(stream) do
    Process.unlink(stream)
    if Process.alive?(stream), do: Process.exit(stream, :shutdown)
    :ok
  end

  defp stop_stream(_stream), do: :ok

  # -- normalization ---------------------------------------------------------------

  defp normalize(opts) do
    {body, headers} =
      case Keyword.fetch(opts, :json) do
        {:ok, json} -> {Jason.encode!(json), [{"content-type", "application/json"}]}
        :error -> {Keyword.get(opts, :body), []}
      end

    %{
      method: Keyword.get(opts, :method, :get),
      url: url(Keyword.fetch!(opts, :url), Keyword.get(opts, :params, [])),
      headers: merge_headers(Keyword.get(opts, :headers, []), headers),
      body: body,
      receive_timeout: Keyword.get(opts, :receive_timeout, 15_000),
      decode_json: Keyword.get(opts, :decode_json, true)
    }
  end

  defp url(url, []), do: url

  defp url(url, params) do
    uri = URI.parse(url)
    query = URI.encode_query(Enum.reject(params, fn {_k, v} -> is_nil(v) end))

    URI.to_string(%{
      uri
      | query: if(uri.query in [nil, ""], do: query, else: uri.query <> "&" <> query)
    })
  end

  defp injected_response({:ok, %{status: status} = response}, request) do
    headers = headers(Map.get(response, :headers, %{}))
    body = Map.get(response, :body)
    body = if is_binary(body), do: decode(body, headers, request), else: body
    {:ok, %Response{status: status, headers: headers, body: body}}
  end

  defp injected_response({:error, %TransportError{} = error}, _request), do: {:error, error}

  defp injected_response({:error, reason}, _request),
    do: {:error, %TransportError{reason: reason}}

  defp decode(body, headers, %{decode_json: true}) when is_binary(body) and body != "" do
    with [type | _] <- Map.get(headers, "content-type", []),
         true <- String.contains?(type, "json"),
         {:ok, decoded} <- Jason.decode(body) do
      decoded
    else
      _ -> body
    end
  end

  defp decode(body, _headers, _request), do: body

  # Lowercase name => [values], as Req exposed them to provider error handling.
  defp headers(%HTTP.Headers{} = headers), do: headers |> HTTP.Headers.to_list() |> headers()

  defp headers(headers) when is_map(headers) do
    Map.new(headers, fn {name, values} ->
      {String.downcase(to_string(name)), List.wrap(values)}
    end)
  end

  defp headers(headers) when is_list(headers) do
    Enum.reduce(headers, %{}, fn {name, value}, acc ->
      Map.update(
        acc,
        String.downcase(to_string(name)),
        [to_string(value)],
        &(&1 ++ [to_string(value)])
      )
    end)
  end

  # Defaults (e.g. JSON content-type) apply only when the caller did not set them.
  defp merge_headers(given, defaults) do
    given = headers(given)
    defaults = Enum.reject(headers(defaults), fn {name, _} -> Map.has_key?(given, name) end)
    to_pairs(given) ++ to_pairs(Map.new(defaults))
  end

  defp to_pairs(headers), do: for({name, values} <- headers, value <- values, do: {name, value})

  defp reason(%HTTP.RequestError{reason: reason}), do: reason(reason)
  defp reason(reason), do: reason
end
