defmodule Sigma.Agent.Backplane.GoalRunsTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Error
  alias Sigma.Agent.Backplane.{GoalRuns, GoalStore, Store}

  defmodule FailingFileSystem do
    def read(_context, path), do: Store.FileSystem.read(path)
    def write_atomic(_context, _path, _bytes), do: {:error, :injected_failure}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "sigma-goal-runs-#{System.unique_integer([:positive])}")
    start_supervised!({GoalStore, path: root})

    on_exit(fn ->
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "durable index retains exact scoped binding identities without capabilities", %{root: root} do
    assert {:ok, []} = GoalRuns.list(root, "thread")
    binding = binding("run", 1)
    assert :ok = GoalRuns.record(root, "thread", binding)
    assert :ok = GoalRuns.record(root, "thread", binding)
    assert {:ok, [^binding]} = GoalRuns.list(root, "thread")
    assert {:ok, []} = GoalRuns.list(root, "other-thread")
    assert :ok = GoalRuns.record(root, "thread", binding("run", 2))
    assert {:ok, bindings} = GoalRuns.list(root, "thread")
    assert Enum.sort_by(bindings, & &1.incarnation) == [binding, binding("run", 2)]

    assert {:error, %Error{class: :resource_conflict}} =
             GoalRuns.record(root, "thread", %{binding | mode: :plan})

    assert {:error, %Error{class: :validation}} =
             GoalRuns.record(root, "other-thread", binding)

    assert {:error, %Error{class: :validation}} =
             GoalRuns.record(root, "thread", Map.put(binding, :capability, make_ref()))
  end

  test "index write failure never acknowledges a binding and corruption never becomes empty", %{
    root: root
  } do
    assert {:error, %Error{class: :execution_failure}} =
             GoalRuns.record(
               root,
               "thread",
               binding("run", 1),
               filesystem: {FailingFileSystem, nil}
             )

    assert {:ok, []} = GoalRuns.list(root, "thread")
    assert :ok = GoalRuns.record(root, "thread", binding("run", 1))
    [path] = Path.wildcard(Path.join(root, "*.goal-runs"))
    assert {:ok, %{mode: 0o100600}} = File.stat(path)
    File.write!(path, "corrupt")
    assert {:error, %Error{class: :malformed_result}} = GoalRuns.list(root, "thread")

    File.write!(
      path,
      :erlang.term_to_binary(%{version: 1, thread_id: "thread", runs: %{}, injected: self()})
    )

    assert {:error, %Error{class: :malformed_result}} = GoalRuns.list(root, "thread")
  end

  defp binding(run, incarnation),
    do: %{
      thread_id: "thread",
      run_id: run,
      incarnation: incarnation,
      mode: :execution,
      goal_id: nil,
      usage_authoritative: false
    }
end
