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

  test "uses model maxTokens as the default OpenAI output cap" do
    sse = [
      ~s(data: {"choices":[{"index":0,"delta":{"content":"hello"},"finish_reason":null}]}\n\n),
      ~s(data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n),
      "data: [DONE]\n\n"
    ]

    with_capture_server(sse, fn base_url, captured ->
      OpenAI.stream(%{
        model: %{
          "maxTokens" => 128_000,
          id: "MiniMax-M3",
          api: "openai",
          provider: "openai"
        },
        context: %{messages: [], system_prompt: nil, tools: []},
        options: [api_key: "test-key", base_url: base_url, receive_timeout: 1_000]
      })
      |> Enum.to_list()

      assert %{"max_tokens" => 128_000} = Agent.get(captured, & &1)
    end)
  end

  test "raises provider error details for non-streaming error responses" do
    body =
      Jason.encode!(%{
        "error" => %{
          "code" => "context_length_exceeded",
          "message" => "context is too long"
        }
      })

    with_response_server(400, "application/json", body, fn base_url ->
      error =
        assert_raise RuntimeError, fn ->
          OpenAI.stream(%{
            model: %{id: "MiniMax-M3", api: "openai", provider: "openai"},
            context: %{messages: [], system_prompt: nil, tools: []},
            options: [api_key: "test-key", base_url: base_url, receive_timeout: 1_000]
          })
          |> Enum.to_list()
        end

      assert Exception.message(error) ==
               "AI provider error context_length_exceeded: context is too long"
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

  defp with_response_server(status, content_type, body, fun) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        _request = recv_request(socket, "")

        response = [
          "HTTP/1.1 #{status} Error\r\n",
          "content-type: #{content_type}\r\n",
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

  defp with_capture_server(chunks, fun) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)
    {:ok, captured} = Agent.start_link(fn -> %{} end)

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        request = recv_request(socket, "")

        request
        |> request_body()
        |> Jason.decode!()
        |> then(&Agent.update(captured, fn _ -> &1 end))

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
      fun.("http://127.0.0.1:#{port}", captured)
    after
      Agent.stop(captured)
      Task.shutdown(task, 1_000)
      :gen_tcp.close(listen_socket)
    end
  end

  defp recv_request(socket, acc) do
    {:ok, chunk} = :gen_tcp.recv(socket, 0, 1_000)
    acc = acc <> chunk

    case String.split(acc, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        content_length =
          headers
          |> String.split("\r\n")
          |> Enum.find_value(0, fn line ->
            case String.split(line, ":", parts: 2) do
              [name, value] ->
                if String.downcase(name) == "content-length" do
                  value |> String.trim() |> String.to_integer()
                end

              _ ->
                nil
            end
          end)

        if byte_size(body) >= content_length do
          acc
        else
          recv_request(socket, acc)
        end

      [_partial] ->
        recv_request(socket, acc)
    end
  end

  defp request_body(request) do
    [_headers, body] = String.split(request, "\r\n\r\n", parts: 2)
    body
  end
end
