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

  test "decodes the generic status type through an explicit mapping" do
    entry =
      message_entry(%{
        "role" => "status",
        "content" => "working",
        "status_type" => "status"
      })

    assert {:ok, %Message{role: :status, status_type: :status}} = EntryDecoder.message(entry)
  end

  test "rejects unknown status types without creating atoms" do
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
      {Map.put(valid, "id", 123), :invalid_message_id},
      {Map.delete(valid, "timestamp"), :invalid_message_timestamp},
      {Map.put(valid, "timestamp", "1"), :invalid_message_timestamp}
    ]

    for {message, expected_error} <- cases do
      assert {:error, ^expected_error} = EntryDecoder.message(%{"message" => message})
    end
  end

  test "uses the journal timestamp for legacy messages without a nested timestamp" do
    message =
      valid_message(%{
        "role" => "assistant",
        "content" => "legacy response",
        "usage" => %{"input" => 10, "cost" => %{"total" => 0.1}}
      })
      |> Map.delete("timestamp")

    entry = %{"timestamp" => "2026-07-21T00:00:00Z", "message" => message}

    assert {:ok,
            %Message{
              timestamp: 1_784_592_000_000,
              content: "legacy response",
              usage: %{input: 10, cost: %{total: 0.1}}
            }} = EntryDecoder.message(entry)
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
      {"tool_result", [thinking], :tool_result}
    ]

    for {role, content, role_atom} <- cases do
      entry = message_entry(%{"role" => role, "content" => content})
      assert {:error, {:invalid_content_for_role, ^role_atom}} = EntryDecoder.message(entry)
    end
  end

  test "rejects malformed required content item fields" do
    cases = [
      {%{"type" => "text"}, {:invalid_content_field, :text, :text}},
      {%{"type" => "thinking", "thinking" => 42}, {:invalid_content_field, :thinking, :thinking}},
      {%{"type" => "image", "data" => "image"}, {:invalid_content_field, :image, :mime_type}},
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
    invalid_cost = message_entry(%{"usage" => %{"cost" => %{"total" => "0.1"}}})

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
