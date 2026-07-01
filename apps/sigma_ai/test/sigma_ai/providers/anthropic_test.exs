defmodule Sigma.Ai.Providers.AnthropicTest do
  use ExUnit.Case, async: true

  alias Sigma.Ai.Providers.Anthropic
  alias Sigma.Ai.Stream

  @fixture_path Path.expand("../../fixtures/sse/anthropic_usage.txt", __DIR__)

  defp initial_message do
    %{
      role: :assistant,
      content: [],
      api: "anthropic",
      provider: "anthropic",
      model: "claude-3-5-sonnet-20241022",
      usage: %{
        input: 0,
        output: 0,
        cache_read: 0,
        cache_write: 0,
        total_tokens: 0,
        cost: %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0, total: 0.0}
      },
      stop_reason: nil,
      response_id: nil,
      timestamp: System.system_time(:millisecond)
    }
  end

  test "captures input tokens from message_start and merges with output from message_delta" do
    content = File.read!(@fixture_path)
    {events, ""} = Stream.decode("", content)

    {processed_events, _final_msg} = Anthropic.process_events(events, initial_message())

    assert {:done, :stop, ai_msg} = Enum.find(processed_events, &match?({:done, _, _}, &1))

    assert ai_msg.usage.input == 100_000
    assert ai_msg.usage.cache_read == 200
    assert ai_msg.usage.cache_write == 500
    assert ai_msg.usage.output == 50
    assert ai_msg.usage.total_tokens == 100_050
  end

  test "delta-only output_tokens without input fields preserves baseline input" do
    # message_delta with ONLY output_tokens (real Anthropic API omits input fields)
    events = [
      %{
        "type" => "message_start",
        "message" => %{
          "id" => "msg_1",
          "usage" => %{
            "input_tokens" => 5000,
            "cache_creation_input_tokens" => 100,
            "cache_read_input_tokens" => 50,
            "output_tokens" => 0
          }
        }
      },
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn"},
        "usage" => %{"output_tokens" => 200}
      },
      %{"type" => "message_stop"}
    ]

    {processed_events, _} = Anthropic.process_events(events, initial_message())

    assert {:done, :stop, ai_msg} = Enum.find(processed_events, &match?({:done, _, _}, &1))

    assert ai_msg.usage.input == 5_000
    assert ai_msg.usage.cache_read == 50
    assert ai_msg.usage.cache_write == 100
    assert ai_msg.usage.output == 200
    assert ai_msg.usage.total_tokens == 5_200
  end

  test "uses model maxTokens as the default Anthropic output cap" do
    sse = [
      ~s(data: {"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":1,"output_tokens":0}}}\n\n),
      ~s(data: {"type":"message_stop"}\n\n)
    ]

    with_capture_server(sse, fn base_url, captured ->
      Anthropic.stream(%{
        model: %{
          "maxTokens" => 128_000,
          id: "MiniMax-M3",
          api: "anthropic-messages",
          provider: "minimax"
        },
        context: %{messages: [], system_prompt: nil, tools: []},
        options: [api_key: "test-key", base_url: base_url, receive_timeout: 1_000]
      })
      |> Enum.to_list()

      assert %{"max_tokens" => 128_000} = Agent.get(captured, & &1)
    end)
  end

  test "ignores max_output_tokens model metadata for Anthropic requests" do
    sse = [
      ~s(data: {"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":1,"output_tokens":0}}}\n\n),
      ~s(data: {"type":"message_stop"}\n\n)
    ]

    with_capture_server(sse, fn base_url, captured ->
      Anthropic.stream(%{
        model: %{
          "max_output_tokens" => 128_000,
          id: "claude-test",
          api: "anthropic-messages",
          provider: "anthropic"
        },
        context: %{messages: [], system_prompt: nil, tools: []},
        options: [api_key: "test-key", base_url: base_url, receive_timeout: 1_000]
      })
      |> Enum.to_list()

      assert %{"max_tokens" => 4096} = Agent.get(captured, & &1)
    end)
  end

  test "uses configured bearer token auth header" do
    sse = [
      ~s(data: {"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":1,"output_tokens":0}}}\n\n),
      ~s(data: {"type":"message_stop"}\n\n)
    ]

    with_request_capture_server(sse, fn base_url, captured ->
      Anthropic.stream(%{
        model: %{id: "claude-test", api: "anthropic-messages", provider: "anthropic"},
        context: %{messages: [], system_prompt: nil, tools: []},
        options: [
          api_key: "test-key",
          base_url: base_url,
          receive_timeout: 1_000,
          auth_type: "bearer"
        ]
      })
      |> Enum.to_list()

      assert %{headers: headers} = Agent.get(captured, & &1)
      assert headers["authorization"] == "Bearer test-key"
      refute Map.has_key?(headers, "x-api-key")
    end)
  end

  test "groups consecutive tool results into the next Anthropic user message" do
    sse = [
      ~s(data: {"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":1,"output_tokens":0}}}\n\n),
      ~s(data: {"type":"message_stop"}\n\n)
    ]

    messages = [
      %{
        role: :assistant,
        content: [
          %{
            type: :tool_call,
            id: "call_function_rdsm5k4r1nds_2",
            name: "read_file",
            arguments: %{"path" => "a.ex"}
          },
          %{
            type: :tool_call,
            id: "call_function_rdsm5k4r1nds_3",
            name: "read_file",
            arguments: %{"path" => "b.ex"}
          }
        ]
      },
      %{
        role: :tool_result,
        tool_call_id: "call_function_rdsm5k4r1nds_2",
        content: [%{type: :text, text: "first result"}],
        is_error: false
      },
      %{
        role: :tool_result,
        tool_call_id: "call_function_rdsm5k4r1nds_3",
        content: [%{type: :text, text: "second result"}],
        is_error: false
      },
      %{role: :user, content: "continue"}
    ]

    with_capture_server(sse, fn base_url, captured ->
      Anthropic.stream(%{
        model: %{id: "claude-test", api: "anthropic-messages", provider: "anthropic"},
        context: %{messages: messages, system_prompt: nil, tools: []},
        options: [api_key: "test-key", base_url: base_url, receive_timeout: 1_000]
      })
      |> Enum.to_list()

      assert %{"messages" => [assistant, tool_results, user]} = Agent.get(captured, & &1)

      assert assistant["role"] == "assistant"

      assert [
               %{"type" => "tool_use", "id" => "call_function_rdsm5k4r1nds_2"},
               %{"type" => "tool_use", "id" => "call_function_rdsm5k4r1nds_3"}
             ] = assistant["content"]

      assert %{
               "role" => "user",
               "content" => [
                 %{
                   "type" => "tool_result",
                   "tool_use_id" => "call_function_rdsm5k4r1nds_2",
                   "content" => "first result",
                   "is_error" => false
                 },
                 %{
                   "type" => "tool_result",
                   "tool_use_id" => "call_function_rdsm5k4r1nds_3",
                   "content" => "second result",
                   "is_error" => false
                 }
               ]
             } = tool_results

      assert %{"role" => "user", "content" => "continue"} = user
    end)
  end

  test "raises provider error details for non-streaming error responses" do
    body =
      Jason.encode!(%{
        "error" => %{
          "type" => "invalid_request_error",
          "message" => "max_tokens is too large"
        }
      })

    with_response_server(400, "application/json", body, fn base_url ->
      error =
        assert_raise RuntimeError, fn ->
          Anthropic.stream(%{
            model: %{id: "MiniMax-M3", api: "anthropic-messages", provider: "minimax"},
            context: %{messages: [], system_prompt: nil, tools: []},
            options: [api_key: "test-key", base_url: base_url, receive_timeout: 1_000]
          })
          |> Enum.to_list()
        end

      assert Exception.message(error) ==
               "AI provider error invalid_request_error: max_tokens is too large"
    end)
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

  defp with_request_capture_server(chunks, fun) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)
    {:ok, captured} = Agent.start_link(fn -> %{} end)

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        request = recv_request(socket, "")

        Agent.update(captured, fn _ ->
          %{
            headers: request_headers(request),
            body: request |> request_body() |> Jason.decode!()
          }
        end)

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

  defp request_headers(request) do
    [headers, _body] = String.split(request, "\r\n\r\n", parts: 2)

    headers
    |> String.split("\r\n")
    |> Enum.drop(1)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [name, value] -> Map.put(acc, String.downcase(name), String.trim(value))
        _ -> acc
      end
    end)
  end
end
