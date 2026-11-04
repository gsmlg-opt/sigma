defmodule Sigma.Session.EntryDecoderTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.Message
  alias Sigma.Session.{EntryDecoder, EntryEncoder}

  test "raw custom tool input survives JSONL encoding and replay without JSON decoding" do
    for input <- [
          "*** Begin Patch\n*** Add File: 中文.txt\n+hello\n*** End Patch\n",
          ~s({"literal":"this is custom input, not function arguments"})
        ] do
      message =
        Message.assistant("custom-message", %{
          content: [
            %{
              type: :tool_call,
              id: "patch-call",
              name: "apply_patch",
              input_kind: :custom,
              arguments: input
            }
          ],
          stop_reason: :tool_use,
          timestamp: 123
        })

      assert {:ok, entry} = EntryEncoder.encode({:message_end, message}, "previous", true)
      wire_entry = entry |> Jason.encode!() |> Jason.decode!()
      assert {:ok, replayed} = EntryDecoder.message(wire_entry)
      assert replayed.content == message.content
      assert replayed.stop_reason == :tool_use
    end
  end

  test "custom input tags reject mismatched kinds without creating atoms" do
    unknown = "custom_kind_#{System.unique_integer([:positive])}"

    for {kind, arguments, field} <- [
          {"custom", %{}, :arguments},
          {"function", "raw", :arguments},
          {unknown, "raw", :input_kind}
        ] do
      entry = %{
        "message" => %{
          "id" => "invalid-custom",
          "role" => "assistant",
          "timestamp" => 1,
          "content" => [
            %{
              "type" => "tool_call",
              "id" => "call",
              "name" => "apply_patch",
              "input_kind" => kind,
              "arguments" => arguments
            }
          ]
        }
      }

      assert {:error, {:invalid_content_field, :tool_call, ^field}} = EntryDecoder.message(entry)
    end

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    entry = %{
      "message" => %{
        "id" => "untagged-custom",
        "role" => "assistant",
        "timestamp" => 1,
        "content" => [
          %{
            "type" => "tool_call",
            "id" => "call",
            "name" => "apply_patch",
            "arguments" => ~s({"raw":"custom input"})
          }
        ]
      }
    }

    assert {:error, {:invalid_content_field, :tool_call, :input_kind}} =
             EntryDecoder.message(entry)
  end

  test "namespaced calls and image result metadata retain their canonical journal values" do
    message =
      Message.assistant("clock-message", %{
        content: [%{type: :tool_call, id: "clock-call", name: "clock::curr_time", arguments: %{}}],
        timestamp: 123
      })

    assert {:ok, entry} = EntryEncoder.encode({:message_end, message}, nil, true)
    assert {:ok, replayed} = entry |> Jason.encode!() |> Jason.decode!() |> EntryDecoder.message()
    assert replayed.content == message.content

    image = %{type: :image, data: Base.encode64(<<137, 80, 78, 71>>), mime_type: "image/png"}

    result =
      Message.tool_result("image-message", %{
        tool_call_id: "image-call",
        tool_name: "view_image",
        content: [image],
        metadata: %{structured_result: %{path: "plot.png", bytes: 4, detail: "original"}},
        timestamp: 124
      })

    assert {:ok, entry} = EntryEncoder.encode({:message_end, result}, entry["id"], true)
    assert {:ok, replayed} = entry |> Jason.encode!() |> Jason.decode!() |> EntryDecoder.message()
    assert replayed.content == [image]
    assert replayed.metadata["structured_result"]["detail"] == "original"
  end

  test "decodes known message, content, usage, and enum fields" do
    entry = %{
      "type" => "message",
      "id" => "entry-1",
      "parentId" => nil,
      "timestamp" => "2026-07-21T00:00:00Z",
      "message" => %{
        "id" => "message-1",
        "role" => "assistant",
        "content" => [
          %{"type" => "text", "text" => "hello"},
          %{
            "type" => "tool_call",
            "id" => "call-1",
            "name" => "read",
            "arguments" => %{"path" => "README.md"}
          }
        ],
        "timestamp" => 1_784_592_000_000,
        "stop_reason" => "tool_use",
        "usage" => %{
          "input" => 10,
          "output" => 2,
          "cache_read" => 1,
          "cache_write" => 0,
          "total_tokens" => 13,
          "cost" => %{"input" => 0.1, "output" => 0.2, "total" => 0.3}
        }
      }
    }

    assert {:ok,
            %Message{
              id: "message-1",
              role: :assistant,
              stop_reason: :tool_use,
              content: [
                %{type: :text, text: "hello"},
                %{
                  type: :tool_call,
                  id: "call-1",
                  name: "read",
                  arguments: %{"path" => "README.md"}
                }
              ],
              usage: %{
                input: 10,
                output: 2,
                cache_read: 1,
                cache_write: 0,
                total_tokens: 13,
                cost: %{input: 0.1, output: 0.2, total: 0.3}
              }
            }} = EntryDecoder.message(entry)
  end

  test "rejects unknown enum values without creating atoms" do
    unknown = "journal_unknown_#{System.unique_integer([:positive])}"

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    entry = %{
      "message" => %{
        "id" => "message-1",
        "role" => unknown,
        "content" => "hello",
        "timestamp" => 1
      }
    }

    assert {:error, {:unknown_role, ^unknown}} = EntryDecoder.message(entry)
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  test "ignores unknown top-level message keys without creating atoms" do
    unknown = "journal_unknown_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    entry = %{
      "message" => %{
        "id" => "message-1",
        "role" => "user",
        "content" => "hello",
        "timestamp" => 1,
        unknown => "ignored"
      }
    }

    assert {:ok, %Message{role: :user, content: "hello"}} = EntryDecoder.message(entry)
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  test "decodes compaction summaries from an entry timestamp" do
    entry = %{
      "id" => "compact-1",
      "timestamp" => "2026-07-21T00:00:00Z",
      "summary" => "Earlier work"
    }

    assert {:ok,
            %Message{
              id: "compact-1",
              role: :compaction_summary,
              content: "Earlier work",
              timestamp: 1_784_592_000_000
            }} = EntryDecoder.compaction(entry)
  end

  test "rejects unknown metrics facts without creating atoms" do
    unknown = "future_metrics_fact_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    assert {:error, :invalid_metrics} =
             EntryDecoder.metrics(%{"type" => "metrics", "fact" => unknown, "data" => %{}})

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  test "decodes closed turn lifecycle facts without converting data keys to atoms" do
    unknown_key = "future_turn_field_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_key) end

    entry = %{
      "type" => "metrics",
      "fact" => "turn_finished",
      "data" => %{
        "turn_id" => "turn-1",
        "status" => "completed",
        "purpose" => "auxiliary",
        unknown_key => "retained"
      }
    }

    assert {:ok,
            {:turn_finished,
             %{
               "turn_id" => "turn-1",
               "status" => :completed,
               "purpose" => :auxiliary,
               ^unknown_key => "retained"
             }}} = EntryDecoder.metrics(entry)

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_key) end
  end

  test "allows an explicitly nil status type" do
    entry =
      message_entry(%{
        "role" => "status",
        "content" => "working",
        "status_type" => nil
      })

    assert {:ok, %Message{role: :status, status_type: nil}} = EntryDecoder.message(entry)
  end

  test "rejects unknown status types without creating atoms" do
    assert {:error, {:unknown_status_type, "status"}} =
             EntryDecoder.message(message_entry(%{"role" => "status", "status_type" => "status"}))

    unknown = "journal_unknown_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    entry = message_entry(%{"role" => "status", "status_type" => unknown})

    assert {:error, {:unknown_status_type, ^unknown}} = EntryDecoder.message(entry)
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  test "rejects missing and invalid message ids and timestamps" do
    valid = valid_message()

    cases = [
      {Map.delete(valid, "id"), :invalid_message_id},
      {Map.put(valid, "id", ""), :invalid_message_id},
      {Map.put(valid, "id", 123), :invalid_message_id},
      {Map.delete(valid, "timestamp"), :invalid_message_timestamp},
      {Map.put(valid, "timestamp", "1"), :invalid_message_timestamp}
    ]

    for {message, expected_error} <- cases do
      assert {:error, ^expected_error} = EntryDecoder.message(%{"message" => message})
    end
  end

  test "validates every copied message field against the Message type" do
    nullable_strings = [
      {"api", :api},
      {"provider", :provider},
      {"model", :model},
      {"response_model", :response_model},
      {"response_id", :response_id},
      {"error_message", :error_message},
      {"tool_call_id", :tool_call_id},
      {"tool_name", :tool_name},
      {"command", :command},
      {"summary", :summary},
      {"from_id", :from_id}
    ]

    for {field, expected_field} <- nullable_strings do
      assert {:ok, %Message{}} = EntryDecoder.message(message_entry(%{field => nil}))

      assert {:error, {:invalid_message_field, ^expected_field}} =
               EntryDecoder.message(message_entry(%{field => 42}))
    end

    for {field, expected_field} <- [{"exit_code", :exit_code}, {"tokens_before", :tokens_before}] do
      assert {:ok, %Message{}} = EntryDecoder.message(message_entry(%{field => nil}))

      assert {:error, {:invalid_message_field, ^expected_field}} =
               EntryDecoder.message(message_entry(%{field => "1"}))
    end

    assert {:ok, %Message{is_error: nil}} =
             EntryDecoder.message(message_entry(%{"is_error" => nil}))

    assert {:error, {:invalid_message_field, :is_error}} =
             EntryDecoder.message(message_entry(%{"is_error" => "false"}))

    assert {:ok, %Message{attachments: nil}} =
             EntryDecoder.message(message_entry(%{"attachments" => nil}))

    assert {:error, {:invalid_message_field, :attachments}} =
             EntryDecoder.message(message_entry(%{"attachments" => %{}}))

    assert {:ok, %Message{metadata: %{}}} = EntryDecoder.message(message_entry(%{}))

    assert {:error, {:invalid_message_field, :metadata}} =
             EntryDecoder.message(message_entry(%{"metadata" => nil}))

    assert {:ok, %Message{redacted: false}} = EntryDecoder.message(message_entry(%{}))

    assert {:error, {:invalid_message_field, :redacted}} =
             EntryDecoder.message(message_entry(%{"redacted" => "false"}))
  end

  test "uses the journal timestamp for legacy messages without a nested timestamp" do
    message =
      valid_message(%{
        "role" => "assistant",
        "content" => "legacy response",
        "usage" => %{"input" => 10, "output" => 2, "cost" => %{"total" => 0.1}}
      })
      |> Map.delete("timestamp")

    entry = %{"timestamp" => "2026-07-21T00:00:00Z", "message" => message}

    assert {:ok,
            %Message{
              timestamp: 1_784_592_000_000,
              content: "legacy response",
              usage: %{input: 10, output: 2, cost: %{total: 0.1}}
            }} = EntryDecoder.message(entry)
  end

  test "requires input and output when usage is present" do
    empty_usage = message_entry(%{"usage" => %{}})
    input_only = message_entry(%{"usage" => %{"input" => 10}})

    assert {:error, {:invalid_usage_field, :input}} = EntryDecoder.message(empty_usage)
    assert {:error, {:invalid_usage_field, :output}} = EntryDecoder.message(input_only)
  end

  @tag :tmp_dir
  test "real Responses unknown and partial usage survives JSONL and Writer recovery", %{
    tmp_dir: dir
  } do
    wire_usages = [
      nil,
      %{"input_tokens" => 10, "output_tokens" => 2},
      %{
        "input_tokens" => 80,
        "output_tokens" => 5,
        "input_tokens_details" => %{"cached_tokens" => 20},
        "output_tokens_details" => %{"reasoning_tokens" => 2}
      }
    ]

    usages = Enum.map(wire_usages, &Sigma.Ai.ProviderUsage.from_wire(&1, :openai_responses))
    [unknown, partial, cached] = usages
    assert is_nil(unknown.input) and is_nil(unknown.output)
    assert is_nil(partial.input) and partial.input_tokens == 10 and partial.output == 2
    assert cached.input == 60 and cached.input_tokens == 80 and cached.reasoning_tokens == 2

    path = Path.join(dir, "nullable-usage.jsonl")
    opts = [storage_id: path, session_id: "nullable-usage", cwd: dir]
    writer = start_supervised!({Sigma.Session.Writer, opts})

    messages =
      Enum.with_index(usages, fn usage, index ->
        message =
          Message.assistant("usage-#{index}", %{
            content: [%{type: :text, text: "Answer #{index}"}],
            timestamp: 123 + index,
            stop_reason: :stop,
            usage: usage
          })

        assert {:ok, entry} = EntryEncoder.encode({:message_end, message}, nil, true)

        assert {:ok, decoded} =
                 entry |> Jason.encode!() |> Jason.decode!() |> EntryDecoder.message()

        assert decoded.usage ==
                 Map.put(usage, :provenance, %{
                   "source" => "provider",
                   "input_tokens" => "included"
                 })

        assert Sigma.Ai.ProviderUsage.normalize(decoded.usage) ==
                 Sigma.Ai.ProviderUsage.normalize(usage)

        assert {:ok, _entry_id} = Sigma.Session.Writer.append(writer, {:message_end, message})
        decoded
      end)

    assert :ok = stop_supervised(Sigma.Session.Writer)
    assert {:ok, snapshot} = Sigma.Session.Log.snapshot(path)
    assert snapshot.diagnostics == []
    assert Enum.map(snapshot.messages, & &1.usage) == Enum.map(messages, & &1.usage)

    reopened = start_supervised!({Sigma.Session.Writer, opts})
    assert {:ok, restored} = Sigma.Session.Writer.context_snapshot(reopened)
    assert Enum.map(restored.messages, & &1.usage) == Enum.map(messages, & &1.usage)
  end

  test "nullable usage still rejects malformed and negative known counters" do
    for {key, field} <- [
          {"input", :input},
          {"input_tokens", :input_tokens},
          {"output", :output},
          {"cache_read", :cache_read},
          {"cache_write", :cache_write},
          {"reasoning_tokens", :reasoning_tokens},
          {"total_tokens", :total_tokens}
        ],
        value <- ["10", -1, 1.5, true, %{}, []] do
      usage = %{"input" => nil, "output" => nil} |> Map.put(key, value)

      assert {:error, {:invalid_usage_field, ^field}} =
               EntryDecoder.message(message_entry(%{"usage" => usage}))
    end
  end

  test "usage provenance keeps only semantic JSON fields without creating atoms" do
    unknown = "usage_provenance_#{System.unique_integer([:positive])}"

    usage = %{
      "input" => nil,
      "output" => nil,
      "provenance" => %{"source" => "provider", "input_tokens" => "included", unknown => "secret"}
    }

    assert {:ok, decoded} = EntryDecoder.message(message_entry(%{"usage" => usage}))
    assert decoded.usage.provenance == %{"source" => "provider", "input_tokens" => "included"}
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    for provenance <- [%{"source" => unknown}, "secret", [], 42] do
      assert {:error, {:invalid_usage_field, :provenance}} =
               EntryDecoder.message(
                 message_entry(%{"usage" => Map.put(usage, "provenance", provenance)})
               )
    end

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  test "requires non-empty tool result identities" do
    valid = %{
      "role" => "tool_result",
      "content" => "result",
      "tool_call_id" => "call-1",
      "tool_name" => "read"
    }

    cases = [
      {Map.delete(valid, "tool_call_id"), :tool_call_id},
      {Map.put(valid, "tool_call_id", ""), :tool_call_id},
      {Map.delete(valid, "tool_name"), :tool_name},
      {Map.put(valid, "tool_name", ""), :tool_name}
    ]

    for {overrides, field} <- cases do
      assert {:error, {:invalid_tool_result_field, ^field}} =
               EntryDecoder.message(message_entry(overrides))
    end
  end

  test "validates tool result is_error while preserving nil" do
    valid = %{
      "role" => "tool_result",
      "content" => "result",
      "tool_call_id" => "call-1",
      "tool_name" => "read"
    }

    assert {:ok, %Message{is_error: nil}} = EntryDecoder.message(message_entry(valid))

    assert {:ok, %Message{is_error: nil}} =
             EntryDecoder.message(message_entry(Map.put(valid, "is_error", nil)))

    assert {:ok, %Message{is_error: false}} =
             EntryDecoder.message(message_entry(Map.put(valid, "is_error", false)))

    assert {:error, {:invalid_tool_result_field, :is_error}} =
             EntryDecoder.message(message_entry(Map.put(valid, "is_error", "false")))
  end

  test "rejects content that violates role contracts" do
    tool_call = %{
      "type" => "tool_call",
      "id" => "call-1",
      "name" => "read",
      "arguments" => %{}
    }

    thinking = %{"type" => "thinking", "thinking" => "hmm", "redacted" => false}

    cases = [
      {"system", nil, :system},
      {"user", nil, :user},
      {"user", [tool_call], :user},
      {"tool_result", [thinking], :tool_result},
      {"thought", [%{"type" => "image", "data" => "a", "mime_type" => "image/png"}], :thought},
      {"status", nil, :status},
      {"status", [thinking], :status},
      {"notification", nil, :notification},
      {"notification", [thinking], :notification},
      {"branch_summary", [thinking], :branch_summary},
      {"compaction_summary", nil, :compaction_summary},
      {"bash_execution", [thinking], :bash_execution},
      {"artifact", [thinking], :artifact}
    ]

    for {role, content, role_atom} <- cases do
      overrides =
        if role == "tool_result" do
          %{
            "role" => role,
            "content" => content,
            "tool_call_id" => "call-1",
            "tool_name" => "read"
          }
        else
          %{"role" => role, "content" => content}
        end

      entry = message_entry(overrides)
      assert {:error, {:invalid_content_for_role, ^role_atom}} = EntryDecoder.message(entry)
    end
  end

  test "accepts structurally safe content for every known role" do
    image = [%{"type" => "image", "data" => "a", "mime_type" => "image/png"}]
    assistant = [%{"type" => "thinking", "thinking" => "hmm"}]

    cases = [
      %{"role" => "system", "content" => "instructions"},
      %{"role" => "user", "content" => image},
      %{"role" => "assistant", "content" => assistant},
      %{
        "role" => "tool_result",
        "content" => image,
        "tool_call_id" => "call-1",
        "tool_name" => "read"
      },
      %{"role" => "thought", "content" => "thinking"},
      %{"role" => "status", "content" => "working"},
      %{"role" => "notification", "content" => "done"},
      %{
        "role" => "branch_summary",
        "content" => nil,
        "summary" => "earlier branch",
        "from_id" => "message-1"
      },
      %{"role" => "compaction_summary", "content" => "summary"},
      %{"role" => "bash_execution", "content" => nil, "command" => "mix test", "exit_code" => 0},
      %{"role" => "artifact", "content" => nil, "attachments" => []}
    ]

    for overrides <- cases do
      assert {:ok, %Message{}} = EntryDecoder.message(message_entry(overrides))
    end
  end

  test "rejects malformed required content item fields" do
    cases = [
      {%{"type" => "text"}, {:invalid_content_field, :text, :text}},
      {%{"type" => "thinking", "thinking" => 42}, {:invalid_content_field, :thinking, :thinking}},
      {%{"type" => "image", "data" => "image"}, {:invalid_content_field, :image, :mime_type}},
      {%{"type" => "tool_call", "id" => "", "name" => "read", "arguments" => %{}},
       {:invalid_content_field, :tool_call, :id}},
      {%{"type" => "tool_call", "id" => "call-1", "name" => "", "arguments" => %{}},
       {:invalid_content_field, :tool_call, :name}},
      {%{"type" => "tool_call", "id" => "call-1", "name" => "read", "arguments" => []},
       {:invalid_content_field, :tool_call, :arguments}}
    ]

    for {content_item, expected_error} <- cases do
      entry = message_entry(%{"role" => "assistant", "content" => [content_item]})
      assert {:error, ^expected_error} = EntryDecoder.message(entry)
    end
  end

  test "rejects malformed known usage and cost fields" do
    invalid_usage = message_entry(%{"usage" => %{"input" => "10"}})

    invalid_cost =
      message_entry(%{
        "usage" => %{"input" => 10, "output" => 2, "cost" => %{"total" => "0.1"}}
      })

    assert {:error, {:invalid_usage_field, :input}} = EntryDecoder.message(invalid_usage)
    assert {:error, {:invalid_cost_field, :total}} = EntryDecoder.message(invalid_cost)
  end

  test "rejects unknown optional enums without creating atoms" do
    for {field, error_tag} <- [
          {"stop_reason", :unknown_stop_reason},
          {"level", :unknown_level}
        ] do
      unknown = "journal_unknown_#{System.unique_integer([:positive])}"
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

      assert {:error, {^error_tag, ^unknown}} =
               EntryDecoder.message(message_entry(%{field => unknown}))

      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
    end
  end

  test "ignores unknown nested content keys without creating atoms" do
    unknown = "journal_unknown_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    entry =
      message_entry(%{
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => "hello", unknown => "ignored"}]
      })

    assert {:ok, %Message{content: [%{type: :text, text: "hello"}]}} =
             EntryDecoder.message(entry)

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  test "rejects unknown nested content types without creating atoms" do
    unknown = "journal_unknown_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    entry = message_entry(%{"role" => "assistant", "content" => [%{"type" => unknown}]})

    assert {:error, {:unknown_content_type, ^unknown}} = EntryDecoder.message(entry)
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  defp message_entry(overrides), do: %{"message" => valid_message(overrides)}

  defp valid_message(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "message-1",
        "role" => "user",
        "content" => "hello",
        "timestamp" => 1
      },
      overrides
    )
  end
end
