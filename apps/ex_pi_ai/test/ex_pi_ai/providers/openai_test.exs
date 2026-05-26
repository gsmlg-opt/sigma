defmodule PiAi.Providers.OpenAITest do
  use ExUnit.Case, async: true

  alias PiAi.Providers.OpenAI

  test "captures prompt tokens from stream usage chunk" do
    sse = [
      ~s(data: {"choices":[{"index":0,"delta":{"content":"hello"},"finish_reason":null}]}\n\n),
      ~s(data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n),
      ~s(data: {"usage":{"prompt_tokens":12345,"completion_tokens":7,"total_tokens":12352}}\n\n),
      "data: [DONE]\n\n"
    ]

    with_sse_server(sse, fn base_url ->
      events =
        OpenAI.stream(%{
          model: %{id: "gpt-test", api: "openai", provider: "openai"},
          context: %{messages: [], system_prompt: nil, tools: []},
          options: [api_key: "test-key", base_url: base_url, receive_timeout: 1_000]
        })
        |> Enum.to_list()

      assert {:done, :stop, ai_msg} = Enum.find(events, &match?({:done, _, _}, &1))
      assert ai_msg.usage.input == 12_345
      assert ai_msg.usage.output == 7
      assert ai_msg.usage.total_tokens == 12_352
    end)
  end

  defp with_sse_server(chunks, fun) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 1_000)
        body = IO.iodata_to_binary(chunks)

        response = [
          "HTTP/1.1 200 OK\r\n",
          "content-type: text/event-stream\r\n",
          "content-length: #{byte_size(body)}\r\n",
          "connection: close\r\n",
          "\r\n",
          body
        ]

        :ok = :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
      end)

    try do
      fun.("http://127.0.0.1:#{port}")
    after
      Task.shutdown(task, 1_000)
      :gen_tcp.close(listen_socket)
    end
  end
end
