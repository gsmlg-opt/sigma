defmodule Sigma.Session.EntryDecoderTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.Message
  alias Sigma.Session.EntryDecoder

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
end
