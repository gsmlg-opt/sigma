defmodule Sigma.Agent.BackplaneGoalStore45FunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Error, Execution, Goal}
  alias Backplane.AgentRuntime.Goal.Store, as: GoalContract
  alias Sigma.Agent.Backplane.GoalStore

  @moduletag :tmp_dir
  @admission_fields ~w(runtime_receipt_counts admission_settlements)a

  defmodule Host do
    @behaviour Backplane.AgentRuntime.Goal.Host

    def record_user_instruction(_host, _thread, _instruction), do: :ok

    def start_turn_if_idle(host, _thread, request) do
      Agent.get_and_update(host, fn state ->
        admission = %{
          run_id: "store45-run-#{request.host_generation}",
          turn_id: "store45-turn-#{request.host_generation}",
          incarnation: 1,
          host_generation: request.host_generation,
          reservation_token: request.reservation_token
        }

        {{:ok, {:started, admission}}, %{state | admission: admission}}
      end)
    end

    def admit(host, admission) do
      Agent.get(host, fn state ->
        if state.admission == admission and
             not MapSet.member?(state.sealed, admission.reservation_token),
           do: :admitted,
           else: :fenced
      end)
    end

    def seal(host, admission),
      do: Agent.update(host, &%{&1 | sealed: MapSet.put(&1.sealed, admission.reservation_token)})
  end

  test "a stored 1.10.44 Goal reopens through the public owner without rewriting history", %{
    tmp_dir: dir
  } do
    host = start_supervised!({Agent, fn -> %{admission: nil, sealed: MapSet.new()} end})
    root = Path.join(dir, "goals")
    {path, legacy} = legacy_goal(root, host)
    before_read = file_fact(path)

    store = open_store(root)
    assert {:ok, normalized} = GoalContract.load(GoalStore, store, "thread")
    assert Map.drop(normalized, @admission_fields) == legacy
    assert normalized.runtime_receipt_counts == %{}
    assert normalized.admission_settlements == %{}

    goal = open_goal(store, host)
    assert {:ok, %{goal: %{objective: "Preserve 中文\r\nGoal"}}} = Goal.get(goal)
    assert {:ok, ^normalized} = Goal.snapshot(goal)
    assert file_fact(path) == before_read

    # The first real mutation, rather than reopening or reading, upgrades the
    # persisted record and continues from the original CAS revision.
    assert {:ok, %{goal: %{status: :paused}}} =
             Goal.set(goal, %{status: :paused}, %{text: "Pause this Goal"})

    assert {:ok, current} = Goal.snapshot(goal)
    assert current.revision == legacy.revision + 1
    assert current.goal.goal_id == legacy.goal.goal_id
    assert current.runtime_receipt_counts == %{}
    assert current.admission_settlements == %{}
    assert :erlang.binary_to_term(File.read!(path), [:safe]) == current
  end

  test "an ended preparation settles durably and reopens with exact retry and independent fork",
       %{
         tmp_dir: dir
       } do
    host = start_supervised!({Agent, fn -> %{admission: nil, sealed: MapSet.new()} end})
    root = Path.join(dir, "goals")
    {path, _legacy} = legacy_goal(root, host)
    store = open_store(root)
    goal = open_goal(store, host)
    assert {:ok, {:started, admission}} = Goal.idle(goal, 1)

    supervisor = start_supervised!(Task.Supervisor)
    owner = self()

    assert {:ok, executor} =
             Task.Supervisor.start_child(supervisor, fn ->
               receive do
                 :prepare ->
                   assert Host.admit(host, admission) == :admitted

                   send(
                     owner,
                     {:preparation_ended, Execution.validate_limits(cleanup_timeout: 0)}
                   )
               end
             end)

    monitor = Process.monitor(executor)
    send(executor, :prepare)
    assert_receive {:preparation_ended, {:error, %Error{class: :validation}}}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^executor, :normal}, 1_000
    Host.seal(host, admission)
    assert Host.admit(host, admission) == :fenced

    attestation = %{
      admission: admission,
      executor: :confirmed_down,
      runtime_admission: :never_started,
      future_start: :fenced,
      effects: :none_dispatched
    }

    assert {:ok, {:settled, :preparation_failed}} =
             Goal.settle_unstarted_admission(goal, admission, :preparation_failed, attestation)

    assert {:ok, committed} = Goal.snapshot(goal)
    assert committed.goal.status == :active
    assert committed.receipts == %{}
    assert committed.deliveries == %{}
    assert committed.continuation_deferral == nil
    assert map_size(committed.admission_settlements) == 1
    assert committed.admission_settlements[admission.reservation_token].admission == admission
    assert committed.runtime_receipt_counts == %{}
    GenServer.stop(goal)
    assert :ok = GoalStore.retire(root)

    # Make a same-byte rewrite observable even on filesystems exposing only
    # second-resolution timestamps through File.Stat.
    File.touch!(path, {{2000, 1, 1}, {0, 0, 0}})
    before_reopen = file_fact(path)
    reopened_store = open_store(root)
    reopened_goal = open_goal(reopened_store, host)
    assert {:ok, ^committed} = Goal.snapshot(reopened_goal)

    assert {:ok, {:started, fresh}} = Goal.idle(reopened_goal, 2)
    refute fresh.reservation_token == admission.reservation_token

    assert {:ok, {:settled, :preparation_failed}} =
             Goal.settle_unstarted_admission(
               reopened_goal,
               admission,
               :preparation_failed,
               attestation
             )

    assert {:ok, {:not_submitted, :already_reserved}} = Goal.idle(reopened_goal, 3)
    assert {:ok, ^committed} = Goal.snapshot(reopened_goal)
    assert file_fact(path) == before_reopen

    assert {:ok, forked} = Goal.fork_snapshot(reopened_goal, "fork")
    assert forked.admission_settlements == %{}
    assert forked.runtime_receipt_counts == %{}
    assert forked.goal == %{committed.goal | thread_id: "fork"}

    target_store = open_store(Path.join(dir, "fork-goals"))
    assert {:ok, ^forked} = GoalStore.import_fork(target_store, "fork", forked)
    target_goal = open_goal(target_store, host, "fork")
    assert {:ok, ^forked} = Goal.snapshot(target_goal)
    assert {:ok, ^committed} = Goal.snapshot(reopened_goal)
    assert file_fact(path) == before_reopen
  end

  test "present admission fields and incomplete schemas are not repaired as legacy records", %{
    tmp_dir: dir
  } do
    host = start_supervised!({Agent, fn -> %{admission: nil, sealed: MapSet.new()} end})
    root = Path.join(dir, "goals")
    {path, legacy} = legacy_goal(root, host)
    store = open_store(root)
    assert {:ok, normalized} = GoalContract.load(GoalStore, store, "thread")

    for malformed <- [
          Map.put(normalized, :runtime_receipt_counts, nil),
          Map.put(normalized, :admission_settlements, nil),
          Map.delete(normalized, :receipts),
          Map.put(legacy, :runtime_receipt_counts, %{})
        ] do
      bytes = :erlang.term_to_binary(malformed)
      File.write!(path, bytes)
      assert {:error, %Error{class: :malformed_result}} = GoalStore.load(store, "thread")
      assert File.read!(path) == bytes
    end
  end

  defp legacy_goal(root, host) do
    store = open_store(root)
    goal = open_goal(store, host)

    assert {:ok, _} =
             Goal.set(goal, %{objective: "Preserve 中文\r\nGoal"}, %{text: "Create this Goal"})

    assert {:ok, snapshot} = Goal.snapshot(goal)
    GenServer.stop(goal)
    assert :ok = GoalStore.retire(root)
    [path] = Path.wildcard(Path.join(root, "*.goal"))
    legacy = Map.drop(snapshot, @admission_fields)
    File.write!(path, :erlang.term_to_binary(legacy, compressed: 6))
    File.touch!(path, {{2000, 1, 1}, {0, 0, 0}})
    {path, legacy}
  end

  defp open_store(root) do
    assert {:ok, store} = GoalStore.open(path: root)
    on_exit(fn -> if Process.alive?(store), do: GenServer.stop(store) end)
    store
  end

  defp open_goal(store, host, thread \\ "thread") do
    assert {:ok, goal} =
             Goal.start_link(
               thread_id: thread,
               owner_pid: self(),
               store: GoalStore,
               store_context: store,
               host: Host,
               host_context: host
             )

    on_exit(fn -> if Process.alive?(goal), do: GenServer.stop(goal) end)
    goal
  end

  defp file_fact(path) do
    bytes = File.read!(path)
    stat = File.stat!(path, time: :posix)
    %{bytes: bytes, sha256: :crypto.hash(:sha256, bytes), mtime: stat.mtime, inode: stat.inode}
  end
end
