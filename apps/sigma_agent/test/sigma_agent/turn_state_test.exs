defmodule Sigma.Agent.TurnStateTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.TurnState

  test "models the closed active and terminal phase set" do
    turn = TurnState.start("turn-1", make_ref())
    assert %{phase: :streaming_provider, turn_id: "turn-1"} = turn
    assert TurnState.active?(turn)

    assert %{phase: :running_tools} = TurnState.transition(turn, :running_tools)
    assert %{phase: :waiting_permission} = TurnState.transition(turn, :waiting_permission)
    assert %{phase: :cancelling} = TurnState.transition(turn, :cancelling)
    assert %{phase: :cancelled} = TurnState.transition(turn, :cancelled)
    refute TurnState.active?(TurnState.transition(turn, :completed))
  end

  test "keeps retry failures visible during replacement requests and clears them on exit" do
    retry = %{status: :waiting, error: "AI provider HTTP 504: Gateway Timeout"}
    turn = TurnState.start("turn-retry", make_ref()) |> Map.put(:provider_retry, retry)

    assert %{provider_retry: %{status: :requesting, error: error}} =
             TurnState.transition(turn, :streaming_provider)

    assert error == retry.error

    for phase <- [:running_tools, :cancelling, :cancelled, :completed, :failed] do
      assert %{provider_retry: nil} = TurnState.transition(turn, phase)
    end

    assert %{provider_retry: nil} = TurnState.start("next-turn", make_ref())
  end
end
