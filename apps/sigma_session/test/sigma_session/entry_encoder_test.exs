defmodule Sigma.Session.EntryEncoderTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.Message
  alias Sigma.Session.EntryEncoder

  test "encodes a header and durable entries with the supplied parent" do
    assert {:ok, header} = EntryEncoder.encode({:agent_start, "/repo"}, nil, false)

    assert %{
             "type" => "session",
             "version" => 3,
             "id" => header_id,
             "cwd" => "/repo",
             "timestamp" => header_timestamp
           } = header

    assert is_binary(header_id)
    assert {:ok, _timestamp, 0} = DateTime.from_iso8601(header_timestamp)

    assert {:ok, message_entry} =
             EntryEncoder.encode({:message_end, Message.user("message-1", "hello")}, "leaf-1", true)

    assert %{
             "type" => "message",
             "parentId" => "leaf-1",
             "message" => %{"id" => "message-1", "role" => :user, "content" => "hello"}
           } = message_entry

    assert {:ok, compaction_entry} =
             EntryEncoder.encode(
               {:compact,
                %Message{
                  id: "summary-1",
                  role: :compaction_summary,
                  content: "summary"
                }, "kept-entry"},
               message_entry["id"],
               true
             )

    assert %{
             "type" => "compaction",
             "parentId" => message_parent,
             "summary" => "summary",
             "firstKeptEntryId" => "kept-entry"
           } = compaction_entry

    assert message_parent == message_entry["id"]
  end

  test "encodes behavioral state on the current active leaf" do
    events_and_payloads = [
      {{:model_change, "anthropic", "claude/opus"},
       %{"type" => "model_change", "model" => "anthropic/claude/opus"}},
      {{:thinking_level_change, "high", "auto"},
       %{
         "type" => "thinking_level_change",
         "thinkingLevel" => "high",
         "configured" => "auto"
       }},
      {{:service_tier_change, "priority"},
       %{"type" => "service_tier_change", "serviceTier" => "priority"}},
      {{:mcp_server_selection_change, ["filesystem", "notes"]},
       %{
         "type" => "mcp_server_selection_change",
         "serverIds" => ["filesystem", "notes"]
       }},
      {{:mode_change, "plan", %{"depth" => "high"}},
       %{"type" => "mode_change", "mode" => "plan", "data" => %{"depth" => "high"}}},
      {{:branch_summary, "entry-1", "summary"},
       %{"type" => "branch_summary", "fromId" => "entry-1", "summary" => "summary"}}
    ]

    for {event, payload} <- events_and_payloads do
      assert {:ok, entry} = EntryEncoder.encode(event, "active-leaf", true)
      assert entry["parentId"] == "active-leaf"
      assert Map.take(entry, Map.keys(payload)) == payload
    end
  end

  test "ignores transient runtime events and duplicate agent starts" do
    assert :ignored = EntryEncoder.encode({:message_start, %{}}, nil, false)
    assert :ignored = EntryEncoder.encode({:message_update, %{}, %{}}, nil, false)
    assert :ignored = EntryEncoder.encode({:turn_start}, nil, false)
    assert :ignored = EntryEncoder.encode({:agent_start, "/repo"}, nil, true)
  end
end
