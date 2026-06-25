defmodule Sigma.Ai.Providers.OpenAITest do
  use ExUnit.Case, async: true

  alias Sigma.Ai.Providers.OpenAI

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

  test "normalizes streamed tool calls into unified provider events" do
    sse = [
      sse_json(%{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "call_1",
                  "type" => "function",
                  "function" => %{"name" => "bash", "arguments" => "{\"command\""}
                }
              ]
            },
            "finish_reason" => nil
          }
        ]
      }),
      sse_json(%{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [
                %{"index" => 0, "function" => %{"arguments" => ":\"git status\"}"}}
              ]
            },
            "finish_reason" => nil
          }
        ]
      }),
      sse_json(%{
        "choices" => [
          %{"index" => 0, "delta" => %{}, "finish_reason" => "tool_calls"}
        ]
      }),
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

      assert {:toolcall_start, 0, _start_msg} =
               Enum.find(events, &match?({:toolcall_start, 0, _}, &1))

      assert [
               {:toolcall_delta, 0, "{\"command\"", _},
               {:toolcall_delta, 0, ":\"git status\"}", _}
             ] = Enum.filter(events, &match?({:toolcall_delta, 0, _, _}, &1))

      assert {:toolcall_end, 0, tool_call, tool_msg} =
               Enum.find(events, &match?({:toolcall_end, 0, _, _}, &1))

      assert tool_call == %{
               type: :tool_call,
               id: "call_1",
               name: "bash",
               arguments: %{"command" => "git status"}
             }

      assert tool_msg.content == [tool_call]

      assert {:done, :tool_use, ai_msg} = Enum.find(events, &match?({:done, _, _}, &1))
      assert ai_msg.content == [tool_call]
    end)
  end

  test "normalizes sparse OpenAI tool call indexes into compact content indexes" do
    sse = [
      sse_json(%{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 1,
                  "id" => "call_sparse",
                  "type" => "function",
                  "function" => %{"name" => "bash", "arguments" => "{\"command\":\"git status\"}"}
                }
              ]
            },
            "finish_reason" => nil
          }
        ]
      }),
      sse_json(%{
        "choices" => [
          %{"index" => 0, "delta" => %{}, "finish_reason" => "tool_calls"}
        ]
      }),
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

      assert {:toolcall_start, 0, _start_msg} =
               Enum.find(events, &match?({:toolcall_start, 0, _}, &1))

      assert {:toolcall_end, 0, tool_call, tool_msg} =
               Enum.find(events, &match?({:toolcall_end, 0, _, _}, &1))

      assert tool_call == %{
               type: :tool_call,
               id: "call_sparse",
               name: "bash",
               arguments: %{"command" => "git status"}
             }

      assert tool_msg.content == [tool_call]

      assert {:done, :tool_use, %{content: [^tool_call]}} =
               Enum.find(events, &match?({:done, _, _}, &1))
    end)
  end

  test "finalizes streamed tool calls when OpenAI-compatible providers finish with stop" do
    sse = [
      sse_json(%{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 1,
                  "id" => "call_stop",
                  "type" => "function",
                  "function" => %{"name" => "bash", "arguments" => "{\"command\":\"git diff\"}"}
                }
              ]
            },
            "finish_reason" => nil
          }
        ]
      }),
      sse_json(%{
        "choices" => [
          %{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}
        ]
      }),
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

      assert {:toolcall_start, 0, _start_msg} =
               Enum.find(events, &match?({:toolcall_start, 0, _}, &1))

      assert {:toolcall_end, 0, tool_call, tool_msg} =
               Enum.find(events, &match?({:toolcall_end, 0, _, _}, &1))

      assert tool_call == %{
               type: :tool_call,
               id: "call_stop",
               name: "bash",
               arguments: %{"command" => "git diff"}
             }

      assert tool_msg.content == [tool_call]

      assert {:done, :tool_use, %{content: [^tool_call]}} =
               Enum.find(events, &match?({:done, _, _}, &1))
    end)
  end

  test "finalizes pending streamed tool calls when the transport closes" do
    sse = [
      sse_json(%{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "call_transport_done",
                  "type" => "function",
                  "function" => %{
                    "name" => "read",
                    "arguments" => "{\"path\":\"/tmp/example.txt\"}"
                  }
                }
              ]
            },
            "finish_reason" => nil
          }
        ]
      })
    ]

    with_sse_server(sse, fn base_url ->
      events =
        OpenAI.stream(%{
          model: %{id: "gpt-test", api: "openai", provider: "openai"},
          context: %{messages: [], system_prompt: nil, tools: []},
          options: [api_key: "test-key", base_url: base_url, receive_timeout: 1_000]
        })
        |> Enum.to_list()

      assert {:toolcall_end, 0, tool_call, tool_msg} =
               Enum.find(events, &match?({:toolcall_end, 0, _, _}, &1))

      assert tool_call == %{
               type: :tool_call,
               id: "call_transport_done",
               name: "read",
               arguments: %{"path" => "/tmp/example.txt"}
             }

      assert tool_msg.content == [tool_call]

      assert {:done, :tool_use, %{content: [^tool_call]}} =
               Enum.find(events, &match?({:done, _, _}, &1))
    end)
  end

  test "serializes assistant tool calls for follow-up tool results" do
    sse = [
      ~s(data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n),
      "data: [DONE]\n\n"
    ]

    with_capture_server(sse, fn base_url, captured ->
      OpenAI.stream(%{
        model: %{id: "gpt-test", api: "openai", provider: "openai"},
        context: %{
          messages: [
            %{role: :user, content: "Read the file"},
            %{
              role: :assistant,
              content: [
                %{
                  type: :tool_call,
                  id: "call_read_1",
                  name: "read",
                  arguments: %{"path" => "/tmp/example.txt"}
                }
              ]
            },
            %{
              role: :tool_result,
              tool_call_id: "call_read_1",
              content: [%{type: :text, text: "file contents"}]
            }
          ],
          system_prompt: nil,
          tools: []
        },
        options: [api_key: "test-key", base_url: base_url, receive_timeout: 1_000]
      })
      |> Enum.to_list()

      assert %{"messages" => [_user_msg, assistant_msg, tool_msg]} = Agent.get(captured, & &1)

      assert assistant_msg["role"] == "assistant"
      assert assistant_msg["content"] == nil

      assert [
               %{
                 "id" => "call_read_1",
                 "type" => "function",
                 "function" => %{
                   "name" => "read",
                   "arguments" => "{\"path\":\"/tmp/example.txt\"}"
                 }
               }
             ] = assistant_msg["tool_calls"]

      assert %{
               "role" => "tool",
               "tool_call_id" => "call_read_1",
               "content" => "file contents"
             } = tool_msg
    end)
  end

  test "emits LLM telemetry for OpenAI requests" do
    session_id = "openai_telemetry_#{System.unique_integer([:positive])}"
    handler_id = "openai-telemetry-test-#{System.unique_integer([:positive])}"
    {:ok, telemetry_events} = Agent.start(fn -> [] end)
    Sigma.Logs.start_session(session_id)

    :telemetry.attach_many(
      handler_id,
      [[:sigma, :llm, :request, :start], [:sigma, :llm, :request, :stop]],
      fn event, measurements, metadata, _config ->
        Agent.update(telemetry_events, &[{event, measurements, metadata} | &1])
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)
      Agent.stop(telemetry_events)
      Sigma.Logs.stop_session(session_id)
    end)

    sse = [
      ~s(data: {"choices":[{"index":0,"delta":{"content":"hello"},"finish_reason":null}]}\n\n),
      ~s(data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n),
      ~s(data: {"usage":{"prompt_tokens":10,"completion_tokens":1,"total_tokens":11}}\n\n),
      "data: [DONE]\n\n"
    ]

    with_sse_server(sse, fn base_url ->
      OpenAI.stream(%{
        model: %{id: "gpt-test", api: "openai", provider: "openai"},
        session_id: session_id,
        context: %{messages: [], system_prompt: nil, tools: []},
        options: [api_key: "test-key", base_url: base_url, receive_timeout: 1_000]
      })
      |> Enum.to_list()
    end)

    events = Agent.get(telemetry_events, &Enum.reverse/1)

    assert {[:sigma, :llm, :request, :start], _measurements,
            %{
              session_id: ^session_id,
              model: "gpt-test",
              provider: "openai",
              request_body: request_body
            }} = Enum.find(events, &match?({[:sigma, :llm, :request, :start], _, _}, &1))

    assert request_body.model == "gpt-test"

    assert {[:sigma, :llm, :request, :stop], %{duration: duration},
            %{
              session_id: ^session_id,
              model: "gpt-test",
              usage: %{input: 10, output: 1, total_tokens: 11},
              response_content: [%{type: :text, text: "hello"}]
            }} = Enum.find(events, &match?({[:sigma, :llm, :request, :stop], _, _}, &1))

    assert is_integer(duration)
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

  test "omits OpenAI output cap when the model does not configure one" do
    sse = [
      ~s(data: {"choices":[{"index":0,"delta":{"content":"hello"},"finish_reason":null}]}\n\n),
      ~s(data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n),
      "data: [DONE]\n\n"
    ]

    with_capture_server(sse, fn base_url, captured ->
      OpenAI.stream(%{
        model: %{id: "openai-codex/gpt-5.5", api: "openai", provider: "openai"},
        context: %{messages: [], system_prompt: nil, tools: []},
        options: [api_key: "test-key", base_url: base_url, receive_timeout: 1_000]
      })
      |> Enum.to_list()

      body = Agent.get(captured, & &1)

      refute Map.has_key?(body, "max_tokens")
      refute Map.has_key?(body, "max_completion_tokens")
      refute Map.has_key?(body, "max_output_tokens")
    end)
  end

  test "ignores max_output_tokens model metadata for OpenAI requests" do
    sse = [
      ~s(data: {"choices":[{"index":0,"delta":{"content":"hello"},"finish_reason":null}]}\n\n),
      ~s(data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n),
      "data: [DONE]\n\n"
    ]

    with_capture_server(sse, fn base_url, captured ->
      OpenAI.stream(%{
        model: %{
          "max_output_tokens" => 128_000,
          id: "openai-codex/gpt-5.5",
          api: "openai",
          provider: "openai"
        },
        context: %{messages: [], system_prompt: nil, tools: []},
        options: [api_key: "test-key", base_url: base_url, receive_timeout: 1_000]
      })
      |> Enum.to_list()

      body = Agent.get(captured, & &1)

      refute Map.has_key?(body, "max_tokens")
      refute Map.has_key?(body, "max_output_tokens")
    end)
  end

  test "uses configured x-api-key auth header" do
    sse = [
      ~s(data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n),
      "data: [DONE]\n\n"
    ]

    with_request_capture_server(sse, fn base_url, captured ->
      OpenAI.stream(%{
        model: %{id: "gpt-test", api: "openai", provider: "openai"},
        context: %{messages: [], system_prompt: nil, tools: []},
        options: [
          api_key: "test-key",
          base_url: base_url,
          receive_timeout: 1_000,
          auth_type: "x-api-key"
        ]
      })
      |> Enum.to_list()

      assert %{headers: headers} = Agent.get(captured, & &1)
      assert headers["x-api-key"] == "test-key"
      refute Map.has_key?(headers, "authorization")
    end)
  end

  test "uses configured custom auth header" do
    sse = [
      ~s(data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n),
      "data: [DONE]\n\n"
    ]

    with_request_capture_server(sse, fn base_url, captured ->
      OpenAI.stream(%{
        model: %{id: "gpt-test", api: "openai", provider: "openai"},
        context: %{messages: [], system_prompt: nil, tools: []},
        options: [
          api_key: "test-key",
          base_url: base_url,
          receive_timeout: 1_000,
          auth_type: "custom_header",
          auth_header_name: "X-Provider-Key"
        ]
      })
      |> Enum.to_list()

      assert %{headers: headers} = Agent.get(captured, & &1)
      assert headers["x-provider-key"] == "test-key"
      refute Map.has_key?(headers, "authorization")
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

  defp sse_json(payload), do: "data: #{Jason.encode!(payload)}\n\n"

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
