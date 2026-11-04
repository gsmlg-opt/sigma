defmodule Sigma.Ai.CancellationFeedbackTest do
  use ExUnit.Case, async: true
  alias Sigma.Ai.CancellationFeedback

  test "UI feedback distinguishes pending, confirmed, terminal and unconfirmed outcomes" do
    scope = %{target: "/root/child", turn_id: "old-turn"}

    assert CancellationFeedback.message(scope, %{outcome: :confirmed}) =~
             "upstream confirmed cancellation"

    assert CancellationFeedback.message(scope, %{outcome: :already_terminal, status: "completed"}) =~
             "already completed"

    assert CancellationFeedback.message(scope, %{outcome: :pending}) =~
             "waiting for upstream confirmation"

    for result <- [%{outcome: :failed}, %{outcome: :unknown, reason: :missing_checkpoint}] do
      message = CancellationFeedback.message(scope, result)
      assert message =~ "unconfirmed"
      refute message =~ "confirmed cancellation"
    end

    assert CancellationFeedback.message(scope, %{outcome: :unsupported}) =~
             "Generation may continue"
  end

  test "public event payload is JSON encodable and retains outcome rather than implying local means remote" do
    for outcome <- [:pending, :confirmed, :already_terminal, :unsupported, :failed, :unknown] do
      payload =
        CancellationFeedback.payload(%{target: "Child"}, %{
          outcome: outcome,
          reason: :missing_checkpoint,
          response_id: "resp_known"
        })

      assert {:ok, encoded} = Jason.encode(payload)
      assert Jason.decode!(encoded)["outcome"] == Atom.to_string(outcome)
      assert payload["responseId"] == "resp_known"
    end
  end
end
