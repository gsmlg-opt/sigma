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
             EntryEncoder.encode(
               {:message_end, Message.user("message-1", "hello")},
               "leaf-1",
               true
             )

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

  test "encodes skill invocation records as durable journal entries" do
    assert {:ok, entry} =
             EntryEncoder.encode(
               {:skill_invocation, %{"requestId" => "inv-1", "state" => "preparing"}},
               "active-leaf",
               true
             )

    assert entry["type"] == "skill_invocation"
    assert entry["invocation"]["requestId"] == "inv-1"
  end

  test "encodes operational metrics facts as non-message journal entries" do
    assert {:ok, entry} =
             EntryEncoder.encode(
               {:metrics, :request_finished,
                %{request_id: "req-1", revision: 1, status: :completed, output_tokens_total: 12}},
               "leaf-1",
               true
             )

    assert %{
             "type" => "metrics",
             "fact" => "request_finished",
             "parentId" => "leaf-1",
             "data" => %{
               "request_id" => "req-1",
               "revision" => 1,
               "status" => "completed",
               "output_tokens_total" => 12
             }
           } = entry

    assert :ok = Jason.encode!(entry) |> then(fn _ -> :ok end)

    assert {:ok, %{"type" => "metrics", "fact" => "request_started"}} =
             EntryEncoder.encode({:request_started, %{request_id: "req-1"}}, "leaf-1", true)

    assert {:ok, %{"type" => "metrics", "fact" => "turn_finished"}} =
             EntryEncoder.encode(
               {:turn_finished, %{turn_id: "turn-1", status: :completed}},
               "leaf-1",
               true
             )
  end

  test "normalizes nested error terms into JSON-safe metrics data" do
    reason =
      {:event_persistence_failed, :runtime,
       {:storage_append_failed,
        %Protocol.UndefinedError{
          protocol: Jason.Encoder,
          value: {:storage_append_failed, :enoent},
          description: "not encodable"
        }}}

    assert {:ok, entry} =
             EntryEncoder.encode(
               {:metrics, :turn_finished,
                %{turn_id: "turn-error", revision: 1, status: :failed, reason: reason}},
               "leaf-1",
               true
             )

    assert ["event_persistence_failed", "runtime", ["storage_append_failed", error]] =
             entry["data"]["reason"]

    assert error["__struct__"] == "Elixir.Protocol.UndefinedError"
    assert error["value"] == ["storage_append_failed", "enoent"]
    assert is_binary(Jason.encode!(entry))
  end

  test "preserves null and boolean metrics values while encoding atom labels" do
    assert {:ok, entry} =
             EntryEncoder.encode(
               {:metrics, :turn_finished,
                %{
                  turn_id: "turn-1",
                  status: :completed,
                  reason: nil,
                  metadata: %{
                    allowed: true,
                    cancelled: false,
                    values: [nil, true, false, :unknown],
                    result: {:ok, nil, false},
                    error: %Protocol.UndefinedError{protocol: Jason.Encoder, value: nil}
                  }
                }},
               "leaf-1",
               true
             )

    persisted = entry |> Jason.encode!() |> Jason.decode!()

    assert %{
             "status" => "completed",
             "reason" => nil,
             "metadata" => %{
               "allowed" => true,
               "cancelled" => false,
               "values" => [nil, true, false, "unknown"],
               "result" => ["ok", nil, false],
               "error" => %{"protocol" => "Elixir.Jason.Encoder", "value" => nil}
             }
           } = persisted["data"]
  end

  @tag :tmp_dir
  test "JSONL metrics recovery preserves unknown values and live summaries", %{tmp_dir: tmp_dir} do
    assert {:ok, header} = EntryEncoder.encode({:agent_start, "/repo"}, nil, false)

    request = %{
      request_id: "req-unknown",
      session_id: header["id"],
      turn_id: "turn-1",
      message_id: nil,
      revision: 0,
      purpose: :turn,
      status: :completed,
      usage_status: :unknown,
      input_tokens_total: nil,
      output_tokens_total: nil,
      elapsed_ms: nil,
      retry_of: nil,
      provenance: nil
    }

    turn = %{
      turn_id: "turn-1",
      session_id: header["id"],
      revision: 0,
      status: :completed,
      started_at: nil,
      finished_at: nil,
      wall_time_ms: nil,
      terminal_reason: nil
    }

    facts = [{:request_finished, request}, {:turn_finished, turn}]
    live = Sigma.Session.Metrics.reduce_all(facts, header["id"])
    path = Path.join(tmp_dir, "unknown-metrics.jsonl")
    assert :ok = Sigma.Session.Storage.JsonlFile.append(path, header)

    for fact <- facts do
      assert {:ok, entry} = EntryEncoder.encode(fact, nil, true)
      assert :ok = Sigma.Session.Storage.JsonlFile.append(path, entry)
    end

    assert {:ok, restored} = Sigma.Session.Log.snapshot(path)
    assert restored.diagnostics == []

    assert %{
             usage_status: :unknown,
             input_tokens_total: nil,
             output_tokens_total: nil,
             elapsed_ms: nil,
             message_id: nil,
             retry_of: nil,
             provenance: nil
           } = restored.metrics.requests["req-unknown"]

    assert Sigma.Session.Metrics.snapshot(restored.metrics) ==
             Sigma.Session.Metrics.snapshot(live)
  end
end
