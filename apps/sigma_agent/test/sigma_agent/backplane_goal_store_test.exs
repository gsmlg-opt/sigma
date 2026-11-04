defmodule Sigma.Agent.Backplane.GoalStoreTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Error, Goal}
  alias Backplane.AgentRuntime.Goal.State, as: GoalState
  alias Backplane.AgentRuntime.Goal.Store, as: GoalContract
  alias Sigma.Agent.Backplane.{GoalStore, Store}

  defmodule Host do
    @behaviour Backplane.AgentRuntime.Goal.Host

    def record_user_instruction(owner, thread, instruction) do
      send(owner, {:goal_instruction, thread, instruction})
      :ok
    end

    def start_turn_if_idle(_owner, _thread, _request),
      do: {:ok, {:not_submitted, :test_host}}
  end

  defmodule FaultableFileSystem do
    def ensure_dir(_agent, path), do: Store.FileSystem.ensure_dir(path)

    def read(agent, path) do
      case Agent.get(agent, & &1) do
        :read_error -> {:error, :eacces}
        _ -> Store.FileSystem.read(path)
      end
    end

    def write_atomic(agent, path, bytes) do
      case Agent.get(agent, & &1) do
        :write_error -> {:error, :injected_commit_failure}
        _ -> Store.FileSystem.write_atomic(path, bytes)
      end
    end
  end

  setup context do
    root =
      Path.join(
        System.tmp_dir!(),
        "sigma-goal-store-#{context.test}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "one local writer per absolute root and absent threads have complete empty records", %{
    root: root
  } do
    assert {:ok, store} = open_store(path: root)
    assert {:ok, ^store} = open_store(path: root)
    assert {:error, %Error{class: :validation}} = open_store(path: "relative/goals")
    assert {:ok, empty} = GoalContract.load(GoalStore, store, "header-1")
    assert {:ok, ^empty} = GoalState.new("header-1", [])
    assert [] == Path.wildcard(Path.join(root, "*.goal"))
  end

  test "CAS fences thread identity, revision and current goal identity", %{root: root} do
    {:ok, store} = open_store(path: root)
    {:ok, empty} = GoalState.new("thread", [])
    {:ok, created} = GoalState.create(empty, %{objective: "Finish migration"})

    assert {:ok, first} = cas(store, "thread", 0, nil, created)
    assert first.revision == 1
    assert {:error, %Error{class: :resource_conflict}} = cas(store, "thread", 0, nil, created)
    assert {:error, %Error{class: :resource_conflict}} = cas(store, "thread", 1, "wrong", first)
    assert {:error, %Error{class: :validation}} = cas(store, "other", 0, nil, created)

    assert {:error, %Error{class: :validation}} =
             cas(store, "thread", 1, first.goal.goal_id, %{first | revision: 0})

    assert {:ok, ^first} = GoalStore.load(store, "thread")
  end

  test "concurrent CAS acknowledgements have exactly one winner", %{root: root} do
    {:ok, store} = open_store(path: root)
    {:ok, empty} = GoalState.new("race", [])

    results =
      1..8
      |> Enum.map(fn n ->
        Task.async(fn ->
          {:ok, next} = GoalState.create(empty, %{objective: "Candidate #{n}"})
          cas(store, "race", 0, nil, next)
        end)
      end)
      |> Enum.map(&Task.await/1)

    assert 1 == Enum.count(results, &match?({:ok, %{revision: 1}}, &1))
    assert 7 == Enum.count(results, &match?({:error, %Error{class: :resource_conflict}}, &1))
  end

  test "symlink roots and ancestors cannot create independent CAS writers", %{root: root} do
    real = Path.join(root, "real")
    alias_path = Path.join(root, "alias")
    {:ok, store} = open_store(path: real)
    File.ln_s!(real, alias_path)

    assert {:error, %Error{class: :validation}} = open_store(path: alias_path)
    assert {:error, %Error{class: :validation}} = open_store(path: Path.join(alias_path, "child"))
    refute File.exists?(Path.join(real, "child"))

    {:ok, empty} = GoalState.new("same-thread", [])

    results =
      for n <- 1..4 do
        Task.async(fn ->
          {:ok, next} = GoalState.create(empty, %{objective: "Writer #{n}"})
          cas(store, "same-thread", 0, nil, next)
        end)
      end
      |> Enum.map(&Task.await/1)

    assert 1 == Enum.count(results, &match?({:ok, %{revision: 1}}, &1))
    assert 3 == Enum.count(results, &match?({:error, %Error{class: :resource_conflict}}, &1))
  end

  test "malformed usage accounting is rejected on CAS and on disk load", %{root: root} do
    {:ok, store} = open_store(path: root)
    {:ok, empty} = GoalState.new("thread", [])
    {:ok, committed} = cas(store, "thread", 0, nil, empty)
    [path] = Path.wildcard(Path.join(root, "*.goal"))

    malformed_usage = [
      %{},
      %{empty.usage | reports: nil},
      %{empty.usage | totals: %{}},
      %{empty.usage | totals: %{empty.usage.totals | cached_tokens: -1}},
      %{empty.usage | occupancy: nil}
    ]

    for usage <- malformed_usage do
      corrupt = %{committed | usage: usage}

      assert {:error, %Error{class: :validation}} =
               cas(store, "thread", 1, nil, corrupt)

      assert {:ok, ^committed} = GoalStore.load(store, "thread")
      File.write!(path, :erlang.term_to_binary(corrupt))
      assert {:error, %Error{class: :malformed_result}} = GoalStore.load(store, "thread")
      File.write!(path, :erlang.term_to_binary(committed))
    end
  end

  test "public usage ledger and exact interrupted turn identity survive restart", %{root: root} do
    {:ok, store} = open_store(path: root)
    {:ok, empty} = GoalState.new("thread", [])

    {:ok, usage, _receipt} =
      Backplane.AgentRuntime.Usage.report(empty.usage, %{
        identity: "attempt",
        input_tokens: 15,
        cached_tokens: 5,
        output_tokens: 3,
        reasoning_tokens: :unknown,
        occupancy_tokens: 20
      })

    next = %{empty | usage: usage, interrupted_turn: {"run", 1, "turn"}}
    assert {:ok, committed} = cas(store, "thread", 0, nil, next)
    GenServer.stop(store)
    {:ok, reopened} = open_store(path: root)
    assert {:ok, ^committed} = GoalStore.load(reopened, "thread")

    assert {:ok, _usage, %{status: :duplicate}} =
             Backplane.AgentRuntime.Usage.report(
               committed.usage,
               %{
                 identity: "attempt",
                 input_tokens: 15,
                 cached_tokens: 5,
                 output_tokens: 3,
                 reasoning_tokens: :unknown,
                 occupancy_tokens: 20
               }
             )
  end

  test "corrupt interrupted turn identity rejects CAS and persisted load", %{root: root} do
    {:ok, store} = open_store(path: root)
    {:ok, empty} = GoalState.new("thread", [])
    {:ok, committed} = cas(store, "thread", 0, nil, empty)
    [path] = Path.wildcard(Path.join(root, "*.goal"))

    for turn <- [{}, {"run", "turn"}, {"run", -1, "turn"}, {nil, 1, "turn"}] do
      corrupt = %{committed | interrupted_turn: turn}
      assert {:error, %Error{class: :validation}} = cas(store, "thread", 1, nil, corrupt)
      File.write!(path, :erlang.term_to_binary(corrupt))
      assert {:error, %Error{class: :malformed_result}} = GoalStore.load(store, "thread")
      File.write!(path, :erlang.term_to_binary(committed))
    end
  end

  test "full private snapshot and tombstone survive actual stop and reopen", %{root: root} do
    {:ok, store} = open_store(path: root)
    {:ok, empty} = GoalState.new("header/../opaque", [])
    {:ok, created} = GoalState.create(empty, %{objective: "Persist fences"})

    next = %{
      created
      | receipts: %{"receipt" => "digest"},
        invocations: %{{"run", 1, "call"} => %{digest: "digest", response: %{goal: nil}}},
        deliveries: %{"receipt" => %{response: %{goal: nil}, steering: nil}},
        continuation_deferral: %{reason: :interrupted},
        accounting_uncertain: true
    }

    assert {:ok, committed} = cas(store, empty.thread_id, 0, nil, next)
    [path] = Path.wildcard(Path.join(root, "*.goal"))
    assert Path.dirname(path) == root
    assert {:ok, %{mode: 0o100600}} = File.stat(path)
    assert {:ok, %{mode: 0o040700}} = File.stat(root)
    GenServer.stop(store)
    assert {:ok, reopened} = open_store(path: root)
    assert {:ok, ^committed} = GoalStore.load(reopened, empty.thread_id)

    {:ok, cleared} = GoalState.clear(committed)
    assert {:ok, tombstone} = cas(reopened, empty.thread_id, 1, committed.goal.goal_id, cleared)
    assert tombstone.revision == 2
    GenServer.stop(reopened)
    {:ok, again} = open_store(path: root)
    assert {:ok, ^tombstone} = GoalStore.load(again, empty.thread_id)

    assert {:error, %Error{class: :resource_conflict}} =
             cas(again, empty.thread_id, 0, nil, created)

    {:ok, recreated} = GoalState.create(tombstone, %{objective: "Next goal"})
    assert {:ok, %{revision: 3}} = cas(again, empty.thread_id, 2, nil, recreated)
  end

  test "malformed or unreadable records fail instead of resetting a goal", %{root: root} do
    {:ok, faults} = Agent.start_link(fn -> nil end)
    {:ok, store} = open_store(path: root, filesystem: {FaultableFileSystem, faults})
    {:ok, empty} = GoalState.new("thread", [])
    assert {:ok, committed} = cas(store, "thread", 0, nil, empty)
    [path] = Path.wildcard(Path.join(root, "*.goal"))
    Agent.update(faults, fn _ -> :read_error end)
    assert {:error, %Error{class: :execution_failure}} = GoalStore.load(store, "thread")
    Agent.update(faults, fn _ -> nil end)

    for bytes <- [
          "not a record",
          :erlang.term_to_binary(%{revision: 1, goal: nil}),
          :erlang.term_to_binary(%{committed | thread_id: "foreign"})
        ] do
      File.write!(path, bytes)
      assert {:error, %Error{class: :malformed_result}} = GoalStore.load(store, "thread")
    end
  end

  test "failed persistence preserves the last acknowledged revision", %{root: root} do
    {:ok, faults} = Agent.start_link(fn -> nil end)
    {:ok, store} = open_store(path: root, filesystem: {FaultableFileSystem, faults})
    {:ok, empty} = GoalState.new("thread", [])
    {:ok, created} = GoalState.create(empty, %{objective: "Remain durable"})
    {:ok, first} = cas(store, "thread", 0, nil, created)
    {:ok, complete} = GoalState.update(first, :model, %{status: :complete})
    Agent.update(faults, fn _ -> :write_error end)

    assert {:error, %Error{class: :execution_failure}} =
             cas(store, "thread", 1, first.goal.goal_id, complete)

    assert {:ok, ^first} = GoalStore.load(store, "thread")
  end

  test "live capabilities and malformed nested thread identities are never acknowledged", %{
    root: root
  } do
    {:ok, store} = open_store(path: root)
    {:ok, empty} = GoalState.new("thread", [])
    {:ok, created} = GoalState.create(empty, %{objective: "Validate record"})

    for handle <- [self(), make_ref(), fn -> :unsafe end] do
      unsafe = %{created | receipts: %{{:nested, handle} => "digest"}}

      assert {:error, %Error{class: :validation}} =
               GoalStore.compare_and_swap(store, "thread", 0, nil, unsafe)
    end

    foreign = %{created | goal: %{created.goal | thread_id: "foreign"}}
    assert {:error, %Error{class: :validation}} = cas(store, "thread", 0, nil, foreign)
    assert {:ok, ^empty} = GoalStore.load(store, "thread")
  end

  test "public Goal mutations persist idempotent responses and restart without creating a goal",
       %{root: root} do
    {:ok, store} = open_store(path: root)

    opts = [
      thread_id: "thread",
      owner_pid: self(),
      store: GoalStore,
      store_context: store,
      host: Host,
      host_context: self()
    ]

    {:ok, goal} = Goal.start_link(opts)
    assert {:ok, %{goal: nil}} = Goal.get(goal)
    binding = bind(goal, "run-1")

    operation = %{
      name: :create_goal,
      invocation_id: "create",
      binding: binding,
      arguments: %{objective: "Explicitly requested work"}
    }

    assert {:ok, response} = Goal.tool(goal, operation)
    assert {:ok, ^response} = Goal.tool(goal, operation)

    assert {:error, %Error{class: :resource_conflict}} =
             Goal.tool(goal, %{operation | invocation_id: "another"})

    assert {:ok, snapshot} = Goal.snapshot(goal)
    GenServer.stop(goal)
    GenServer.stop(store)

    {:ok, reopened} = open_store(path: root)
    {:ok, restored} = Goal.start_link(Keyword.put(opts, :store_context, reopened))
    assert {:ok, ^snapshot} = Goal.snapshot(restored)
    assert {:error, %Error{class: :forbidden}} = Goal.tool(restored, operation)
    fresh = bind(restored, "run-2")

    for status <- [:active, :budget_limited, :usage_limited] do
      assert {:error, %Error{class: :validation}} =
               Goal.tool(
                 restored,
                 %{
                   name: :update_goal,
                   invocation_id: "invalid-#{status}",
                   binding: fresh,
                   arguments: %{status: status}
                 }
               )
    end

    assert {:ok, %{goal: %{status: :complete}}} =
             Goal.tool(
               restored,
               %{
                 name: :update_goal,
                 invocation_id: "complete",
                 binding: fresh,
                 arguments: %{status: :complete}
               }
             )

    GenServer.stop(restored)
  end

  defp open_store(opts) do
    case GoalStore.open(opts) do
      {:ok, pid} = result ->
        on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
        result

      result ->
        result
    end
  end

  defp cas(store, thread, revision, goal_id, next),
    do: GoalContract.compare_and_swap(GoalStore, store, thread, revision, goal_id, next)

  defp bind(goal, run) do
    {:ok, binding} =
      Goal.bind(goal, %{
        thread_id: "thread",
        run_id: run,
        incarnation: 1,
        authority: %{run_id: run},
        usage_authoritative: false
      })

    binding
  end
end
