defmodule Sigma.Agent.ContextControlsContractTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.{ContextBuilder, ContextPolicy, Message, SessionContext}
  alias Sigma.Agent.Backplane.ContextControls

  test "an empty new window rehydrates base instructions as host context without a user turn" do
    session = session_context()

    context =
      ContextBuilder.build(
        messages: [],
        session_context: session,
        system_prompt: "Stable product instructions",
        context_window: 2
      )

    assert [%{role: :user, metadata: %{source: :context_window}} = base] = context.messages
    assert text(base) =~ "Repository instruction: keep the source of truth"
    assert text(base) =~ "repo-skill"
    assert text(base) =~ "Hook instruction: preserve the worktree"
    assert context.system_prompt == "Stable product instructions"
    refute text(base) =~ "compaction_summary"
    assert session == session_context()
  end

  test "base instructions survive tool-only continuation without duplicating a real user prompt" do
    assistant = %Message{id: "new-assistant", role: :assistant, content: "Working", timestamp: 1}

    context =
      ContextBuilder.build(
        messages: [assistant],
        session_context: session_context(),
        context_window: 2
      )

    assert [%{metadata: %{source: :context_window}} = base, %{role: :assistant}] =
             context.messages

    assert text(base) =~ "Repository instruction: keep the source of truth"

    user = Message.user("new-user", "Continue with the new task")

    with_user =
      ContextBuilder.build(
        messages: [user, assistant],
        session_context: session_context(),
        context_window: 2
      )

    assert [%{role: :user} = injected, %{role: :assistant}] = with_user.messages

    assert length(
             Regex.scan(~r/Repository instruction: keep the source of truth/, text(injected))
           ) == 1

    assert text(injected) =~ "Continue with the new task"
    refute Map.has_key?(injected, :metadata)
  end

  test "the model output reserve recognizes the same catalog maxTokens used by providers" do
    snapshot = ContextPolicy.snapshot(next_request_estimated_input_tokens: 600)

    for model <- [
          %{"contextWindow" => 1_000, "maxTokens" => 300},
          %{context_window: 1_000, max_tokens: 300}
        ] do
      policy = ContextPolicy.policy(snapshot, model: model)
      assert policy.output_reserve == 300
      assert policy.hard_tokens_remaining == 100
    end
  end

  test "remaining context uses the smaller compaction allowance and full window minus reserve" do
    assert tokens_left(snapshot(600), output_reserve: 300) == 100
    assert tokens_left(snapshot(750), output_reserve: 100) == 50
    assert tokens_left(snapshot(950), output_reserve: 100) == 0
  end

  test "unavailable, stale and partial budgets remain unknown" do
    assert tokens_left(%{snapshot(600) | stale: true}, output_reserve: 100) == nil

    partial = ContextPolicy.snapshot(model: model(), system: :unknown, messages: "known")
    assert tokens_left(partial, output_reserve: 100) == nil
    assert tokens_left(snapshot(600), model: %{}, output_reserve: 100) == nil
  end

  test "real context growth consumes budget instead of returning a fixed number or only nil" do
    short = assembled_snapshot("short")
    long = assembled_snapshot(String.duplicate("Additional context ", 40))
    short_left = tokens_left(short, output_reserve: 100)
    long_left = tokens_left(long, output_reserve: 100)

    assert is_integer(short_left)
    assert is_integer(long_left)
    assert short_left > long_left
  end

  defp tokens_left(snapshot, opts) do
    assert Code.ensure_loaded?(ContextControls),
           "the real host context adapter is not implemented"

    assert function_exported?(ContextControls, :tokens_left, 2)
    apply(ContextControls, :tokens_left, [snapshot, Keyword.put_new(opts, :model, model())])
  end

  defp snapshot(tokens),
    do: ContextPolicy.snapshot(model: model(), next_request_estimated_input_tokens: tokens)

  defp model, do: %{id: "context-model", context_window: 1_000}

  defp assembled_snapshot(content) do
    context =
      ContextBuilder.build(
        messages: [Message.user("user", content)],
        system_prompt: "System",
        session_context: SessionContext.new(),
        tools: []
      )

    ContextPolicy.snapshot(
      model: model(),
      system: context.system,
      messages: context.messages,
      tools: context.tools
    )
  end

  defp session_context do
    SessionContext.new(
      agents_context: "Repository instruction: keep the source of truth",
      skills: [%{name: "repo-skill", description: "Repository workflow"}],
      hooks: "Hook instruction: preserve the worktree"
    )
  end

  defp text(%{content: content}) when is_binary(content), do: content
  defp text(%{content: content}), do: Enum.map_join(content, "\n", &Map.get(&1, :text, ""))
end
