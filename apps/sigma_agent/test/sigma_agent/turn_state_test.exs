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
end
