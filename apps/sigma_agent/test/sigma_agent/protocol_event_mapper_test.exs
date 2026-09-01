defmodule Sigma.Agent.ProtocolEventMapperTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.ProtocolEventMapper
  alias Sigma.Protocol.{Codec, Envelope}

  test "queued follow-up keeps the current stream correlated to its active turn" do
    accepted =
      {:prompt_admitted, :accepted, %{message_id: "initial-message", turn_id: "turn-current"}}

    {_event, active_turn_id} = ProtocolEventMapper.map(accepted, "session", nil)
    assert active_turn_id == "turn-current"

    follow_up =
      {:prompt_admitted, :queued_as_follow_up,
       %{message_id: "follow-up-message", turn_id: "turn-future"}}

    {admission_event, active_turn_id} =
      ProtocolEventMapper.map(follow_up, "session", active_turn_id)

    assert admission_event.turn_id == "turn-future"
    assert active_turn_id == "turn-current"

    {terminal_event, active_turn_id} =
      ProtocolEventMapper.map({:turn_completed, "turn-current"}, "session", active_turn_id)

    assert terminal_event.turn_id == "turn-current"
    assert active_turn_id == "turn-current"

    {nil, active_turn_id} =
      ProtocolEventMapper.map(
        {:prompt_consumed, :follow_up, %{turn_id: "turn-future"}},
        "session",
        active_turn_id
      )

    {started_event, active_turn_id} =
      ProtocolEventMapper.map({:turn_start}, "session", active_turn_id)

    assert started_event.turn_id == "turn-future"
    assert active_turn_id == "turn-future"
  end

  test "large reconnect snapshots are truncated into an encodable bounded envelope" do
    messages =
      for index <- 1..30 do
        content = for block <- 1..20, do: %{type: :text, text: String.duplicate("x", 2_048) <> "#{block}"}
        Sigma.Agent.Message.user("message-#{index}", content)
      end

    snapshot = %Sigma.Session.Snapshot{
      session_id: "large-session",
      cwd: "/tmp/repo",
      active_leaf_id: "leaf",
      branch_entry_ids: Enum.map(1..500, &"entry-#{&1}"),
      messages: messages
    }

    payload = ProtocolEventMapper.snapshot_payload(snapshot)
    assert payload["messagesTruncated"]
    assert length(payload["messages"]) == 5
    assert length(payload["branchEntryIds"]) == 50
    assert {:ok, event} = Envelope.event("session.snapshot", "large-session", payload)
    assert {:ok, encoded} = Codec.encode(event)
    assert byte_size(encoded) <= 65_536

    huge_mcp_snapshot = %{
      snapshot
      | mcp_server_ids: Enum.map(1..100, &String.duplicate("m", 1_000) <> "#{&1}")
    }

    huge_mcp_payload = ProtocolEventMapper.snapshot_payload(huge_mcp_snapshot)
    assert {:ok, event} = Envelope.event("session.snapshot", "large-session", huge_mcp_payload)
    assert {:ok, _encoded} = Codec.encode(event)
  end
end
