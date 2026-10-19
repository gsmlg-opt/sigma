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
        content =
          for block <- 1..20, do: %{type: :text, text: String.duplicate("x", 2_048) <> "#{block}"}

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
    assert payload["protocolVersion"] == Envelope.version()
    assert "metrics.v1" in payload["capabilities"]
    assert "subscription.resync.v1" in payload["capabilities"]
    assert payload["messagesTruncated"]
    assert length(payload["messages"]) == 5
    assert length(payload["branchEntryIds"]) == 50
    assert {:ok, event} = Envelope.event("session.snapshot", "large-session", payload)
    assert {:ok, encoded} = Codec.encode(event)
    assert byte_size(encoded) <= 65_536

    huge_mcp_snapshot = %{
      snapshot
      | mcp_server_ids: Enum.map(1..100, &(String.duplicate("m", 1_000) <> "#{&1}"))
    }

    huge_mcp_payload = ProtocolEventMapper.snapshot_payload(huge_mcp_snapshot)
    assert {:ok, event} = Envelope.event("session.snapshot", "large-session", huge_mcp_payload)
    assert {:ok, _encoded} = Codec.encode(event)
  end

  test "structured operation conflicts retain safe details" do
    error = ProtocolEventMapper.public_error({:revision_conflict, %{expected: 2, actual: 3}})

    assert error.code == "revision_conflict"
    assert error.details == %{"expected" => 2, "actual" => 3}
  end

  test "metrics snapshots expose deterministic bounded request and turn summaries" do
    requests =
      Map.new(1..15, fn index ->
        id = "request-#{String.pad_leading(to_string(index), 2, "0")}"

        {id,
         %{
           request_id: id,
           status: :completed,
           started_at: "2026-09-09T10:#{String.pad_leading(to_string(index), 2, "0")}:00Z",
           provider: String.duplicate("p", 256),
           model: String.duplicate("模型", 128)
         }}
      end)

    turns =
      Map.new(1..15, fn index ->
        id = "turn-#{String.pad_leading(to_string(index), 2, "0")}"

        {id,
         %{
           status: :completed,
           started_at: "2026-09-09T10:#{String.pad_leading(to_string(index), 2, "0")}:00Z",
           request_ids: ["request-#{index}"]
         }}
      end)

    projection =
      ProtocolEventMapper.metrics_snapshot(%{
        session_id: "session-1",
        requests: requests,
        turns: turns
      })

    assert [
             %{"request_id" => "request-15", "status" => "completed"},
             %{"request_id" => "request-14"}
             | request_summaries
           ] = projection["requestSummaries"]

    assert length(request_summaries) == 8
    assert List.last(projection["requestSummaries"])["request_id"] == "request-06"
    assert byte_size(hd(projection["requestSummaries"])["provider"]) == 128
    assert byte_size(hd(projection["requestSummaries"])["model"]) <= 128
    assert String.valid?(hd(projection["requestSummaries"])["model"])

    assert [%{"turn_id" => "turn-15"}, %{"turn_id" => "turn-14"} | turn_summaries] =
             projection["turnSummaries"]

    assert length(turn_summaries) == 8
    assert List.last(projection["turnSummaries"])["turn_id"] == "turn-06"
  end

  test "maps durable metrics facts to a versioned string-keyed event" do
    {event, turn_id} =
      ProtocolEventMapper.map(
        {:metrics, :request_finished,
         %{
           request_id: "request-1",
           session_id: "session-1",
           revision: 1,
           status: :completed,
           input_tokens_total: 12,
           output_tokens_total: 3
         }},
        "session-1",
        "turn-1"
      )

    assert turn_id == "turn-1"
    assert event.type == "metrics.changed"
    assert event.payload["schemaVersion"] == 1
    assert event.payload["fact"] == "request_finished"
    assert event.payload["data"]["request_id"] == "request-1"
    assert event.payload["data"]["status"] == "completed"
    assert Enum.all?(Map.keys(event.payload["data"]), &is_binary/1)
    assert {:ok, encoded} = Codec.encode(event)
    assert {:ok, ^event} = Codec.decode(encoded)
  end

  test "maps durable turn lifecycle facts without dropping unknown reasons" do
    {started, "turn-1"} =
      ProtocolEventMapper.map(
        {:metrics, :turn_started,
         %{
           turn_id: "turn-1",
           session_id: "session-1",
           revision: 0,
           status: :running,
           reason: nil,
           started_at: "2026-09-09T10:00:00Z"
         }},
        "session-1",
        "turn-1"
      )

    assert started.type == "metrics.changed"
    assert started.payload["fact"] == "turn_started"
    assert started.payload["data"]["reason"] == nil

    {finished, "turn-1"} =
      ProtocolEventMapper.map(
        {:metrics, :turn_finished,
         %{
           turn_id: "turn-1",
           session_id: "session-1",
           revision: 1,
           status: :failed,
           reason: :unknown,
           wall_ms: 25
         }},
        "session-1",
        "turn-1"
      )

    assert finished.payload["fact"] == "turn_finished"
    assert finished.payload["data"]["status"] == "failed"
    assert finished.payload["data"]["reason"] == "unknown"
    assert finished.payload["data"]["wall_ms"] == 25
  end

  test "rejects unknown metrics facts at the closed protocol boundary" do
    assert {nil, "turn-1"} =
             ProtocolEventMapper.map(
               {:metrics, :unapproved_fact, %{request_id: "request-1", revision: 1}},
               "session-1",
               "turn-1"
             )
  end

  test "subagent events and capable snapshots use only validated DTO fields" do
    fact = %{
      fact: :registered,
      revision: 1,
      event_id: "event",
      observer_incarnation: "owner",
      data: %{
        agent_id: "child",
        run_id: "run",
        incarnation: 1,
        status: :pending_init,
        credentials: "private-secret",
        pid: self(),
        reference: make_ref(),
        callback: fn -> :secret end
      }
    }

    assert {%{type: "subagents.changed"} = event, "turn"} =
             ProtocolEventMapper.map({:subagent, fact}, "session", "turn")

    assert event.payload["revision"] == 1
    assert {:ok, encoded} = Codec.encode(event)
    refute encoded =~ "private-secret"
    refute encoded =~ "#PID"

    assert {nil, "turn"} =
             ProtocolEventMapper.map(
               {:subagent, put_in(fact, [:data, :agent_id], self())},
               "session",
               "turn"
             )

    {:ok, safe_fact} = Sigma.Protocol.Subagents.event(fact)

    row =
      Map.merge(
        safe_fact.data,
        Map.take(safe_fact, [:revision, :event_id, :observer_incarnation])
      )

    roster = %{
      revision: 1,
      agents: [row],
      counts: %{created: 1, executing: 0, pending: 1, stopped: 0, unknown: 0},
      credentials: "private-secret"
    }

    snapshot = %Sigma.Session.Snapshot{session_id: "session", subagents: roster}
    refute Map.has_key?(ProtocolEventMapper.snapshot_payload(snapshot), "subagents")
    capable = ProtocolEventMapper.snapshot_payload(snapshot, "session", ["subagents.v1"])
    assert capable["subagents"]["counts"]["pending"] == 1
    refute inspect(capable) =~ "private-secret"
  end
end
