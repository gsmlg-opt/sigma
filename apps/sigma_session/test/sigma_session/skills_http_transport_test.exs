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

  defp with_server(body, fun) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 2_000)

        :gen_tcp.send(socket, [
          "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n",
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
end
