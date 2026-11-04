defmodule Sigma.Ai.Providers.OpenAITest do
  use ExUnit.Case, async: true

  alias Sigma.Ai.{ProviderError, Providers.OpenAI}
  alias Sigma.Ai.Providers.OpenAIResponses

  test "streams Responses API text and uses Responses request fields" do
    sse = [
      sse_json(%{"type" => "response.created", "response" => %{"id" => "resp_1"}}),
      sse_json(%{"type" => "response.output_text.delta", "delta" => "hello"}),
      sse_json(%{
        "type" => "response.completed",
        "response" => %{
          "status" => "completed",
          "usage" => %{
            "input_tokens" => 10,
            "output_tokens" => 2,
            "input_token_details" => %{"cached_tokens" => 3}
          }
        }
      }),
      "data: [DONE]\n\n"
    ]

    with_request_capture_server(sse, fn base_url, captured ->
      events =
        Sigma.Ai.Providers.OpenAIResponses.stream(%{
          model: %{id: "gpt-5", api: "openai", provider: "openai"},
          context: %{
            messages: [%{role: :user, content: "Hi"}],
            system_prompt: "Be concise",
            tools: []
          },
          options: [api_key: "test-key", base_url: base_url, receive_timeout: 1_000]
        })
        |> Enum.to_list()

      body = Agent.get(captured, & &1.body)
      assert body["input"]
      refute Map.has_key?(body, "messages")
      assert body["store"] == false
      assert body["stream"] == true
      assert body["input"] |> hd() |> Map.get("role") == "system"
      assert {:done, :stop, message} = Enum.find(events, &match?({:done, _, _}, &1))
      assert message.response_id == "resp_1"
      assert message.usage.input == 7
      assert message.usage.cache_read == 3
    end)
  end

  test "Responses real plural usage details reach normalized facts without invented cached zeros" do
    for details <- [
          %{
            "input_tokens_details" => %{"cached_tokens" => 3},
            "output_tokens_details" => %{"reasoning_tokens" => 1}
          },
          %{}
        ] do
      usage = Map.merge(%{"input_tokens" => 10, "output_tokens" => 2}, details)

      sse = [
        sse_json(%{
          "type" => "response.completed",
          "response" => %{"status" => "completed", "usage" => usage}
        }),
        "data: [DONE]\n\n"
      ]

      with_request_capture_server(sse, fn base_url, _captured ->
        events =
          OpenAIResponses.stream(%{
            model: %{id: "gpt-5", api: "openai", provider: "openai"},
            context: %{messages: [%{role: :user, content: "Hi"}], tools: []},
            options: [api_key: "test", base_url: base_url, receive_timeout: 1_000]
          })
          |> Enum.to_list()

        assert {:done, :stop, message} = Enum.find(events, &match?({:done, _, _}, &1))
        fact = Sigma.Ai.ProviderUsage.normalize(message.usage)
        assert fact.input_tokens == 10

        if map_size(details) == 0 do
          assert is_nil(fact.cache_read_tokens)
          assert is_nil(fact.reasoning_tokens)
        else
          assert fact.cache_read_tokens == 3
          assert fact.reasoning_tokens == 1
        end
      end)
    end
  end

  test "empty bash output preserves the function result and permits the next request" do
    sse = [
      sse_json(%{"type" => "response.completed", "response" => %{"status" => "completed"}}),
      "data: [DONE]\n\n"
    ]

    for content <- ["", [], [%{type: :text, text: ""}]] do
      with_request_capture_server(sse, fn base_url, captured ->
        events =
          OpenAIResponses.stream(%{
            model: %{id: "gpt-5", api: "openai", provider: "openai"},
            context: %{
              messages: [
                %{role: :user, content: "Run a silent command"},
                %{
                  role: :assistant,
                  content: [%{type: :tool_call, id: "silent-1", name: "bash", arguments: %{}}]
                },
                %{role: :tool_result, tool_call_id: "silent-1", content: content}
              ],
              tools: []
            },
            options: [api_key: "test-key", base_url: base_url, receive_timeout: 1_000]
          })
          |> Enum.to_list()

        assert [
                 _,
                 %{"type" => "function_call", "call_id" => "silent-1"},
                 %{"type" => "function_call_output", "call_id" => "silent-1", "output" => ""}
               ] =
                 Agent.get(captured, & &1.body["input"])

        assert Enum.any?(events, &match?({:done, :stop, _}, &1))
      end)
    end
  end

  test "invalid protocol requests are non-retryable request errors" do
    error =
      assert_raise ProviderError, fn ->
        OpenAIResponses.stream(%{
          model: %{id: "gpt-5", api: "openai", provider: "openai"},
          context: %{messages: [%{role: :user, content: [%{type: :text, text: nil}]}]},
          options: [api_key: "test-key", base_url: "http://127.0.0.1:1"]
        })
      end

    assert %{kind: :invalid_request, retryable: false} = ProviderError.from_exception(error)
  end

  test "raw replay requires an explicit custom tag even when the bytes are valid JSON" do
    for kind <- [:untagged, :function],
        raw <- ["freeform patch", ~s({"literal":"raw custom input"})] do
      call = %{type: :tool_call, id: "raw-1", name: "apply_patch", arguments: raw}
      call = if kind == :untagged, do: call, else: Map.put(call, :input_kind, kind)

      error =
        assert_raise ProviderError, fn ->
          OpenAIResponses.stream(%{
            model: %{id: "gpt-5", api: "openai", provider: "openai"},
            context: %{messages: [%{role: :assistant, content: [call]}], tools: []},
            options: [api_key: "test", base_url: "http://127.0.0.1:1"]
          })
        end

      assert error.kind == :invalid_request
    end
  end

  test "accepts enum JSON Schema through the Backplane AI protocol request" do
    sse = [
      sse_json(%{"type" => "response.completed", "response" => %{"status" => "completed"}}),
      "data: [DONE]\n\n"
    ]

    with_request_capture_server(sse, fn base_url, captured ->
      OpenAIResponses.stream(%{
        model: %{id: "gpt-5", api: "openai", provider: "openai"},
        context: %{
          messages: [%{role: :user, content: "Pick one"}],
          system_prompt: nil,
          tools: [
            %{
              name: "todo",
              description: "Manage a todo",
              parameters: %{
                "type" => "object",
                "properties" => %{
                  "status" => %{"type" => "string", "enum" => ["todo", "done"]}
                }
              }
            }
          ]
        },
        options: [api_key: "test-key", base_url: base_url, receive_timeout: 1_000]
      })
      |> Enum.to_list()

      assert [%{"type" => "function", "parameters" => parameters}] =
               Agent.get(captured, & &1.body["tools"])

      assert parameters["properties"]["status"]["enum"] == ["todo", "done"]
    end)
  end

  test "completes Responses API function calls after output item metadata arrives" do
    arguments = "{\"path\":\"README.md\"}"

    sse = [
      sse_json(%{"type" => "response.created", "response" => %{"id" => "resp_tool"}}),
      sse_json(%{
        "type" => "response.output_item.added",
        "item" => %{
          "type" => "function_call",
          "id" => "item_1",
          "call_id" => "call_1",
          "name" => "read",
          "arguments" => ""
        }
      }),
      sse_json(%{
        "type" => "response.function_call_arguments.delta",
        "item_id" => "item_1",
        "delta" => "{\"path\":"
      }),
      sse_json(%{
        "type" => "response.function_call_arguments.delta",
        "item_id" => "item_1",
        "delta" => "\"README.md\"}"
      }),
      sse_json(%{
        "type" => "response.function_call_arguments.done",
        "item_id" => "item_1",
        "arguments" => arguments
      }),
      sse_json(%{
        "type" => "response.output_item.done",
        "item" => %{
          "type" => "function_call",
          "id" => "item_1",
          "call_id" => "call_1",
          "name" => "read",
          "arguments" => arguments
        }
      }),
      sse_json(%{
        "type" => "response.completed",
        "response" => %{"status" => "completed", "usage" => %{}}
      }),
      "data: [DONE]\n\n"
    ]

    with_sse_server(sse, fn base_url ->
      events =
        OpenAIResponses.stream(%{
          model: %{id: "gpt-5", api: "openai", provider: "openai"},
          context: %{messages: [], system_prompt: nil, tools: []},
          options: [api_key: "test-key", base_url: base_url, receive_timeout: 1_000]
        })
        |> Enum.to_list()

      assert {:toolcall_end, 0,
              %{id: "call_1", name: "read", arguments: %{"path" => "README.md"}},
              _} =
               Enum.find(events, &match?({:toolcall_end, _, _, _}, &1))

      assert {:done, :tool_use, %{content: [%{id: "call_1", name: "read"}]}} =
               Enum.find(events, &match?({:done, _, _}, &1))
    end)
  end

  test "normalizes Responses API reasoning summary deltas" do
    sse = [
      sse_json(%{"type" => "response.reasoning_summary_text.delta", "delta" => "thinking"}),
      sse_json(%{"type" => "response.completed", "response" => %{"status" => "completed"}}),
      "data: [DONE]\n\n"
    ]

    with_sse_server(sse, fn base_url ->
      events =
        OpenAIResponses.stream(%{
          model: %{id: "gpt-5", api: "openai", provider: "openai"},
          context: %{messages: [], system_prompt: nil, tools: []},
          options: [api_key: "test-key", base_url: base_url, receive_timeout: 1_000]
        })
        |> Enum.to_list()

      assert {:thinking_delta, 0, "thinking", _} =
               Enum.find(events, &match?({:thinking_delta, _, _, _}, &1))
    end)
  end

  test "malformed Responses API tool arguments become a structured stream error" do
    sse = [
      sse_json(%{
        "type" => "response.output_item.added",
        "item" => %{
          "type" => "function_call",
          "id" => "item_bad",
          "call_id" => "call_bad",
          "name" => "read",
          "arguments" => ""
        }
      }),
      sse_json(%{
        "type" => "response.function_call_arguments.done",
        "item_id" => "item_bad",
        "arguments" => "{"
      }),
      sse_json(%{"type" => "response.completed", "response" => %{"status" => "completed"}}),
      "data: [DONE]\n\n"
    ]

    with_sse_server(sse, fn base_url ->
      request =
        Sigma.Ai.ProviderRequest.from_legacy(%{
          model: %{id: "gpt-5", api: "openai", provider: "openai"},
          context: %{messages: [], system_prompt: nil, tools: []},
          options: [api_key: "test-key", base_url: base_url, receive_timeout: 1_000]
        })

      events = Sigma.Ai.Provider.stream(OpenAIResponses, request) |> Enum.to_list()

      assert %Sigma.Ai.ProviderEvent{
               type: :response_failed,
               error: %ProviderError{kind: :malformed_stream, retryable: false}
             } = Enum.find(events, &(&1.type == :response_failed))

      refute Enum.any?(events, &(&1.type == :response_completed))
    end)
  end

  test "preserves native namespaces, custom grammar, output schemas and replay bytes on the wire" do
    raw = "*** Begin Patch\n*** Add File: quote.txt\n+\"hello\"\n*** End Patch"
    format = %{"type" => "grammar", "syntax" => "lark", "definition" => "start: /.+/"}
    output_schema = %{"type" => "object", "properties" => %{"ok" => %{"type" => "boolean"}}}
    image = %{type: :image, data: "iVBORw0KGgo=", mime_type: "image/png"}
    sse = [sse_json(%{"type" => "response.completed", "response" => %{"status" => "completed"}})]

    with_request_capture_server(sse, fn base_url, captured ->
      OpenAIResponses.stream(%{
        model: %{id: "gpt-5", api: "openai", provider: "openai"},
        context: %{
          messages: [
            %{role: :user, content: [image]},
            %{
              role: :assistant,
              content: [
                %{
                  type: :tool_call,
                  id: "patch-1",
                  name: "functions::apply_patch",
                  input_kind: :custom,
                  arguments: raw
                },
                %{
                  type: :tool_call,
                  id: "exec-1",
                  name: "functions::exec_command",
                  arguments: %{"cmd" => "pwd"}
                }
              ]
            },
            %{
              role: :tool_result,
              tool_call_id: "patch-1",
              content: [%{type: :text, text: "patched"}, image]
            },
            %{role: :tool_result, tool_call_id: "exec-1", content: [image]}
          ],
          tools: [
            %{
              type: "custom",
              name: "functions::apply_patch",
              description: "Patch",
              format: format
            },
            %{
              type: "function",
              name: "functions::exec_command",
              description: "Run",
              parameters: %{"type" => "object"},
              output_schema: output_schema
            }
          ]
        },
        options: [api_key: "test", base_url: base_url, receive_timeout: 1_000]
      })
      |> Enum.to_list()

      body = Agent.get(captured, & &1.body)

      assert [
               %{
                 "type" => "namespace",
                 "name" => "functions",
                 "description" => description,
                 "tools" => [custom, function]
               }
             ] =
               body["tools"]

      assert is_binary(description) and String.trim(description) != ""
      assert custom["type"] == "custom"
      assert custom["name"] == "apply_patch"
      assert custom["format"] == format
      refute Map.has_key?(custom, "parameters")
      assert function["name"] == "exec_command"
      assert function["output_schema"] == output_schema
      assert [user, custom_call, function_call, custom_result, function_result] = body["input"]

      assert [%{"type" => "input_image", "image_url" => "data:image/png;base64,iVBORw0KGgo="}] =
               user["content"]

      assert %{
               "type" => "custom_tool_call",
               "namespace" => "functions",
               "name" => "apply_patch",
               "input" => ^raw
             } = custom_call

      assert %{"type" => "function_call", "namespace" => "functions", "name" => "exec_command"} =
               function_call

      assert Jason.decode!(function_call["arguments"]) == %{"cmd" => "pwd"}

      assert %{
               "type" => "custom_tool_call_output",
               "call_id" => "patch-1",
               "output" => [
                 %{"type" => "input_text", "text" => "patched"},
                 %{"type" => "input_image"}
               ]
             } = custom_result

      assert %{
               "type" => "function_call_output",
               "call_id" => "exec-1",
               "output" => [%{"type" => "input_image"}]
             } = function_result
    end)
  end

  test "custom replay infers output kind from history after declarations are removed" do
    raw = "{this is raw input}\nsecond line"
    sse = [sse_json(%{"type" => "response.completed", "response" => %{"status" => "completed"}})]

    with_request_capture_server(sse, fn base_url, captured ->
      OpenAIResponses.stream(%{
        model: %{id: "gpt-5", api: "openai", provider: "openai"},
        context: %{
          tools: [],
          messages: [
            %{
              role: :assistant,
              content: [
                %{
                  type: :tool_call,
                  id: "raw-1",
                  name: "apply_patch",
                  input_kind: :custom,
                  arguments: raw
                }
              ]
            },
            %{role: :tool_result, tool_call_id: "raw-1", content: []}
          ]
        },
        options: [api_key: "test", base_url: base_url, receive_timeout: 1_000]
      })
      |> Enum.to_list()

      assert [%{"input" => ^raw}, %{"type" => "custom_tool_call_output", "output" => ""}] =
               Agent.get(captured, & &1.body["input"])
    end)
  end

  test "custom calls retain raw bytes and canonical identity through every completion path" do
    raw = "*** Begin Patch\n+\"quoted\"\n*** End Patch"

    item = %{
      "type" => "custom_tool_call",
      "id" => "native-1",
      "call_id" => "custom-1",
      "namespace" => "functions",
      "name" => "apply_patch",
      "input" => raw
    }

    for completion <- [:input_done, :item_done, :terminal_output] do
      completion_frames =
        case completion do
          :input_done ->
            [
              sse_json(%{
                "type" => "response.custom_tool_call_input.done",
                "item_id" => "native-1",
                "input" => raw
              }),
              sse_json(%{"type" => "response.output_item.done", "item" => item})
            ]

          :item_done ->
            [sse_json(%{"type" => "response.output_item.done", "item" => item})]

          :terminal_output ->
            []
        end

      sse =
        [
          sse_json(%{
            "type" => "response.output_item.added",
            "item" => Map.put(item, "input", "")
          }),
          sse_json(%{
            "type" => "response.custom_tool_call_input.delta",
            "item_id" => "native-1",
            "delta" => raw
          })
        ] ++
          completion_frames ++
          [
            sse_json(%{
              "type" => "response.completed",
              "response" => %{"status" => "completed", "output" => [item]}
            })
          ]

      with_sse_server(sse, fn base_url ->
        events = normalized_responses_events(base_url)

        assert [
                 %{
                   tool_call: %{
                     arguments: ^raw,
                     input_kind: :custom,
                     name: "functions::apply_patch"
                   }
                 }
               ] = Enum.filter(events, &(&1.type == :tool_call_completed))

        assert Enum.any?(events, &(&1.type == :response_completed))
        refute Enum.any?(events, &(&1.type == :response_failed))
      end)
    end
  end

  test "terminal output can supply a complete custom call without earlier tool frames" do
    item = %{
      "type" => "custom_tool_call",
      "id" => "native-1",
      "call_id" => "custom-1",
      "name" => "apply_patch",
      "input" => "raw\ninput"
    }

    sse = [
      sse_json(%{
        "type" => "response.completed",
        "response" => %{"status" => "completed", "output" => [item]}
      })
    ]

    with_sse_server(sse, fn base_url ->
      events = normalized_responses_events(base_url)

      assert [%{tool_call: %{arguments: "raw\ninput", input_kind: :custom}}] =
               Enum.filter(events, &(&1.type == :tool_call_completed))
    end)
  end

  test "non-completed tool items never become executable through terminal output fallback" do
    for kind <- ["custom_tool_call", "function_call"],
        event <- ["response.completed", "response.incomplete"],
        status <- ["in_progress", "incomplete", "failed"] do
      input =
        if kind == "custom_tool_call",
          do: %{"input" => "partial patch"},
          else: %{"arguments" => "{}"}

      item =
        Map.merge(input, %{
          "type" => kind,
          "id" => "native-1",
          "call_id" => "call-1",
          "name" => "tool",
          "status" => status
        })

      response_status = if event == "response.completed", do: "completed", else: "incomplete"

      sse = [
        sse_json(%{
          "type" => event,
          "response" => %{"status" => response_status, "output" => [item]}
        })
      ]

      with_sse_server(sse, fn base_url ->
        events = normalized_responses_events(base_url)

        assert Enum.any?(
                 events,
                 &(&1.type == :response_failed and &1.error.kind == :malformed_stream)
               )

        refute Enum.any?(events, &(&1.type in [:tool_call_completed, :response_completed]))
      end)
    end
  end

  test "incomplete terminal-only calls without a completed item status are rejected" do
    item = %{
      "type" => "custom_tool_call",
      "id" => "native-1",
      "call_id" => "call-1",
      "name" => "apply_patch",
      "input" => "partial patch"
    }

    sse = [
      sse_json(%{
        "type" => "response.incomplete",
        "response" => %{"status" => "incomplete", "output" => [item]}
      })
    ]

    with_sse_server(sse, fn base_url ->
      events = normalized_responses_events(base_url)
      assert Enum.any?(events, &(&1.type == :response_failed))
      refute Enum.any?(events, &(&1.type in [:tool_call_completed, :response_completed]))
    end)
  end

  test "output item done rejects explicit non-completed tool status" do
    for kind <- ["custom_tool_call", "function_call"] do
      input =
        if kind == "custom_tool_call", do: %{"input" => "patch"}, else: %{"arguments" => "{}"}

      item =
        Map.merge(input, %{
          "type" => kind,
          "id" => "native-1",
          "call_id" => "call-1",
          "name" => "tool"
        })

      sse = [
        sse_json(%{"type" => "response.output_item.added", "item" => item}),
        sse_json(%{
          "type" => "response.output_item.done",
          "item" => Map.put(item, "status", "in_progress")
        })
      ]

      with_sse_server(sse, fn base_url ->
        events = normalized_responses_events(base_url)
        assert Enum.any?(events, &(&1.type == :response_failed))
        refute Enum.any?(events, &(&1.type in [:tool_call_completed, :response_completed]))
      end)
    end
  end

  test "duplicate call IDs cannot retag earlier function results during replay" do
    error =
      assert_raise ProviderError, fn ->
        OpenAIResponses.stream(%{
          model: %{id: "gpt-5", api: "openai", provider: "openai"},
          context: %{
            tools: [],
            messages: [
              %{
                role: :assistant,
                content: [%{type: :tool_call, id: "reused", name: "function", arguments: %{}}]
              },
              %{role: :tool_result, tool_call_id: "reused", content: "function result"},
              %{
                role: :assistant,
                content: [
                  %{
                    type: :tool_call,
                    id: "reused",
                    name: "apply_patch",
                    input_kind: :custom,
                    arguments: "raw"
                  }
                ]
              }
            ]
          },
          options: [api_key: "test", base_url: "http://127.0.0.1:1"]
        })
      end

    assert error.kind == :invalid_request
    assert error.message =~ "Duplicate tool name or call ID"
  end

  test "malformed custom tool streams fail without an executable call or completion" do
    item = %{
      "type" => "custom_tool_call",
      "id" => "native-1",
      "call_id" => "custom-1",
      "namespace" => "functions",
      "name" => "apply_patch",
      "input" => ""
    }

    added = sse_json(%{"type" => "response.output_item.added", "item" => item})

    terminal =
      sse_json(%{"type" => "response.completed", "response" => %{"status" => "completed"}})

    cases = [
      [
        added,
        sse_json(%{
          "type" => "response.custom_tool_call_input.delta",
          "item_id" => "native-1",
          "delta" => %{}
        }),
        terminal
      ],
      [
        added,
        sse_json(%{
          "type" => "response.custom_tool_call_input.done",
          "item_id" => "native-1",
          "input" => %{}
        }),
        terminal
      ],
      [
        added,
        sse_json(%{
          "type" => "response.custom_tool_call_input.delta",
          "item_id" => "missing",
          "delta" => "raw"
        }),
        terminal
      ],
      [
        added,
        sse_json(%{
          "type" => "response.function_call_arguments.delta",
          "item_id" => "native-1",
          "delta" => "{}"
        }),
        terminal
      ],
      [
        added,
        sse_json(%{
          "type" => "response.output_item.done",
          "item" => Map.merge(item, %{"namespace" => "other", "input" => "raw"})
        }),
        terminal
      ],
      [
        added,
        sse_json(%{
          "type" => "response.custom_tool_call_input.delta",
          "item_id" => "native-1",
          "delta" => "first"
        }),
        sse_json(%{
          "type" => "response.custom_tool_call_input.done",
          "item_id" => "native-1",
          "input" => "different"
        }),
        terminal
      ],
      [
        added,
        sse_json(%{
          "type" => "response.custom_tool_call_input.delta",
          "item_id" => "native-1",
          "delta" => "truncated"
        })
      ],
      [
        added,
        sse_json(%{
          "type" => "response.custom_tool_call_input.delta",
          "item_id" => "native-1",
          "delta" => "truncated"
        }),
        sse_json(%{"type" => "response.incomplete", "response" => %{"status" => "incomplete"}})
      ]
    ]

    for sse <- cases do
      with_sse_server(sse, fn base_url ->
        events = normalized_responses_events(base_url)

        assert Enum.any?(
                 events,
                 &(&1.type == :response_failed and &1.error.kind == :malformed_stream)
               )

        refute Enum.any?(events, &(&1.type in [:tool_call_completed, :response_completed]))
      end)
    end
  end

  test "Chat and Anthropic reject native custom and namespaced declarations or replay before HTTP" do
    contexts = [
      %{
        messages: [],
        tools: [%{type: "custom", name: "apply_patch", format: %{"type" => "text"}}]
      },
      %{messages: [], tools: [%{name: "functions::exec_command", parameters: %{}}]},
      %{
        messages: [],
        tools: [%{name: "exec_command", parameters: %{}, output_schema: %{"type" => "object"}}]
      },
      %{
        messages: [
          %{
            role: :assistant,
            content: [
              %{
                type: :tool_call,
                id: "raw-1",
                name: "apply_patch",
                input_kind: :custom,
                arguments: "raw"
              }
            ]
          }
        ],
        tools: []
      }
    ]

    for provider <- [OpenAI, Sigma.Ai.Providers.Anthropic], context <- contexts do
      error =
        assert_raise ProviderError, fn ->
          provider.stream(%{
            model: %{id: "test", api: "test", provider: "test"},
            context: context,
            options: [api_key: "test", base_url: "http://127.0.0.1:1"]
          })
        end

      assert error.kind == :invalid_request
      refute error.retryable
      assert error.message =~ "use OpenAI Responses"
    end
  end

  defp normalized_responses_events(base_url) do
    request =
      Sigma.Ai.ProviderRequest.from_legacy(%{
        model: %{id: "gpt-5", api: "openai", provider: "openai"},
        context: %{messages: [], tools: [], catalog_revision: 0},
        options: [api_key: "test", base_url: base_url, receive_timeout: 1_000]
      })

    Sigma.Ai.Provider.stream(OpenAIResponses, request) |> Enum.to_list()
  end

  test "Responses API preserves streamed arguments when output_item.done has empty arguments and repairs invalid escapes" do
    raw_arguments = ~s({"command":"grep -i \\"beam\\|mix\\"","note":"col1\tcol2"})

    sse = [
      sse_json(%{"type" => "response.created", "response" => %{"id" => "resp_repair"}}),
      sse_json(%{
        "type" => "response.output_item.added",
        "item" => %{
          "type" => "function_call",
          "id" => "item_repair",
          "call_id" => "call_repair",
          "name" => "bash",
          "arguments" => ""
        }
      }),
      sse_json(%{
        "type" => "response.function_call_arguments.delta",
        "delta" => raw_arguments
      }),
      sse_json(%{
        "type" => "response.output_item.done",
        "item" => %{
          "type" => "function_call",
          "id" => "item_repair",
          "call_id" => "call_repair",
          "name" => "bash",
          "arguments" => ""
        }
      }),
      sse_json(%{
        "type" => "response.output_item.added",
        "item" => %{
          "type" => "function_call",
          "id" => "item_empty",
          "call_id" => "call_empty",
          "name" => "ping",
          "arguments" => ""
        }
      }),
      sse_json(%{
        "type" => "response.output_item.done",
        "item" => %{
          "type" => "function_call",
          "id" => "item_empty",
          "call_id" => "call_empty",
          "name" => "ping",
          "arguments" => ""
        }
      }),
      sse_json(%{"type" => "response.completed", "response" => %{"status" => "completed"}}),
      "data: [DONE]\n\n"
    ]

    with_sse_server(sse, fn base_url ->
      events =
        OpenAIResponses.stream(%{
          model: %{id: "gpt-5", api: "openai", provider: "openai"},
          context: %{messages: [], system_prompt: nil, tools: []},
          options: [api_key: "test-key", base_url: base_url, receive_timeout: 1_000]
        })
        |> Enum.to_list()

      assert {:toolcall_end, 0,
              %{
                id: "call_repair",
                name: "bash",
                arguments: %{"command" => "grep -i \"beam\\|mix\"", "note" => "col1\tcol2"}
              },
              _} =
               Enum.find(events, &match?({:toolcall_end, 0, _, _}, &1))

      assert {:toolcall_end, 1, %{id: "call_empty", name: "ping", arguments: %{}}, _} =
               Enum.find(events, &match?({:toolcall_end, 1, _, _}, &1))
    end)
  end

  test "Responses requires a terminal response even after completed output items" do
    incomplete_sse = [
      sse_json(%{"type" => "response.created", "response" => %{"id" => "resp_inc"}}),
      sse_json(%{"type" => "response.output_text.delta", "delta" => "partial output"}),
      sse_json(%{
        "type" => "response.incomplete",
        "response" => %{
          "id" => "resp_inc",
          "status" => "incomplete",
          "usage" => %{"input_tokens" => 20, "output_tokens" => 5}
        }
      }),
      "data: [DONE]\n\n"
    ]

    with_sse_server(incomplete_sse, fn base_url ->
      events =
        OpenAIResponses.stream(%{
          model: %{id: "gpt-5", api: "openai", provider: "openai"},
          context: %{messages: [], system_prompt: nil, tools: []},
          options: [api_key: "test-key", base_url: base_url, receive_timeout: 1_000]
        })
        |> Enum.to_list()

      assert {:done, :length,
              %{
                response_id: "resp_inc",
                usage: %{
                  input: nil,
                  input_tokens: 20,
                  output: 5,
                  cache_read: nil,
                  total_tokens: 25
                }
              } = message} =
               Enum.find(events, &match?({:done, _, _}, &1))

      assert %{input_tokens: 20, output_tokens: 5, usage_status: :reported} =
               Sigma.Ai.ProviderUsage.normalize(message.usage)

      refute Enum.any?(events, &match?({:provider_error, _}, &1))
    end)

    eof_after_item_done_sse = [
      sse_json(%{"type" => "response.created", "response" => %{"id" => "resp_eof"}}),
      sse_json(%{
        "type" => "response.output_item.done",
        "item" => %{
          "type" => "function_call",
          "id" => "item_eof",
          "call_id" => "call_eof",
          "name" => "read",
          "arguments" => "{\"path\":\"README.md\"}"
        }
      })
    ]

    with_sse_server(eof_after_item_done_sse, fn base_url ->
      events =
        OpenAIResponses.stream(%{
          model: %{id: "gpt-5", api: "openai", provider: "openai"},
          context: %{messages: [], system_prompt: nil, tools: []},
          options: [api_key: "test-key", base_url: base_url, receive_timeout: 1_000]
        })
        |> Enum.to_list()

      refute Enum.any?(events, &match?({:done, _, _}, &1))

      assert {:provider_error, %ProviderError{kind: :malformed_stream, retryable: false}} =
               Enum.find(events, &match?({:provider_error, _}, &1))
    end)
  end

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

  test "encodes image blocks in rich OpenAI user content" do
    sse = [
      ~s(data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n),
      "data: [DONE]\n\n"
    ]

    image = %{type: :image, data: "iVBORw0KGgo=", mime_type: "image/png"}

    with_capture_server(sse, fn base_url, captured ->
      OpenAI.stream(%{
        model: %{id: "gpt-test", api: "openai", provider: "openai"},
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
               "type" => "image_url",
               "image_url" => %{"url" => "data:image/png;base64,iVBORw0KGgo="}
             }
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

  test "keeps text deltas separate when they follow streamed tool calls" do
    sse = [
      sse_json(%{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "call_then_text",
                  "type" => "function",
                  "function" => %{"name" => "read", "arguments" => "{\"path\":\"README.md\"}"}
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
            "delta" => %{"content" => "After the tool call"},
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

      assert {:text_delta, 1, "After the tool call", _} =
               Enum.find(events, &match?({:text_delta, _, _, _}, &1))

      assert {:done, :tool_use,
              %{content: [%{type: :tool_call}, %{type: :text, text: "After the tool call"}]}} =
               Enum.find(events, &match?({:done, _, _}, &1))

      refute Enum.any?(events, &match?({:provider_error, _}, &1))
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

  test "malformed finalized tool arguments fail the normalized stream" do
    sse = [
      sse_json(%{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "call-invalid",
                  "type" => "function",
                  "function" => %{"name" => "bash", "arguments" => "{"}
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
      request =
        Sigma.Ai.ProviderRequest.from_legacy(%{
          model: %{id: "gpt-test", api: "openai", provider: "openai"},
          context: %{messages: [], system_prompt: nil, tools: []},
          options: [api_key: "test-key", base_url: base_url, receive_timeout: 1_000]
        })

      events = Sigma.Ai.Provider.stream(OpenAI, request) |> Enum.to_list()

      refute Enum.any?(events, &(&1.type == :tool_call_completed))

      assert %Sigma.Ai.ProviderEvent{
               type: :response_failed,
               error: %Sigma.Ai.ProviderError{kind: :malformed_stream}
             } = Enum.find(events, &(&1.type == :response_failed))
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

  test "rejects pending streamed tool calls when the transport closes without a terminal frame" do
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

      refute Enum.any?(events, &match?({:toolcall_end, 0, _, _}, &1))

      assert {:provider_error, %ProviderError{kind: :malformed_stream}} =
               Enum.find(events, &match?({:provider_error, _}, &1))

      refute Enum.any?(events, &match?({:done, _, _}, &1))
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
      fn event, measurements, metadata, config ->
        # Filter by this test's session_id so concurrent async LLM tests cannot
        # pollute the collected event list (Enum.find would otherwise pick them).
        if metadata[:session_id] == config.session_id do
          Agent.update(config.events, &[{event, measurements, metadata} | &1])
        end
      end,
      %{session_id: session_id, events: telemetry_events}
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
              provider: "openai"
            }} = Enum.find(events, &match?({[:sigma, :llm, :request, :start], _, _}, &1))

    assert {[:sigma, :llm, :request, :stop], %{duration: duration},
            %{
              session_id: ^session_id,
              model: "gpt-test",
              usage: %{input: 10, output: 1, total_tokens: 11},
              stop_reason: :stop
            }} = Enum.find(events, &match?({[:sigma, :llm, :request, :stop], _, _}, &1))

    assert is_integer(duration)
  end

  test "shared reserve matches the real Chat and Responses HTTP output caps" do
    fixtures = [
      {OpenAI, "max_tokens", ["data: [DONE]\n\n"]},
      {OpenAIResponses, "max_output_tokens",
       [
         sse_json(%{"type" => "response.completed", "response" => %{"status" => "completed"}}),
         "data: [DONE]\n\n"
       ]}
    ]

    for {provider, field, sse} <- fixtures,
        {model, request_options} <- [
          {%{"maxTokens" => 6_000, id: "output-context"}, []},
          {%{id: "output-context", max_tokens: 6_000}, [maxTokens: 2_000]},
          {%{id: "output-context"}, []}
        ] do
      model = Map.merge(%{api: "openai", provider: "openai"}, model)

      with_capture_server(sse, fn base_url, captured ->
        options =
          Keyword.merge(request_options,
            api_key: "test-key",
            base_url: base_url,
            receive_timeout: 1_000
          )

        reserve = Sigma.Ai.Provider.output_token_limit(provider, model, options)

        provider.stream(%{model: model, context: %{messages: [], tools: []}, options: options})
        |> Enum.to_list()

        assert Agent.get(captured, & &1[field]) == reserve

        assert reserve ==
                 (request_options[:maxTokens] || model[:max_tokens] || model["maxTokens"])
      end)
    end
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

  test "omits authorization header when api key is blank" do
    sse = [
      ~s(data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n),
      "data: [DONE]\n\n"
    ]

    with_request_capture_server(sse, fn base_url, captured ->
      OpenAI.stream(%{
        model: %{id: "gpt-test", api: "openai", provider: "openai"},
        context: %{messages: [], system_prompt: nil, tools: []},
        options: [api_key: "", base_url: base_url, receive_timeout: 1_000]
      })
      |> Enum.to_list()

      assert %{headers: headers} = Agent.get(captured, & &1)
      refute Map.has_key?(headers, "authorization")
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
        assert_raise ProviderError, fn ->
          OpenAI.stream(%{
            model: %{id: "MiniMax-M3", api: "openai", provider: "openai"},
            context: %{messages: [], system_prompt: nil, tools: []},
            options: [api_key: "test-key", base_url: base_url, receive_timeout: 1_000]
          })
          |> Enum.to_list()
        end

      assert error.kind == :context_limit
      assert error.status == 400
      assert error.code == "context_length_exceeded"
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
