defmodule Sigma.Ai.Providers.AnthropicTest do
  use ExUnit.Case, async: true

  alias Sigma.Ai.{ProviderError, Stream}
  alias Sigma.Ai.Providers.Anthropic

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
    assert ai_msg.usage.input_tokens == 100_700
    assert ai_msg.usage.total_tokens == 100_750
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
    assert ai_msg.usage.input_tokens == 5_150
    assert ai_msg.usage.total_tokens == 5_350
  end

  test "null Anthropic delta usage preserves previously reported cumulative facts" do
    usage = stream_delta_usage(nil)

    assert usage.input_tokens == 95
    assert usage.output_tokens == 1
    assert usage.cache_read_tokens == 80
    assert usage.cache_write_tokens == 5
    assert usage.total_tokens == 96
  end

  test "nullable Anthropic delta counters preserve baseline while output advances" do
    usage =
      stream_delta_usage(%{
        "input_tokens" => nil,
        "cache_read_input_tokens" => nil,
        "cache_creation_input_tokens" => nil,
        "output_tokens" => 2
      })

    assert usage.input_tokens == 95
    assert usage.output_tokens == 2
    assert usage.cache_read_tokens == 80
    assert usage.cache_write_tokens == 5
    assert usage.total_tokens == 97
  end

  test "malformed nonnull Anthropic delta counters become unknown instead of retaining baseline" do
    usage =
      stream_delta_usage(%{
        "input_tokens" => "invalid",
        "cache_read_input_tokens" => -1,
        "output_tokens" => 2
      })

    assert is_nil(usage.input_tokens)
    assert is_nil(usage.cache_read_tokens)
    assert usage.cache_write_tokens == 5
    assert usage.output_tokens == 2
    assert is_nil(usage.total_tokens)
    refute Sigma.Ai.ProviderUsage.complete?(usage)
  end

  defp stream_delta_usage(delta_usage) do
    sse =
      Enum.map(
        [
          %{
            "type" => "message_start",
            "message" => %{
              "id" => "msg_usage",
              "usage" => %{
                "input_tokens" => 10,
                "output_tokens" => 1,
                "cache_read_input_tokens" => 80,
                "cache_creation_input_tokens" => 5
              }
            }
          },
          %{
            "type" => "message_delta",
            "delta" => %{"stop_reason" => "end_turn"},
            "usage" => delta_usage
          },
          %{"type" => "message_stop"}
        ],
        fn event -> "data: " <> Jason.encode!(event) <> "\n\n" end
      )

    with_capture_server(sse, fn base_url, _captured ->
      request =
        Sigma.Ai.ProviderRequest.new(%{
          model: %{id: "claude-usage", api: "anthropic-messages", provider: "anthropic"},
          context: %{messages: [], tools: []},
          options: [api_key: "test-key", base_url: base_url, receive_timeout: 1_000]
        })

      events = Sigma.Ai.Provider.stream(Anthropic, request) |> Enum.to_list()
      assert Enum.any?(events, &(&1.type == :response_completed))

      assert %Sigma.Ai.ProviderEvent{usage: usage} =
               Enum.find(events, &(&1.type == :usage_updated))

      usage
    end)
  end

  test "malformed finalized tool arguments emit a provider error" do
    events = [
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "tool_use", "id" => "call-1", "name" => "bash"}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "input_json_delta", "partial_json" => "{"}
      },
      %{"type" => "content_block_stop", "index" => 0}
    ]

    {processed, _message} = Anthropic.process_events(events, initial_message())

    assert {:provider_error, %Sigma.Ai.ProviderError{kind: :malformed_stream}} =
             Enum.find(processed, &match?({:provider_error, _error}, &1))

    refute Enum.any?(processed, &match?({:toolcall_end, _, _, _}, &1))
  end

  test "shared output reserve matches the real thinking-adjusted Anthropic HTTP cap" do
    sse = [
      ~s(data: {"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":1,"output_tokens":0}}}\n\n),
      ~s(data: {"type":"message_stop"}\n\n)
    ]

    model = %{
      id: "claude-context",
      api: "anthropic-messages",
      provider: "anthropic",
      max_tokens: 2_000
    }

    for request_options <- [[], [maxTokens: 3_000], [max_tokens: 1_000, thinking_budget: 8_000]] do
      with_capture_server(sse, fn base_url, captured ->
        options =
          Keyword.merge(request_options,
            api_key: "test-key",
            base_url: base_url,
            receive_timeout: 1_000
          )

        reserve = Sigma.Ai.Provider.output_token_limit(Anthropic, model, options)

        Anthropic.stream(%{model: model, context: %{messages: [], tools: []}, options: options})
        |> Enum.to_list()

        assert Agent.get(captured, & &1["max_tokens"]) == reserve

        assert reserve ==
                 if(options[:thinking_budget], do: 9_000, else: options[:maxTokens] || 2_000)
      end)
    end
  end

  test "repairs invalid escape sequences and control characters in streamed tool arguments" do
    events = [
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "tool_use", "id" => "call-repair", "name" => "edit"}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{
          "type" => "input_json_delta",
          "partial_json" => "{\"path\":\"A\\H\",\"text\":\"col1\tcol2\"}"
        }
      },
      %{"type" => "content_block_stop", "index" => 0}
    ]

    {processed, _message} = Anthropic.process_events(events, initial_message())

    assert {:toolcall_end, 0,
            %{
              id: "call-repair",
              name: "edit",
              arguments: %{"path" => "A\\H", "text" => "col1\tcol2"}
            }, _} = Enum.find(processed, &match?({:toolcall_end, _, _, _}, &1))
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

  test "encodes image blocks in rich Anthropic user content" do
    sse = [
      ~s(data: {"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":1,"output_tokens":0}}}\n\n),
      ~s(data: {"type":"message_stop"}\n\n)
    ]

    image = %{type: :image, data: "iVBORw0KGgo=", mime_type: "image/png"}

    with_capture_server(sse, fn base_url, captured ->
      Anthropic.stream(%{
        model: %{id: "claude-test", api: "anthropic-messages", provider: "anthropic"},
        context: %{
          messages: [%{role: :user, content: [%{type: :text, text: "Describe this"}, image]}],
          system_prompt: nil,
          tools: []
        },
        options: [api_key: "test-key", base_url: base_url, receive_timeout: 1_000]
      })
      |> Enum.to_list()

      assert %{"messages" => [%{"content" => [%{"type" => "text"}, image_block]}]} =
               Agent.get(captured, & &1)

      assert image_block == %{
               "type" => "image",
               "source" => %{
                 "type" => "base64",
                 "media_type" => "image/png",
                 "data" => "iVBORw0KGgo="
               }
             }
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
        assert_raise ProviderError, fn ->
          Anthropic.stream(%{
            model: %{id: "MiniMax-M3", api: "anthropic-messages", provider: "minimax"},
            context: %{messages: [], system_prompt: nil, tools: []},
            options: [api_key: "test-key", base_url: base_url, receive_timeout: 1_000]
          })
          |> Enum.to_list()
        end

      assert error.kind == :invalid_request
      assert error.status == 400
      assert error.code == "invalid_request_error"
    end)
  end

  describe "native (Codex) tool projection" do
    @patch_tool %{
      type: :custom,
      name: "apply_patch",
      description: "Apply a patch.",
      format: %{"type" => "grammar", "syntax" => "lark", "definition" => "start: /.+/"}
    }

    @search_tool %{
      name: "history::search_contents",
      description: "Search history.",
      parameters: %{
        "type" => "object",
        "properties" => %{"query" => %{"type" => "string"}},
        "required" => ["query"]
      },
      output_schema: %{"type" => "object"}
    }

    @read_tool %{
      name: "read_file",
      description: "Read a file.",
      parameters: %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}}
    }

    @empty_sse [
      ~s(data: {"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":1,"output_tokens":0}}}\n\n),
      ~s(data: {"type":"message_stop"}\n\n)
    ]

    test "projects custom and namespaced declarations into legal Anthropic functions" do
      with_capture_server(@empty_sse, fn base_url, captured ->
        Anthropic.stream(%{
          model: %{id: "claude-test", api: "anthropic-messages", provider: "anthropic"},
          context: %{
            messages: [%{role: :user, content: "hi"}],
            system_prompt: "system rules",
            tools: [@patch_tool, @search_tool, @read_tool]
          },
          options: [
            api_key: "test-key",
            base_url: base_url,
            receive_timeout: 1_000,
            thinking_budget: 2_000
          ]
        })
        |> Enum.to_list()

        body = Agent.get(captured, & &1)
        assert [patch, search, read] = body["tools"]

        assert patch["name"] == "apply_patch"
        assert String.starts_with?(patch["description"], "Apply a patch.")
        assert patch["description"] =~ ~s("input_kind":"custom")
        assert patch["description"] =~ "lark"

        assert patch["input_schema"] == %{
                 "type" => "object",
                 "properties" => %{"input" => %{"type" => "string"}},
                 "required" => ["input"],
                 "additionalProperties" => false
               }

        assert search["name"] == wire_alias("history::search_contents")
        assert search["name"] =~ ~r/\A[a-zA-Z0-9_-]{1,64}\z/
        assert String.starts_with?(search["description"], "Search history.")
        assert search["description"] =~ "codex::output_schema"
        assert search["input_schema"] == @search_tool.parameters
        refute Map.has_key?(search, "cache_control")

        assert read["name"] == "read_file"
        assert read["cache_control"] == %{"type" => "ephemeral"}

        assert [%{"text" => "system rules", "cache_control" => %{"type" => "ephemeral"}}] =
                 body["system"]

        assert body["thinking"] == %{"type" => "enabled", "budget_tokens" => 2_000}
        assert body["max_tokens"] == 4_096
        assert body["messages"] == [%{"role" => "user", "content" => "hi"}]
      end)
    end

    test "decodes streamed custom and namespaced calls to canonical identities" do
      raw = "  *** Begin Patch\r\n+héllo ✓ wörld\n*** End Patch \n"
      wrapper = Jason.encode!(%{"input" => raw})
      {first, rest} = String.split_at(wrapper, 7)
      alias_name = wire_alias("history::search_contents")

      sse =
        Enum.map(
          [
            %{
              "type" => "message_start",
              "message" => %{"id" => "msg_1", "usage" => %{"input_tokens" => 3}}
            },
            %{
              "type" => "content_block_start",
              "index" => 0,
              "content_block" => %{"type" => "text", "text" => ""}
            },
            %{
              "type" => "content_block_delta",
              "index" => 0,
              "delta" => %{"type" => "text_delta", "text" => "Patching."}
            },
            %{"type" => "content_block_stop", "index" => 0},
            %{
              "type" => "content_block_start",
              "index" => 1,
              "content_block" => %{
                "type" => "tool_use",
                "id" => "toolu_patch",
                "name" => "apply_patch",
                "input" => %{}
              }
            },
            %{
              "type" => "content_block_delta",
              "index" => 1,
              "delta" => %{"type" => "input_json_delta", "partial_json" => first}
            },
            %{
              "type" => "content_block_delta",
              "index" => 1,
              "delta" => %{"type" => "input_json_delta", "partial_json" => rest}
            },
            %{"type" => "content_block_stop", "index" => 1},
            %{
              "type" => "content_block_start",
              "index" => 2,
              "content_block" => %{
                "type" => "tool_use",
                "id" => "toolu_search",
                "name" => alias_name,
                "input" => %{}
              }
            },
            %{
              "type" => "content_block_delta",
              "index" => 2,
              "delta" => %{"type" => "input_json_delta", "partial_json" => ~s({"query":"x"})}
            },
            %{"type" => "content_block_stop", "index" => 2},
            %{
              "type" => "message_delta",
              "delta" => %{"stop_reason" => "tool_use"},
              "usage" => %{"output_tokens" => 9}
            },
            %{"type" => "message_stop"}
          ],
          fn event -> "data: " <> Jason.encode!(event) <> "\n\n" end
        )

      with_capture_server(sse, fn base_url, _captured ->
        events =
          Anthropic.stream(%{
            model: %{id: "claude-test", api: "anthropic-messages", provider: "anthropic"},
            context: %{messages: [], tools: [@patch_tool, @search_tool]},
            options: [api_key: "test-key", base_url: base_url, receive_timeout: 1_000]
          })
          |> Enum.to_list()

        assert [{:toolcall_start, 1, _}, {:toolcall_start, 2, _}] =
                 Enum.filter(events, &match?({:toolcall_start, _, _}, &1))

        assert {:toolcall_delta, 1, ^raw, _} =
                 Enum.find(events, &match?({:toolcall_delta, 1, _, _}, &1))

        assert [{:toolcall_end, 1, patch, _}, {:toolcall_end, 2, search, _}] =
                 Enum.filter(events, &match?({:toolcall_end, _, _, _}, &1))

        assert patch == %{
                 type: :tool_call,
                 id: "toolu_patch",
                 name: "apply_patch",
                 arguments: raw,
                 input_kind: :custom
               }

        assert search == %{
                 type: :tool_call,
                 id: "toolu_search",
                 name: "history::search_contents",
                 arguments: %{"query" => "x"},
                 input_kind: :function
               }

        assert {:done, :tool_use, message} = List.last(events)

        assert [%{type: :text, text: "Patching."}, ^patch, ^search] = message.content
        assert message.usage.output == 9
        refute Enum.any?(events, &match?({:provider_error, _}, &1))
      end)
    end

    test "replays custom and namespaced history with exact re-wrapped input" do
      raw = " line one\r\nline ✓ two \n"
      alias_name = wire_alias("history::search_contents")

      messages = [
        %{role: :user, content: "go"},
        %{
          role: :assistant,
          content: [
            %{type: :thinking, thinking: "plan", thinking_signature: "sig-1"},
            %{
              type: :tool_call,
              id: "toolu_patch",
              name: "apply_patch",
              arguments: raw,
              input_kind: :custom
            },
            %{
              type: :tool_call,
              id: "toolu_search",
              name: "history::search_contents",
              arguments: %{"query" => "x"},
              input_kind: :function
            }
          ]
        },
        %{
          role: :tool_result,
          tool_call_id: "toolu_patch",
          content: [%{type: :text, text: "applied"}],
          is_error: false
        },
        %{
          role: :tool_result,
          tool_call_id: "toolu_search",
          content: [%{type: :text, text: "found"}],
          is_error: true
        }
      ]

      with_capture_server(@empty_sse, fn base_url, captured ->
        Anthropic.stream(%{
          model: %{id: "claude-test", api: "anthropic-messages", provider: "anthropic"},
          context: %{messages: messages, tools: [@patch_tool, @search_tool]},
          options: [api_key: "test-key", base_url: base_url, receive_timeout: 1_000]
        })
        |> Enum.to_list()

        assert %{"messages" => [_user, assistant, results]} = Agent.get(captured, & &1)

        assert assistant["content"] == [
                 %{"type" => "thinking", "thinking" => "plan", "signature" => "sig-1"},
                 %{
                   "type" => "tool_use",
                   "id" => "toolu_patch",
                   "name" => "apply_patch",
                   "input" => %{"input" => raw}
                 },
                 %{
                   "type" => "tool_use",
                   "id" => "toolu_search",
                   "name" => alias_name,
                   "input" => %{"query" => "x"}
                 }
               ]

        assert results == %{
                 "role" => "user",
                 "content" => [
                   %{
                     "type" => "tool_result",
                     "tool_use_id" => "toolu_patch",
                     "content" => "applied",
                     "is_error" => false
                   },
                   %{
                     "type" => "tool_result",
                     "tool_use_id" => "toolu_search",
                     "content" => "found",
                     "is_error" => true
                   }
                 ]
               }
      end)
    end

    test "native history alone selects the projection even without active declarations" do
      messages = [
        %{
          role: :assistant,
          content: [
            %{
              type: :tool_call,
              id: "toolu_old",
              name: "history::search_contents",
              arguments: %{"query" => "x"}
            }
          ]
        },
        %{
          role: :tool_result,
          tool_call_id: "toolu_old",
          content: [%{type: :text, text: "ok"}],
          is_error: false
        }
      ]

      with_capture_server(@empty_sse, fn base_url, captured ->
        Anthropic.stream(%{
          model: %{id: "claude-test", api: "anthropic-messages", provider: "anthropic"},
          context: %{messages: messages, tools: []},
          options: [api_key: "test-key", base_url: base_url, receive_timeout: 1_000]
        })
        |> Enum.to_list()

        assert %{"messages" => [assistant, _results], "tools" => []} = Agent.get(captured, & &1)

        assert [%{"name" => name, "input" => %{"query" => "x"}}] = assistant["content"]
        assert name == wire_alias("history::search_contents")
      end)
    end

    test "an undeclared response alias fails explicitly instead of producing input" do
      sse =
        Enum.map(
          [
            %{"type" => "message_start", "message" => %{"id" => "msg_1"}},
            %{
              "type" => "content_block_start",
              "index" => 0,
              "content_block" => %{
                "type" => "tool_use",
                "id" => "toolu_x",
                "name" => "bp_unknown"
              }
            }
          ],
          fn event -> "data: " <> Jason.encode!(event) <> "\n\n" end
        )

      with_capture_server(sse, fn base_url, _captured ->
        error =
          assert_raise ProviderError, fn ->
            Anthropic.stream(%{
              model: %{id: "claude-test", api: "anthropic-messages", provider: "anthropic"},
              context: %{messages: [], tools: [@patch_tool]},
              options: [api_key: "test-key", base_url: base_url, receive_timeout: 1_000]
            })
            |> Enum.to_list()
          end

        assert error.kind == :malformed_stream
        assert error.message =~ "projection"
      end)
    end

    test "a malformed custom wrapper fails explicitly" do
      sse =
        Enum.map(
          [
            %{"type" => "message_start", "message" => %{"id" => "msg_1"}},
            %{
              "type" => "content_block_start",
              "index" => 0,
              "content_block" => %{
                "type" => "tool_use",
                "id" => "toolu_x",
                "name" => "apply_patch",
                "input" => %{}
              }
            },
            %{
              "type" => "content_block_delta",
              "index" => 0,
              "delta" => %{"type" => "input_json_delta", "partial_json" => ~s({"patch":"x"})}
            },
            %{"type" => "content_block_stop", "index" => 0}
          ],
          fn event -> "data: " <> Jason.encode!(event) <> "\n\n" end
        )

      with_capture_server(sse, fn base_url, _captured ->
        error =
          assert_raise ProviderError, fn ->
            Anthropic.stream(%{
              model: %{id: "claude-test", api: "anthropic-messages", provider: "anthropic"},
              context: %{messages: [], tools: [@patch_tool]},
              options: [api_key: "test-key", base_url: base_url, receive_timeout: 1_000]
            })
            |> Enum.to_list()
          end

        assert error.kind == :malformed_stream
      end)
    end

    test "hosted Responses history and hosted tools are still rejected before HTTP" do
      model = %{id: "claude-test", api: "anthropic-messages", provider: "anthropic"}
      options = [api_key: "test-key", base_url: "http://127.0.0.1:1"]

      hosted_history = [
        %{
          role: :assistant,
          content: [%{type: :text, text: "x"}],
          metadata: %{"openai_responses_hosted" => %{}}
        }
      ]

      for context <- [
            %{messages: hosted_history, tools: [@patch_tool]},
            %{messages: hosted_history, tools: []},
            %{messages: [], tools: [@patch_tool, %{type: :web_search, name: "web_search"}]}
          ] do
        error =
          assert_raise ProviderError, fn ->
            Anthropic.stream(%{model: model, context: context, options: options})
          end

        assert error.kind == :invalid_request
        assert error.message =~ "Anthropic does not support"
      end
    end

    test "OpenAI Chat Completions still rejects native tools before HTTP" do
      error =
        assert_raise ProviderError, fn ->
          Sigma.Ai.Providers.OpenAI.stream(%{
            model: %{id: "gpt-test", api: "openai-completions", provider: "openai"},
            context: %{messages: [], tools: [@patch_tool]},
            options: [api_key: "test-key", base_url: "http://127.0.0.1:1"]
          })
        end

      assert error.message =~ "does not support native custom tools"
    end
  end

  test "ordinary JSON-function requests keep the hand-written body" do
    messages = [
      %{role: :user, content: "go"},
      %{
        role: :assistant,
        content: [
          %{type: :thinking, thinking: "plan", thinking_signature: "sig-1"},
          %{type: :tool_call, id: "toolu_1", name: "read_file", arguments: %{"path" => "a"}}
        ]
      },
      %{
        role: :tool_result,
        tool_call_id: "toolu_1",
        content: [%{type: :text, text: "body"}],
        is_error: false
      }
    ]

    tools = [
      %{name: "read_file", description: "Read.", parameters: %{"type" => "object"}},
      %{name: "write_file", description: "Write.", parameters: %{"type" => "object"}}
    ]

    sse = [
      ~s(data: {"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":1,"output_tokens":0}}}\n\n),
      ~s(data: {"type":"message_stop"}\n\n)
    ]

    with_capture_server(sse, fn base_url, captured ->
      Anthropic.stream(%{
        model: %{id: "claude-test", api: "anthropic-messages", provider: "anthropic"},
        context: %{messages: messages, system_prompt: "rules", tools: tools},
        options: [api_key: "test-key", base_url: base_url, receive_timeout: 1_000]
      })
      |> Enum.to_list()

      assert Agent.get(captured, & &1) == %{
               "model" => "claude-test",
               "max_tokens" => 4096,
               "stream" => true,
               "system" => [
                 %{
                   "type" => "text",
                   "text" => "rules",
                   "cache_control" => %{"type" => "ephemeral", "ttl" => "1h"}
                 }
               ],
               "messages" => [
                 %{"role" => "user", "content" => "go"},
                 %{
                   "role" => "assistant",
                   "content" => [
                     %{"type" => "thinking", "thinking" => "plan", "signature" => "sig-1"},
                     %{
                       "type" => "tool_use",
                       "id" => "toolu_1",
                       "name" => "read_file",
                       "input" => %{"path" => "a"}
                     }
                   ]
                 },
                 %{
                   "role" => "user",
                   "content" => [
                     %{
                       "type" => "tool_result",
                       "tool_use_id" => "toolu_1",
                       "content" => "body",
                       "is_error" => false
                     }
                   ]
                 }
               ],
               "tools" => [
                 %{
                   "name" => "read_file",
                   "description" => "Read.",
                   "input_schema" => %{"type" => "object"}
                 },
                 %{
                   "name" => "write_file",
                   "description" => "Write.",
                   "input_schema" => %{"type" => "object"},
                   "cache_control" => %{"type" => "ephemeral"}
                 }
               ]
             }
    end)
  end

  defp wire_alias(name) do
    "bp_" <> binary_part(Base.encode16(:crypto.hash(:sha256, name), case: :lower), 0, 60)
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
