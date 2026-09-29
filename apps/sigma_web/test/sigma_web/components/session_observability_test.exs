defmodule Sigma.Web.SessionObservabilityTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias Sigma.Web.SessionObservability

  test "renders complete message metrics and unknown values explicitly" do
    html =
      render_component(&SessionObservability.message_metrics_footer/1, %{
        metrics: %{
          request_id: "request-1",
          input_tokens_total: 10,
          output_tokens_total: 20,
          throughput: 2.5
        },
        elapsed_ms: 100,
        status: :completed
      })

    assert html =~ ~s(<details id=)
    assert html =~ ~s(id="request-details-request-1")
    assert html =~ "input: 10"
    assert html =~ "output: 20"
    assert html =~ "2.50 tok/s"
    assert html =~ "100ms"

    assert render_component(&SessionObservability.message_metrics_footer/1, %{metrics: %{}}) =~
             "unknown"
  end

  test "context warning reflects runtime policy without copying budget numbers" do
    for {policy, expected} <- [
          {%{overflow: :hard_overflow, estimate: 123_456},
           "Request exceeds the model hard budget"},
          {%{overflow: :hard_overflow, estimate_stale: true},
           "Previous check exceeded the model hard budget; current budget unknown"},
          {%{tokens_remaining: 0}, "Compaction threshold reached"}
        ] do
      html = render_component(&SessionObservability.context_warning/1, %{policy: policy})
      assert html =~ expected
      assert html =~ ~s(data-session-context-open="true")
      refute html =~ "123456"
    end

    for policy <- [
          %{},
          %{overflow: :within_budget, tokens_remaining: 1},
          %{tokens_remaining: 0, estimate_stale: true}
        ] do
      html = render_component(&SessionObservability.context_warning/1, %{policy: policy})
      refute html =~ "session-context-warning"
    end
  end

  test "renders runtime context values with distinct threshold and hard budget" do
    html =
      render_component(&SessionObservability.context_budget_card/1, %{
        policy: %{
          estimate: 19_798,
          last_measured: 20_176,
          context_window: 512_000,
          estimate_source: :last_request_measurement,
          tokens_remaining: 389_802,
          threshold: 409_600,
          output_reserve: 8_000,
          hard_tokens_remaining: 484_202,
          overflow: :within_budget
        },
        successful_compactions: 1,
        last_compaction: %{
          before_tokens: 100_000,
          after_tokens: 25_000,
          trigger: :automatic,
          source_leaf_id: "leaf",
          summary_id: "summary",
          request_ids: ["request"],
          before_source: :provider,
          after_source: :estimate
        }
      })

    assert html =~ "Next request estimate: 19798 tokens"
    assert html =~ ~r/Last measured input<\/dt>\s*<dd>20176 tokens/
    assert html =~ "Model window: 512000 tokens"
    assert html =~ "Auto-compaction threshold: 409600 tokens"
    assert html =~ "Until compaction threshold: 389802 tokens"
    assert html =~ ~r/Hard budget remaining<\/dt>\s*<dd>484202 tokens/
    assert html =~ ~s(max="512000")
    assert html =~ "100000 -&gt; 25000"
    assert html =~ "summary"
    assert html =~ "last_request_measurement"
  end

  test "stale and unknown context never suggest a usable remainder" do
    stale =
      render_component(&SessionObservability.context_budget_card/1, %{
        policy: %{
          estimate: 90_000,
          context_window: 100_000,
          tokens_remaining: 0,
          hard_tokens_remaining: 0,
          overflow: :hard_overflow,
          estimate_stale: true
        }
      })

    assert stale =~ "Until compaction threshold: unknown (estimate stale)"
    assert stale =~ ~r/Hard budget remaining<\/dt>\s*<dd>unknown \(estimate stale\)/
    assert stale =~ "Hard request budget: unknown (estimate stale)"
    assert stale =~ "Previous check exceeded the model hard budget; current budget unknown"
    refute stale =~ ~s(<progress)

    unknown = render_component(&SessionObservability.context_budget_card/1, %{policy: %{}})
    assert unknown =~ "Model window: unknown"
    assert unknown =~ "Hard request budget: unknown"
    refute unknown =~ ~s(<progress)

    actions = render_component(&SessionObservability.action_bar/1, %{})
    assert actions =~ "aria-label=\"Retry turn\""
    assert actions =~ "aria-label=\"Fork session\""
  end

  test "renders session usage and timing without lineage in the overview" do
    html =
      render_component(&SessionObservability.session_overview_rail/1, %{
        snapshot: %{
          status: :idle,
          model: "claude-test",
          started_at: "2026-09-09T08:00:00Z",
          own_usage: %{
            input_tokens_total: 40_000,
            output_tokens_total: 1_000,
            total_tokens: 41_000,
            throughput: 50.25,
            partial?: true
          },
          inherited_usage: %{total_tokens: 3_000, request_count: 2},
          parent_session_id: "parent-session",
          coverage: %{known: 2, total: 3},
          context: 25_000,
          successful_compactions: 1,
          last_compaction: %{
            before_tokens: 100_000,
            after_tokens: 25_000,
            finished_at: "2026-09-09T08:05:00Z"
          }
        }
      })

    assert html =~ "input: 40000"
    assert html =~ "output: 1000"
    assert html =~ "known total: 41000"
    assert html =~ "coverage: 2/3"
    assert html =~ "inherited: 3000 tokens (2 requests)"
    assert html =~ "known portion only"
    refute html =~ "forked from: parent-session"
    assert html =~ "50.25 tok/s"
    refute html =~ "Runtime"
    refute html =~ "model: claude-test"
    refute html =~ "<h2 class=\"text-xs font-semibold\">Context</h2>"
    refute html =~ "100000 -&gt; 25000"

    own_only =
      render_component(&SessionObservability.session_overview_rail/1, %{
        snapshot: %{inherited_usage: %{total_tokens: 0, request_count: 0}}
      })

    refute own_only =~ "Inherited usage"
  end

  test "renders a turn total with request and tool counts" do
    html =
      render_component(&SessionObservability.turn_summary/1, %{
        summary: %{
          request_count: 2,
          tool_count: 1,
          input_tokens_total: 50,
          output_tokens_total: 20,
          throughput: 4.0
        }
      })

    assert html =~ "Turn summary"
    assert html =~ "requests: 2"
    assert html =~ "tools: 1"
    assert html =~ "input: 50"
    assert html =~ "output: 20"
  end

  test "single request summary omits counts and marks partial usage" do
    html =
      render_component(&SessionObservability.turn_summary/1, %{
        summary: %{
          request_count: 1,
          input_tokens_total: 12,
          output_tokens_total: 3,
          partial?: true,
          status: :running
        }
      })

    refute html =~ "requests:"
    refute html =~ "tools:"
    assert html =~ "known portion only"
    assert html =~ "wall: unknown"
    assert html =~ "running"
  end

  test "renders original and replacement branch answers with provenance" do
    html =
      render_component(&SessionObservability.branch_alternatives/1, %{
        branches: [
          %{
            leaf_id: "replacement-leaf",
            active?: true,
            branch_point_id: "prompt-entry",
            turn_id: "turn-replacement",
            retry_of_turn_id: "turn-original",
            last_user: %{message_id: "retry-user", text: "Investigate again"},
            last_assistant: %{message_id: "replacement-answer", text: "Replacement answer"}
          },
          %{
            leaf_id: "original-leaf",
            active?: false,
            branch_point_id: "prompt-entry",
            turn_id: "turn-after-original",
            retry_of_turn_id: nil,
            last_user: %{message_id: "original-user", text: "Investigate"},
            last_assistant: %{message_id: "original-answer", text: "Original answer"}
          }
        ]
      })

    assert html =~ "Alternative executions"
    assert html =~ "Active execution"
    assert html =~ "Original execution"
    assert html =~ "Replacement answer"
    assert html =~ "Original answer"
    assert html =~ "turn-original"
    assert html =~ "prompt-entry"
  end
end
