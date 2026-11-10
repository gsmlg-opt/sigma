defmodule Sigma.Session.MetricsTest do
  use ExUnit.Case, async: true

  alias Sigma.Session.Metrics

  test "projects request summaries with the assistant association and footer fields" do
    metrics =
      Metrics.new("s1")
      |> Metrics.reduce(
        {:request_finished,
         %{
           request_id: "r1",
           message_id: "assistant-1",
           session_id: "s1",
           provider: "anthropic",
           model: "opus",
           status: :completed,
           input_tokens_total: 1,
           output_tokens_total: 2,
           elapsed_ms: 100,
           first_output_ms: 20,
           ttft_ms: 30
         }}
      )

    assert %{
             message_id: "assistant-1",
             provider: "anthropic",
             model: "opus",
             status: :completed,
             input_tokens_total: 1,
             output_tokens_total: 2,
             elapsed_ms: 100,
             first_output_ms: 20,
             ttft_ms: 30
           } = Metrics.snapshot(metrics).requests["r1"]
  end

  test "preserves request identity, timing, and provider details across higher revisions" do
    state =
      Metrics.new("s1")
      |> Metrics.reduce(
        {:request_started,
         %{
           request_id: "r1",
           message_id: "assistant-1",
           session_id: "s1",
           turn_id: "turn-1",
           provider: "anthropic",
           model: "opus",
           purpose: :auxiliary,
           revision: 0,
           status: :running,
           started_at: "2026-09-09T10:00:00Z",
           first_output_ms: 20,
           ttft_ms: 25,
           retry_of: "r0"
         }}
      )
      |> Metrics.reduce(
        {:request_usage,
         %{
           request_id: "r1",
           revision: 1,
           status: :completed,
           input_tokens_total: 10,
           output_tokens_total: 4,
           visible_output_tokens: 3,
           provenance: %{source: :provider}
         }}
      )

    assert %{
             message_id: "assistant-1",
             session_id: "s1",
             turn_id: "turn-1",
             provider: "anthropic",
             model: "opus",
             purpose: :auxiliary,
             revision: 1,
             started_at: "2026-09-09T10:00:00Z",
             first_output_ms: 20,
             ttft_ms: 25,
             visible_output_tokens: 3,
             provenance: %{source: :provider},
             retry_of: "r0"
           } = state.requests["r1"]
  end

  test "normalizes totals without double counting cache or reasoning" do
    state =
      Metrics.new("s1")
      |> Metrics.reduce(
        {:request_finished,
         %{
           request_id: "r1",
           session_id: "s1",
           revision: 1,
           input_tokens_total: 40_000,
           output_tokens_total: 1_000,
           cache_read_tokens: 30_000,
           reasoning_tokens: 400,
           elapsed_ms: 1_000
         }}
      )

    usage = Metrics.snapshot(state).own_usage
    assert usage.input_tokens_total == 40_000
    assert usage.output_tokens_total == 1_000
    assert usage.total_tokens == 41_000
    assert usage.cache_read_tokens == 30_000
    assert usage.cache_write_tokens == nil
    assert usage.reasoning_tokens == 400
  end

  test "merges a terminal fact into its same-revision start" do
    state =
      Metrics.new("s1")
      |> Metrics.reduce(
        {:request_started, %{request_id: "r1", session_id: "s1", revision: 0, status: :running}}
      )
      |> Metrics.reduce(
        {:request_finished,
         %{
           request_id: "r1",
           session_id: "s1",
           revision: 0,
           status: :completed,
           input_tokens_total: 2,
           output_tokens_total: 3,
           elapsed_ms: 10
         }}
      )

    assert Metrics.snapshot(state).own_usage.total_tokens == 5
  end

  test "restart finalization interrupts only requests without a terminal fact" do
    state =
      Metrics.new("s1")
      |> Metrics.reduce(
        {:request_started,
         %{
           request_id: "unfinished",
           session_id: "s1",
           status: :running,
           elapsed_ms: 250,
           input_tokens_total: nil,
           output_tokens_total: nil
         }}
      )
      |> Metrics.reduce(
        {:request_finished,
         %{
           request_id: "finished",
           session_id: "s1",
           status: :completed,
           elapsed_ms: 100,
           input_tokens_total: 2,
           output_tokens_total: 3
         }}
      )
      |> Metrics.finalize_in_flight()

    assert %{status: :interrupted, usage_status: :unknown, elapsed_ms: nil} =
             state.requests["unfinished"]

    assert %{status: :completed, input_tokens_total: 2, output_tokens_total: 3} =
             state.requests["finished"]

    assert Metrics.snapshot(state).coverage == %{known: 1, total: 2, ratio: 0.5}
  end

  test "live finalization preserves only the exact current session request and turn" do
    state =
      Metrics.reduce_all(
        for {session_id, turn_id, request_id} <- [
              {"s1", "active-turn", "active-request"},
              {"s1", "active-turn", "previous-request"},
              {"s1", "old-turn", "old-request"},
              {"inherited", "foreign-turn", "foreign-request"}
            ],
            fact <- [
              {:turn_started, %{session_id: session_id, turn_id: turn_id}},
              {:request_started,
               %{
                 session_id: session_id,
                 turn_id: turn_id,
                 request_id: request_id,
                 status: :running,
                 usage_status: :reported,
                 input_tokens_total: 12,
                 output_tokens_total: 3
               }}
            ] do
          fact
        end,
        "s1"
      )

    live =
      Metrics.finalize_in_flight(state,
        active_turn_id: "active-turn",
        active_request_id: "active-request"
      )

    assert live.requests["active-request"] == state.requests["active-request"]
    assert live.turns["active-turn"] == state.turns["active-turn"]

    for request_id <- ["previous-request", "old-request", "foreign-request"] do
      assert live.requests[request_id].status == :interrupted
    end

    assert live.turns["old-turn"].status == :interrupted
    assert live.turns["foreign-turn"].status == :interrupted
    assert Metrics.snapshot(live).turns["active-turn"].status == :running
    assert Metrics.snapshot(live).own_usage == Metrics.snapshot(state).own_usage

    inherited =
      Metrics.finalize_in_flight(state,
        active_turn_id: "foreign-turn",
        active_request_id: "foreign-request"
      )

    assert inherited.requests["foreign-request"].status == :interrupted
    assert inherited.turns["foreign-turn"].status == :interrupted

    mismatched =
      Metrics.finalize_in_flight(state,
        active_turn_id: "old-turn",
        active_request_id: "active-request"
      )

    assert mismatched.requests["active-request"].status == :interrupted
  end

  test "live finalization does not revive terminal facts or preserve absent identities" do
    state =
      Metrics.new("s1")
      |> Metrics.reduce({:turn_finished, %{turn_id: "t1", session_id: "s1", status: :cancelled}})
      |> Metrics.reduce(
        {:request_finished,
         %{request_id: "r1", turn_id: "t1", session_id: "s1", status: :completed}}
      )
      |> Metrics.reduce(
        {:request_started, %{request_id: "aux", session_id: "s1", status: :started}}
      )

    live = Metrics.finalize_in_flight(state, active_turn_id: "t1", active_request_id: "r1")
    assert live.turns["t1"].status == :cancelled
    assert live.requests["r1"].status == :completed
    assert live.requests["aux"].status == :interrupted
    assert Metrics.finalize_in_flight(state).requests["aux"].status == :interrupted

    auxiliary = Metrics.finalize_in_flight(state, active_request_id: "aux")
    assert auxiliary.requests["aux"] == state.requests["aux"]
  end

  test "uses weighted throughput and replaces duplicate revisions" do
    state =
      Metrics.new("s1")
      |> Metrics.reduce(
        {:request_finished,
         %{
           request_id: "r1",
           session_id: "s1",
           revision: 1,
           output_tokens_total: 10,
           input_tokens_total: 1,
           elapsed_ms: 100
         }}
      )
      |> Metrics.reduce(
        {:request_finished,
         %{
           request_id: "r2",
           session_id: "s1",
           revision: 1,
           output_tokens_total: 1_000,
           input_tokens_total: 1,
           elapsed_ms: 20_000
         }}
      )
      |> Metrics.reduce(
        {:request_finished,
         %{
           request_id: "r2",
           session_id: "s1",
           revision: 1,
           output_tokens_total: 9_000,
           input_tokens_total: 9_000,
           elapsed_ms: 20_000
         }}
      )
      |> Metrics.reduce(
        {:request_finished,
         %{
           request_id: "r2",
           session_id: "s1",
           revision: 2,
           output_tokens_total: 1_000,
           input_tokens_total: 1,
           elapsed_ms: 20_000
         }}
      )

    assert_in_delta Metrics.snapshot(state).average_llm_tok_s, 50.25, 0.01
    assert state.facts == 4
  end

  test "excludes requests without valid duration from both throughput terms" do
    state =
      Metrics.new("s1")
      |> Metrics.reduce(
        {:request_finished,
         %{
           request_id: "timed",
           session_id: "s1",
           input_tokens_total: 1,
           output_tokens_total: 10,
           elapsed_ms: 1_000
         }}
      )
      |> Metrics.reduce(
        {:request_finished,
         %{
           request_id: "untimed",
           session_id: "s1",
           input_tokens_total: 1,
           output_tokens_total: 1_000,
           elapsed_ms: nil
         }}
      )

    usage = Metrics.snapshot(state).own_usage
    assert usage.output_tokens_total == 1_010
    assert usage.throughput == 10.0
    assert usage.throughput_requests == 1
  end

  test "groups multiple requests and tool timing by turn without changing LLM throughput" do
    state =
      Metrics.new("s1")
      |> Metrics.reduce(
        {:turn_started,
         %{
           turn_id: "turn-1",
           session_id: "s1",
           started_at: "2026-09-09T10:00:00Z"
         }}
      )
      |> Metrics.reduce(
        {:request_finished,
         %{
           request_id: "request-1",
           message_id: "assistant-1",
           session_id: "s1",
           turn_id: "turn-1",
           input_tokens_total: 1,
           output_tokens_total: 2,
           elapsed_ms: 1_000
         }}
      )
      |> Metrics.reduce(
        {:request_finished,
         %{
           request_id: "request-2",
           message_id: "assistant-2",
           session_id: "s1",
           turn_id: "turn-1",
           input_tokens_total: 2,
           output_tokens_total: 3,
           elapsed_ms: 1_500
         }}
      )
      |> Metrics.reduce(
        {:tool_finished,
         %{tool_id: "tool-1", turn_id: "turn-1", status: :completed, elapsed_ms: 30_000}}
      )
      |> Metrics.reduce(
        {:request_finished,
         %{
           request_id: "request-2",
           message_id: "assistant-2",
           session_id: "s1",
           turn_id: "turn-1",
           input_tokens_total: 2,
           output_tokens_total: 3,
           elapsed_ms: 1_500
         }}
      )
      |> Metrics.reduce(
        {:turn_finished,
         %{
           turn_id: "turn-1",
           session_id: "s1",
           revision: 1,
           finished_at: "2026-09-09T10:00:32.500Z"
         }}
      )

    assert %{
             request_count: 2,
             request_ids: ["request-1", "request-2"],
             tool_count: 1,
             tool_elapsed_ms: 30_000,
             wall_time_ms: 32_500,
             input_tokens_total: 3,
             output_tokens_total: 5,
             total_tokens: 8,
             throughput: 2.0
           } =
             Metrics.snapshot(state).turns["turn-1"]

    assert map_size(state.requests) == 2
    assert state.facts == 5
  end

  test "keeps missing usage partial and separates inherited requests" do
    state =
      Metrics.new("child")
      |> Metrics.reduce(
        {:request_finished,
         %{
           request_id: "parent-r",
           session_id: "parent",
           revision: 1,
           output_tokens_total: 4,
           input_tokens_total: 2,
           elapsed_ms: 100
         }}
      )
      |> Metrics.reduce(
        {:request_finished,
         %{
           request_id: "child-r",
           session_id: "child",
           revision: 1,
           output_tokens_total: 2,
           input_tokens_total: nil,
           elapsed_ms: 100
         }}
      )

    snapshot = Metrics.snapshot(state)
    assert snapshot.own_usage.total_tokens == nil
    assert snapshot.own_usage.input_tokens_total == nil
    assert snapshot.own_usage.partial?
    assert snapshot.inherited_usage.total_tokens == 6
    assert snapshot.coverage == %{known: 0, total: 1, ratio: 0.0}
  end

  test "does not infer active lineage when request ids are unavailable" do
    state =
      Metrics.reduce(
        Metrics.new("s1"),
        {:request_finished,
         %{
           request_id: "r1",
           session_id: "s1",
           input_tokens_total: 1,
           output_tokens_total: 2
         }}
      )

    assert Metrics.snapshot(state).active_lineage_usage == nil
    assert Metrics.snapshot(state, active_request_ids: []).active_lineage_usage.total_tokens == 0
  end

  test "rebinds cached ownership when an existing runtime assigns the session id" do
    state =
      Metrics.new()
      |> Metrics.reduce(
        {:request_finished,
         %{
           request_id: "r1",
           session_id: "s1",
           input_tokens_total: 2,
           output_tokens_total: 3
         }}
      )

    assert Metrics.snapshot(state).inherited_usage.total_tokens == 5

    rebound = %{state | session_id: "s1"}
    assert Metrics.snapshot(rebound).own_usage.total_tokens == 5
    assert Metrics.snapshot(rebound).inherited_usage.total_tokens == 0
  end

  test "ignores an inherited lifecycle until local turn data exists" do
    state =
      Metrics.reduce(
        Metrics.new("child"),
        {:turn_finished,
         %{
           turn_id: "parent-turn",
           session_id: "parent",
           started_at: "2026-09-09T10:00:00Z",
           finished_at: "2026-09-09T10:00:01Z"
         }}
      )

    assert Metrics.snapshot(state).turns == %{}
  end

  test "deduplicates revisioned tool facts and retains request association" do
    state =
      Metrics.new("s1")
      |> Metrics.reduce(
        {:tool_finished,
         %{
           tool_id: "tool-1",
           request_id: "request-1",
           turn_id: "turn-1",
           revision: 0,
           started_at: "2026-09-09T10:00:01Z"
         }}
      )
      |> Metrics.reduce(
        {:tool_finished,
         %{
           tool_id: "tool-1",
           revision: 1,
           status: :completed,
           finished_at: "2026-09-09T10:00:02Z",
           elapsed_ms: 1_000
         }}
      )
      |> Metrics.reduce(
        {:tool_finished,
         %{
           tool_id: "tool-1",
           revision: 1,
           status: :completed,
           finished_at: "2026-09-09T10:00:02Z",
           elapsed_ms: 1_000
         }}
      )

    assert %{
             request_id: "request-1",
             turn_id: "turn-1",
             revision: 1,
             status: :completed,
             started_at: "2026-09-09T10:00:01Z",
             finished_at: "2026-09-09T10:00:02Z"
           } = state.tools["tool-1"]

    assert state.facts == 2
  end

  test "projects revisioned lifecycle facts and full turn wall time" do
    state =
      Metrics.new("s1")
      |> Metrics.reduce(
        {:turn_started,
         %{
           turn_id: "turn-1",
           session_id: "s1",
           revision: 0,
           started_at: "2026-09-09T10:00:00Z",
           source_message_id: "message-1",
           source_checkpoint_id: "checkpoint-1",
           retry_of_turn_id: "turn-0"
         }}
      )
      |> Metrics.reduce(
        {:turn_finished,
         %{
           turn_id: "turn-1",
           session_id: "s1",
           revision: 1,
           finished_at: "2026-09-09T10:00:03Z",
           terminal_reason: "stop",
           provenance: %{source: :agent}
         }}
      )

    assert %{
             status: :completed,
             revision: 1,
             started_at: "2026-09-09T10:00:00Z",
             finished_at: "2026-09-09T10:00:03Z",
             wall_time_ms: 3_000,
             terminal_reason: "stop",
             source_message_id: "message-1",
             source_checkpoint_id: "checkpoint-1",
             retry_of_turn_id: "turn-0",
             total_tokens: nil,
             partial?: true
           } = Metrics.snapshot(state).turns["turn-1"]
  end

  # Sigma.Agent persists turn_finished as `reason`/`wall_ms`; the projection must
  # surface them so a failed turn shows why it failed.
  test "projects the agent's persisted turn_finished reason and wall time" do
    state =
      Metrics.new("s1")
      |> Metrics.reduce(
        {"turn_started",
         %{"turn_id" => "turn-1", "session_id" => "s1", "started_at" => "2026-09-09T10:00:00Z"}}
      )
      |> Metrics.reduce(
        {"turn_finished",
         %{
           "turn_id" => "turn-1",
           "session_id" => "s1",
           "revision" => 1,
           "status" => "failed",
           "reason" => "unsupported_capability: JSON Schema dialect is unsupported",
           "finished_at" => "2026-09-09T10:00:03Z",
           "wall_ms" => 2_816
         }}
      )

    assert %{
             status: :failed,
             terminal_reason: "unsupported_capability: JSON Schema dialect is unsupported",
             wall_time_ms: 2_816
           } = Metrics.snapshot(state).turns["turn-1"]
  end

  test "a non-string persisted turn reason projects as bounded text" do
    reason = ["badkey", "runtime", %{"context" => String.duplicate("x", 10_000)}]

    state =
      Metrics.new("s1")
      |> Metrics.reduce({"turn_started", %{"turn_id" => "turn-1", "session_id" => "s1"}})
      |> Metrics.reduce(
        {"turn_finished",
         %{"turn_id" => "turn-1", "session_id" => "s1", "status" => "failed", "reason" => reason}}
      )

    assert %{terminal_reason: text} = Metrics.snapshot(state).turns["turn-1"]
    assert is_binary(text)
    assert text =~ "badkey"
    assert String.length(text) <= 2_000
  end

  test "includes tool-only turns without inventing token usage" do
    state =
      Metrics.reduce(
        Metrics.new("s1"),
        {:tool_finished,
         %{tool_id: "tool-1", turn_id: "turn-tool", status: :completed, elapsed_ms: 10}}
      )

    assert %{request_count: 0, tool_count: 1, status: :completed, total_tokens: nil} =
             Metrics.snapshot(state).turns["turn-tool"]
  end

  test "groups usage by purpose and provider-model without losing visible output" do
    state =
      Metrics.new("s1")
      |> Metrics.reduce(
        {:request_finished,
         %{
           request_id: "r1",
           session_id: "s1",
           purpose: "auxiliary",
           provider: "openai",
           model: "gpt-5",
           input_tokens_total: 10,
           output_tokens_total: 4,
           visible_output_tokens: 3
         }}
      )

    snapshot = Metrics.snapshot(state)

    assert %{total_tokens: 14, visible_output_tokens: 3} = snapshot.usage_by_purpose.auxiliary

    assert [
             %{
               provider: "openai",
               model: "gpt-5",
               usage: %{total_tokens: 14, visible_output_tokens: 3}
             }
           ] = snapshot.usage_by_model
  end

  test "replays compaction lifecycle and replaces terminal revision" do
    state =
      Metrics.new("s1")
      |> Metrics.reduce(
        {:request_finished,
         %{
           request_id: "compaction-request",
           session_id: "s1",
           purpose: :compaction,
           revision: 1,
           status: :failed,
           input_tokens_total: 100,
           output_tokens_total: 10,
           elapsed_ms: 500
         }}
      )
      |> Metrics.reduce({:compaction, %{compaction_id: "c1", revision: 0, status: :started}})
      |> Metrics.reduce(
        {:compaction,
         %{
           compaction_id: "c1",
           revision: 1,
           status: :failed,
           request_ids: ["compaction-request"]
         }}
      )
      |> Metrics.reduce({:compaction, %{compaction_id: "c1", revision: 1, status: :failed}})

    snapshot = Metrics.snapshot(state)
    assert snapshot.successful_compactions == 0

    assert [%{compaction_id: "c1", status: :failed, request_ids: ["compaction-request"]}] =
             snapshot.compactions

    assert snapshot.own_usage.total_tokens == 110
    assert snapshot.usage_by_purpose.compaction.total_tokens == 110

    assert %{
             attempt_count: 1,
             successful_count: 0,
             failed_count: 1,
             last_attempt: %{compaction_id: "c1", status: :failed},
             last_successful: nil
           } = snapshot.compaction_summary

    assert state.facts == 3
  end

  test "projects first request time and latest committed compaction" do
    state =
      Metrics.new("s1")
      |> Metrics.reduce(
        {:request_finished,
         %{
           request_id: "later",
           session_id: "s1",
           started_at: "2026-09-09T08:01:00Z",
           input_tokens_total: 1,
           output_tokens_total: 1
         }}
      )
      |> Metrics.reduce(
        {:request_finished,
         %{
           request_id: "earlier",
           session_id: "s1",
           started_at: "2026-09-09T08:00:00Z",
           input_tokens_total: 1,
           output_tokens_total: 1
         }}
      )
      |> Metrics.reduce(
        {:compaction,
         %{
           compaction_id: "old",
           status: :committed,
           finished_at: "2026-09-09T08:02:00Z"
         }}
      )
      |> Metrics.reduce(
        {:compaction,
         %{
           compaction_id: "new",
           status: :committed,
           finished_at: "2026-09-09T08:03:00Z"
         }}
      )

    snapshot = Metrics.snapshot(state)
    assert snapshot.started_at == "2026-09-09T08:00:00Z"
    assert snapshot.last_compaction.compaction_id == "new"
  end

  test "folds 10,000 heterogeneous durable facts and applies stable updates incrementally" do
    bulk =
      for index <- 1..9_994 do
        {:request_finished,
         %{
           request_id: "request-#{index}",
           session_id: "s1",
           revision: 1,
           input_tokens_total: 1,
           output_tokens_total: 2,
           elapsed_ms: 10
         }}
      end

    special = [
      {:request_finished,
       %{
         request_id: "old-branch",
         session_id: "s1",
         turn_id: "old-turn",
         revision: 1,
         status: :completed,
         input_tokens_total: 1,
         output_tokens_total: 1
       }},
      {:request_finished,
       %{
         request_id: "failed-auxiliary",
         session_id: "s1",
         turn_id: "failed-turn",
         purpose: :auxiliary,
         revision: 1,
         status: :failed,
         input_tokens_total: 1,
         output_tokens_total: 1
       }},
      {:request_finished,
       %{
         request_id: "compaction-request",
         session_id: "s1",
         purpose: :compaction,
         revision: 1,
         status: :failed,
         input_tokens_total: 1,
         output_tokens_total: 1
       }},
      {:request_finished,
       %{
         request_id: "inherited-request",
         session_id: "parent",
         origin_session_id: "parent",
         revision: 1,
         status: :completed,
         input_tokens_total: 1,
         output_tokens_total: 1
       }},
      {:compaction, %{compaction_id: "failed-compaction", revision: 0, status: :started}},
      {:compaction, %{compaction_id: "failed-compaction", revision: 1, status: :failed}}
    ]

    facts = bulk ++ special
    midpoint = Enum.reduce(Enum.take(facts, 5_000), Metrics.new("s1"), &Metrics.reduce(&2, &1))
    incremental = Enum.reduce(facts, Metrics.new("s1"), &Metrics.reduce(&2, &1))
    replayed = Metrics.reduce_all(facts, "s1")
    projection = Metrics.snapshot(incremental, active_request_ids: ["request-1"])
    work_before_snapshots = Metrics.projection_stats(incremental)

    Enum.each(1..100, fn _ -> Metrics.snapshot(incremental) end)

    assert Metrics.snapshot(incremental) == Metrics.snapshot(replayed)
    assert Metrics.projection_stats(incremental) == work_before_snapshots
    assert work_before_snapshots.snapshot_full_history_scans == 0
    assert work_before_snapshots.historical_items_visited == 1
    assert incremental.facts == 10_000
    assert map_size(incremental.requests) == 9_998
    assert projection.request_count == 9_997
    assert projection.own_usage.total_tokens == 29_988
    assert projection.inherited_usage.total_tokens == 2
    assert projection.active_lineage_usage.total_tokens == 3
    assert projection.usage_by_purpose.auxiliary.total_tokens == 2
    assert projection.usage_by_purpose.compaction.total_tokens == 2
    assert projection.successful_compactions == 0
    assert projection.compaction_summary.failed_count == 1

    midpoint_words = :erts_debug.flat_size(midpoint)
    full_words = :erts_debug.flat_size(incremental)
    assert full_words > midpoint_words
    assert full_words < midpoint_words * 2.2

    corrected =
      Metrics.reduce(
        incremental,
        {:request_usage,
         %{
           request_id: "request-1",
           revision: 2,
           input_tokens_total: 1,
           output_tokens_total: 3,
           elapsed_ms: 10
         }}
      )

    assert corrected.facts == 10_001
    assert map_size(corrected.requests) == 9_998
    assert Metrics.snapshot(corrected).own_usage.total_tokens == 29_989
    assert corrected.compactions == incremental.compactions

    assert Metrics.projection_stats(corrected).historical_items_visited ==
             work_before_snapshots.historical_items_visited
  end

  test "keeps steady work bounded across 10,000 mixed request, turn, tool, and compaction facts" do
    facts =
      Enum.flat_map(1..2_500, fn index ->
        [
          {:turn_finished,
           %{
             turn_id: "turn-#{index}",
             session_id: "s1",
             started_at: "2026-09-09T10:00:00Z",
             finished_at: "2026-09-09T10:00:01Z"
           }},
          {:request_finished,
           %{
             request_id: "request-#{index}",
             session_id: "s1",
             turn_id: "turn-#{index}",
             provider: "openai",
             model: "gpt-5",
             input_tokens_total: 1,
             output_tokens_total: 2,
             elapsed_ms: 10
           }},
          {:tool_finished,
           %{
             tool_id: "tool-#{index}",
             turn_id: "turn-#{index}",
             status: :completed,
             elapsed_ms: 5
           }},
          {:compaction,
           %{
             compaction_id: "compaction-#{index}",
             status: if(rem(index, 2) == 0, do: :committed, else: :failed)
           }}
        ]
      end)

    midpoint = Enum.reduce(Enum.take(facts, 5_000), Metrics.new("s1"), &Metrics.reduce(&2, &1))
    state = Enum.reduce(facts, Metrics.new("s1"), &Metrics.reduce(&2, &1))
    midpoint_stats = Metrics.projection_stats(midpoint)
    stats = Metrics.projection_stats(state)
    snapshot = Metrics.snapshot(state)

    assert stats.accepted_facts == 10_000
    assert stats.historical_items_visited == 0
    assert stats.snapshot_full_history_scans == 0
    assert stats.snapshot_bucket_items_visited == midpoint_stats.snapshot_bucket_items_visited
    assert stats.snapshot_bucket_items_visited == 1
    assert snapshot.own_usage.total_tokens == 7_500
    assert map_size(snapshot.turns) == 2_500
    assert length(snapshot.tools) == 2_500

    assert %{attempt_count: 2_500, successful_count: 1_250, failed_count: 1_250} =
             snapshot.compaction_summary

    assert :erts_debug.flat_size(state) < :erts_debug.flat_size(midpoint) * 2.2
  end
end
