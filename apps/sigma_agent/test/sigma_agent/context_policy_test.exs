defmodule Sigma.Agent.ContextPolicyTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.ContextPolicy

  test "new session budget precedence does not conflate model window with its default budget" do
    model = %{"defaultContextLimit" => 131_072, "contextWindow" => 1_000_000}
    assert {:ok, 131_072} = ContextPolicy.new_session_limit(model)
    assert {:ok, 64_000} = ContextPolicy.new_session_limit(model, "64000")
    assert {:ok, 256_000} = ContextPolicy.new_session_limit(%{"contextWindow" => 1_000_000})
    assert {:error, :invalid_context_limit} = ContextPolicy.new_session_limit(model, "0")
  end

  test "context budgets accept custom positive integers without changing zero token measurements" do
    for value <- [128_000, "128000", 1, "1000000"] do
      assert {:ok, limit} = ContextPolicy.parse_context_limit(value)
      assert is_integer(limit) and limit > 0
    end

    for value <- [0, "0", -1, "-1", 1.5, "128000x", "", nil] do
      assert {:error, :invalid_context_limit} = ContextPolicy.parse_context_limit(value)
    end

    assert ContextPolicy.snapshot(last_request_input_tokens: 0).last_request_input_tokens == 0
  end

  test "session limit caps the model and supplies unknown capacity" do
    snapshot = ContextPolicy.snapshot(next_request_estimated_input_tokens: 250_000)
    policy = ContextPolicy.policy(snapshot, context_limit: 256_000, output_reserve: 8_000)
    assert policy.context_limit == 256_000
    assert policy.context_window == 256_000
    assert policy.threshold == 204_800
    assert policy.window_source == :session
    assert policy.threshold_source == :session_ratio
    assert policy.overflow == :hard_overflow

    smaller =
      ContextPolicy.policy(snapshot, context_limit: 256_000, model: %{context_window: 100_000})

    assert smaller.context_window == 100_000
    assert smaller.threshold == 80_000
    assert smaller.window_source == :model
    assert smaller.threshold_source == :model_ratio

    larger =
      ContextPolicy.policy(snapshot, context_limit: 384_000, model: %{context_window: 1_000_000})

    assert larger.context_window == 384_000
    assert larger.threshold == 307_200
  end

  test "keeps provider measurement separate from next request estimate" do
    snapshot =
      ContextPolicy.snapshot(
        context_revision: 7,
        active_leaf: "leaf-2",
        last_request_input_tokens: 100_000,
        last_request_id: "request-1",
        system_tokens: 100,
        message_tokens: 900,
        tool_tokens: 200,
        skills: ["skill"],
        attachments: []
      )

    assert snapshot.context_revision == 7
    assert snapshot.last_request_input_tokens == 100_000
    assert snapshot.last_request_id == "request-1"
    assert snapshot.next_request_estimated_input_tokens == 1_204
    assert snapshot.estimate_coverage == :complete
    refute snapshot.last_request_input_tokens == snapshot.next_request_estimated_input_tokens
  end

  test "marks unsupported estimate parts as partial instead of pretending precision" do
    snapshot = ContextPolicy.snapshot(system: %{dynamic: :not_countable}, messages: "ok")

    assert snapshot.estimate_coverage == :partial
    assert :system in snapshot.estimate_unknown_components
    assert is_integer(snapshot.next_request_estimated_input_tokens)
  end

  test "does not truncate long structured context while estimating tokens" do
    short = ContextPolicy.snapshot(messages: [%{role: :user, content: "short"}])

    long =
      ContextPolicy.snapshot(
        messages: [%{role: :user, content: String.duplicate("long context ", 10_000)}]
      )

    assert long.next_request_estimated_input_tokens > 30_000
    assert long.next_request_estimated_input_tokens > short.next_request_estimated_input_tokens
  end

  test "hosted replay actions and citations contribute to the next request estimate" do
    short = hosted_message("answer", "query", "source")

    long =
      hosted_message(
        "answer",
        String.duplicate("query ", 2_000),
        String.duplicate("source ", 2_000)
      )

    assert short.content == long.content
    short_snapshot = ContextPolicy.snapshot(messages: [short])
    long_snapshot = ContextPolicy.snapshot(messages: [long])

    assert long_snapshot.next_request_estimated_input_tokens >
             short_snapshot.next_request_estimated_input_tokens + 6_000

    assert long_snapshot.estimate_coverage == :complete
  end

  test "hosted native text is counted once alongside canonical assistant text" do
    short = hosted_message("abcd", "query", "source")
    long = hosted_message(String.duplicate("abcd", 1_001), "query", "source")

    estimate = fn message ->
      ContextPolicy.snapshot(messages: [message]).next_request_estimated_input_tokens
    end

    legacy = fn message -> %{message | metadata: %{}} end

    assert estimate.(long) - estimate.(short) == 1_000

    assert estimate.(long) - estimate.(short) ==
             estimate.(legacy.(long)) - estimate.(legacy.(short))

    assert estimate.(short) > estimate.(legacy.(short))
  end

  test "hosted projection keeps legacy estimates and explicit message token overrides" do
    legacy = ContextPolicy.snapshot(messages: [%{role: :user, content: "short"}])
    assert legacy.estimate_components.messages == 8

    hosted = hosted_message("answer", String.duplicate("query", 1_000), "source")
    explicit = ContextPolicy.snapshot(messages: [hosted], message_tokens: 42)
    assert explicit.estimate_components.messages == 42
    assert explicit.next_request_estimated_input_tokens == 42
  end

  test "reports runtime threshold and model window provenance" do
    snapshot = ContextPolicy.snapshot(next_request_estimated_input_tokens: 75_000)

    view =
      ContextPolicy.policy(snapshot,
        model: %{context_window: 100_000, max_output_tokens: 8_000},
        threshold: 70_000,
        output_reserve: 10_000
      )

    assert view.context_window == 100_000
    assert view.window_source == :model
    assert view.threshold == 70_000
    assert view.threshold_source == :runtime
    assert view.tokens_remaining == 0
    assert view.hard_tokens_remaining == 15_000
    assert view.overflow == :within_budget
  end

  test "keeps unknown model capacity explicit and marks stale estimates" do
    snapshot = ContextPolicy.snapshot(next_request_estimated_input_tokens: 90_000, stale: true)
    view = ContextPolicy.policy(snapshot, output_reserve: 1_000)

    assert view.context_window == nil
    assert view.window_source == :unknown
    assert view.estimate_stale
    assert view.overflow == :unknown
    assert view.hard_tokens_remaining == nil
  end

  test "hard budget catches input plus output reserve beyond known window" do
    snapshot = ContextPolicy.snapshot(next_request_estimated_input_tokens: 95_000)
    view = ContextPolicy.policy(snapshot, context_window: 100_000, output_reserve: 8_000)

    assert view.overflow == :hard_overflow
    assert view.hard_tokens_remaining == 0
  end

  test "invalidates a measured snapshot with a new model and revision" do
    snapshot =
      ContextPolicy.snapshot(
        context_revision: 4,
        active_leaf: "leaf-1",
        model: %{id: "old"},
        source: :provider_usage,
        last_request_input_tokens: 120
      )

    invalidated =
      ContextPolicy.invalidate(snapshot,
        active_leaf: "leaf-2",
        model: %{id: "new"},
        source: :model_change
      )

    assert %ContextPolicy{
             context_revision: 5,
             active_leaf: "leaf-2",
             model: %{id: "new"},
             source: :model_change,
             stale: true,
             last_request_input_tokens: 120
           } = invalidated

    assert {:ok, _generated_at, 0} = DateTime.from_iso8601(invalidated.generated_at)
  end

  defp hosted_message(text, query, title) do
    %{
      role: :assistant,
      content: [%{type: :text, text: text}],
      metadata: %{
        "openai_responses_hosted" => %{
          "version" => 1,
          "origin" => %{
            "protocol" => "openai-responses",
            "provider" => "openai",
            "model" => "model",
            "endpoint_sha256" => String.duplicate("a", 64)
          },
          "response_id" => "response-1",
          "items" => [
            %{
              "output_index" => 0,
              "item" => %{
                "type" => "web_search_call",
                "id" => "search-1",
                "status" => "completed",
                "action" => %{"type" => "search", "query" => query}
              }
            },
            %{
              "output_index" => 1,
              "item" => %{
                "type" => "message",
                "id" => "message-1",
                "role" => "assistant",
                "status" => "completed",
                "content" => [
                  %{
                    "type" => "output_text",
                    "text" => text,
                    "annotations" => [
                      %{
                        "type" => "url_citation",
                        "start_index" => 0,
                        "end_index" => 4,
                        "url" => "https://example.com/source",
                        "title" => title
                      }
                    ]
                  }
                ]
              }
            }
          ]
        }
      }
    }
  end
end
