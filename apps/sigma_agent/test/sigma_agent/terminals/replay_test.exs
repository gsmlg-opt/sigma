defmodule Sigma.Agent.Terminals.ReplayTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.Terminals.{Error, Identity, Replay}

  @session Identity.session("repo-1", "session-1", "incarnation-1")
  @run Identity.run(Identity.terminal(@session, "terminal-1"), 1)

  test "chooses live, bounded replay, coherent snapshot, and explicit degradation" do
    state = Replay.new(@run, earliest_sequence: 6, latest_sequence: 10, checkpoint_sequence: 8)

    assert {:live, 11} = Replay.decide(state, @run, 10)
    assert {:replay, 8..10} = Replay.decide(state, @run, 7)
    assert {:snapshot_then_replay, 8, 9..10} = Replay.decide(state, @run, 2)
    assert {:snapshot_then_replay, 8, 9..10} = Replay.decide(state, @run, 12)

    unavailable = %{state | checkpoint_sequence: nil}
    assert {:error, %Error{code: :snapshot_unavailable}} = Replay.decide(unavailable, @run, 2)

    assert {:error, %Error{code: :stale_run_generation}} =
             Replay.decide(state, %{@run | generation: 2}, 10)
  end
end
