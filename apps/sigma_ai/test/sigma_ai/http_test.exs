defmodule Sigma.Ai.HTTPTest do
  use ExUnit.Case, async: true

  alias Sigma.Ai.HTTP
  alias Sigma.Ai.HTTP.TransportError

  test "streams chunked bodies to the caller and ends with :done" do
    with_server(
      fn socket ->
        send_head(socket, 200, [
          {"content-type", "text/event-stream"},
          {"transfer-encoding", "chunked"}
        ])

        send_chunk(socket, "data: one\n\n")
        Process.sleep(50)
        send_chunk(socket, "data: two\n\n")
        :gen_tcp.send(socket, "0\r\n\r\n")
      end,
      fn url ->
        response =
          HTTP.post_stream!(url, body: "{}", headers: [{"content-type", "application/json"}])

        assert response.status == 200
        assert response.headers["content-type"] == ["text/event-stream"]
        assert collect(response) == {"data: one\n\ndata: two\n\n", :done}
      end
    )
  end

  test "buffered requests decode JSON and expose lowercase headers" do
    with_server(
      fn socket ->
        body = ~s({"data":[{"id":"m1"}]})

        send_head(socket, 200, [
          {"Content-Type", "application/json"},
          {"content-length", "#{byte_size(body)}"}
        ])

        :gen_tcp.send(socket, body)
      end,
      fn url ->
        assert {:ok, %{status: 200, body: %{"data" => [%{"id" => "m1"}]}, headers: headers}} =
                 HTTP.request(url: url <> "/models", params: [after_id: "x"])

        assert headers["content-type"] == ["application/json"]
      end
    )
  end

  test "error statuses stream their body for the caller to classify" do
    with_server(
      fn socket ->
        body = ~s({"error":"bad"})
        send_head(socket, 429, [{"retry-after", "3"}, {"content-length", "#{byte_size(body)}"}])
        :gen_tcp.send(socket, body)
      end,
      fn url ->
        response = HTTP.post_stream!(url, body: "{}")
        assert response.status == 429
        assert response.headers["retry-after"] == ["3"]
        assert collect(response) == {~s({"error":"bad"}), :done}
      end
    )
  end

  test "connection failures raise TransportError and retry only when the policy allows" do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    url = "http://127.0.0.1:#{port}"
    test = self()

    policy = fn nil, %TransportError{reason: reason} ->
      send(test, {:retry_asked, reason})
      true
    end

    assert_raise TransportError, fn ->
      HTTP.post_stream!(url, body: "{}", retry: policy, max_retries: 2, retry_delay: 0)
    end

    assert_receive {:retry_asked, :econnrefused}
    assert_receive {:retry_asked, :econnrefused}
    refute_receive {:retry_asked, _}

    assert {:error, %TransportError{reason: :econnrefused}} = HTTP.request(url: url)
  end

  test "cancel aborts an open stream" do
    with_server(
      fn socket ->
        send_head(socket, 200, [{"transfer-encoding", "chunked"}])
        send_chunk(socket, "first")
        Process.sleep(5_000)
      end,
      fn url ->
        response = HTTP.post_stream!(url, body: "{}")
        assert_receive message, 2_000
        assert {:ok, [{:data, "first"}]} = HTTP.parse_message(response, message)
        assert :ok = HTTP.cancel(response)
        refute Process.alive?(response.stream)
      end
    )
  end

  test "an injected transport replaces the network" do
    transport = fn request ->
      assert request.method == :get

      {:ok,
       %{status: 200, headers: %{"content-type" => ["application/json"]}, body: ~s({"ok":true})}}
    end

    assert {:ok, %{status: 200, body: %{"ok" => true}}} =
             HTTP.request(url: "http://example.invalid", transport: transport)
  end

  defp collect(response, acc \\ "") do
    receive do
      message ->
        case HTTP.parse_message(response, message) do
          {:ok, [{:data, chunk}]} -> collect(response, acc <> chunk)
          {:ok, [:done]} -> {acc, :done}
          {:ok, []} -> collect(response, acc)
          {:error, error} -> {acc, error}
          :unknown -> collect(response, acc)
        end
    after
      3_000 -> {acc, :timeout}
    end
  end

  defp with_server(handler, fun) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        _request = read_request(socket, "")
        handler.(socket)
        :gen_tcp.close(socket)
      end)

    try do
      fun.("http://127.0.0.1:#{port}")
    after
      Task.shutdown(server, :brutal_kill)
      :gen_tcp.close(listen)
    end
  end

  defp read_request(socket, acc) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 2_000)
    acc = acc <> data

    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, body] ->
        length =
          case Regex.run(~r/content-length:\s*(\d+)/i, head) do
            [_, n] -> String.to_integer(n)
            nil -> 0
          end

        if byte_size(body) >= length, do: acc, else: read_request(socket, acc)

      _ ->
        read_request(socket, acc)
    end
  end

  defp send_head(socket, status, headers) do
    lines = Enum.map(headers, fn {k, v} -> "#{k}: #{v}\r\n" end)
    :gen_tcp.send(socket, ["HTTP/1.1 #{status} X\r\n", lines, "connection: close\r\n\r\n"])
  end

  defp send_chunk(socket, data),
    do: :gen_tcp.send(socket, [Integer.to_string(byte_size(data), 16), "\r\n", data, "\r\n"])
end
