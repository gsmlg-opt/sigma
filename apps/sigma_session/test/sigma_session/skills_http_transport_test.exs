defmodule Sigma.Session.Skills.HTTPTransportTest do
  use ExUnit.Case, async: true

  alias Sigma.Session.Skills.HTTPTransport

  test "returns status, single-valued lowercase headers and the body" do
    with_server(~s({"ok":true}), fn url ->
      assert {:ok, %{status: 200, headers: headers, body: ~s({"ok":true})}} =
               HTTPTransport.request(request(url))

      assert headers["content-type"] == "application/json"
    end)
  end

  test "forwards a create POST and its JSON body over the actual HTTP transport" do
    payload = Formata.JSON.encode!(%{"slug" => "new-skill", "content" => "Unicode 正文"})

    with_server("created", fn url ->
      post =
        request(url)
        |> Map.merge(%{
          method: :post,
          body: payload,
          headers: [{"content-type", "application/json"}]
        })

      assert {:ok, %{body: "created"}} = HTTPTransport.request(post)
      assert_receive {:transport_request, bytes}
      assert bytes =~ "POST /skills HTTP/1.1"
      assert String.downcase(bytes) =~ "content-type: application/json"
      assert String.ends_with?(bytes, payload)
    end)
  end

  test "a create redirect is returned without forwarding credentials or replaying the POST" do
    {:ok, target} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(target)

    try do
      with_server(
        "",
        fn url ->
          post =
            request(url)
            |> Map.merge(%{
              method: :post,
              body: "{}",
              headers: [{"authorization", "Bearer fixture-only"}]
            })

          assert {:ok, %{status: 307}} = HTTPTransport.request(post)
          assert {:error, :timeout} = :gen_tcp.accept(target, 100)
        end,
        status: 307,
        headers: [{"location", "http://127.0.0.1:#{port}/redirected"}]
      )
    after
      :gen_tcp.close(target)
    end
  end

  test "stops at max_bytes and when cancelled" do
    with_server(String.duplicate("x", 4_096), fn url ->
      assert {:error, :response_too_large} =
               HTTPTransport.request(%{request(url) | max_bytes: 100})
    end)

    with_server("body", fn url ->
      assert {:error, :cancelled} =
               HTTPTransport.request(%{request(url) | cancelled?: fn -> true end})
    end)
  end

  defp request(url),
    do: %{
      url: url,
      headers: [{"accept", "application/json"}],
      timeout_ms: 2_000,
      deadline: System.monotonic_time(:millisecond) + 2_000,
      max_bytes: 1_000_000,
      cancelled?: fn -> false end
    }

  defp with_server(body, fun, opts \\ []) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    owner = self()

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        send(owner, {:transport_request, read_request(socket)})

        :gen_tcp.send(socket, [
          "HTTP/1.1 #{Keyword.get(opts, :status, 200)} Test\r\ncontent-type: application/json\r\n",
          Enum.map(Keyword.get(opts, :headers, []), fn {key, value} -> "#{key}: #{value}\r\n" end),
          "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n",
          body
        ])

        :gen_tcp.close(socket)
      end)

    try do
      fun.("http://127.0.0.1:#{port}/skills")
    after
      Task.shutdown(server, :brutal_kill)
      :gen_tcp.close(listen)
    end
  end

  defp read_request(socket, bytes \\ "") do
    case String.split(bytes, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        length =
          case Regex.run(~r/content-length:\s*(\d+)/i, headers) do
            [_, value] -> String.to_integer(value)
            nil -> 0
          end

        if byte_size(body) >= length, do: bytes, else: receive_request(socket, bytes)

      _ ->
        receive_request(socket, bytes)
    end
  end

  defp receive_request(socket, bytes) do
    {:ok, chunk} = :gen_tcp.recv(socket, 0, 2_000)
    read_request(socket, bytes <> chunk)
  end
end
