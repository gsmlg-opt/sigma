defmodule Sigma.Agent.Backplane.GoalUnrecordedRunsTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Store, as: RuntimeStore
  alias Sigma.Agent.Backplane.{GoalRecovery, GoalRuns, Store}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    transcript = Path.join(dir, "session.jsonl")
    File.write!(transcript, ~s({"type":"session","id":"thread-1","version":3}\n))
    root = Path.join(transcript <> ".subagents", "goal")
    File.mkdir_p!(root)

    for run <- ["never-admitted", "admitted"] do
      :ok = GoalRuns.record(root, "thread-1", goal_binding(run))
    end

    {:ok, store} = Store.open(path: transcript <> ".runtime")

    {:ok, _} =
      RuntimeStore.store(Store, store, run("admitted"), %{command: {:admit, 1, %{}}})

    :ok = Store.retire(store)
    {:ok, transcript: transcript, root: root}
  end

  test "lists only indexed runs without a Runtime record and discards them on request", c do
    assert {:ok, [%{run_id: "never-admitted"}]} = GoalRecovery.unrecorded_runs(c.transcript)

    assert {:ok, ["never-admitted"]} =
             GoalRecovery.discard_unrecorded(c.transcript, ["never-admitted"])

    assert {:ok, []} = GoalRecovery.unrecorded_runs(c.transcript)
    assert {:ok, [%{run_id: "admitted"}]} = GoalRuns.list(c.root, "thread-1")
  end

  test "never discards a run the Runtime Store recorded", c do
    assert {:error, %Error{class: :resource_conflict}} =
             GoalRecovery.discard_unrecorded(c.transcript, ["admitted"])

    assert {:ok, runs} = GoalRuns.list(c.root, "thread-1")
    assert Enum.map(runs, & &1.run_id) == ["admitted", "never-admitted"]
  end

  defp goal_binding(run),
    do: %{
      thread_id: "thread-1",
      run_id: run,
      incarnation: 1,
      mode: :execution,
      goal_id: nil,
      usage_authoritative: false
    }

  defp run(id),
    do: %{
      run_id: id,
      expected_revision: 0,
      incarnation: 1,
      state: :queued,
      deadline: nil,
      outcome: nil,
      children: []
    }
end
