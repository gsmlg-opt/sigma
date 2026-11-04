defmodule Sigma.Agent.Backplane.GoalCoordinatorTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Error, Goal, GoalBridge}
  alias Backplane.AgentRuntime.Store, as: RuntimeStore
  alias Sigma.Agent.Backplane.{GoalCoordinator, GoalRuns, GoalStore, Store}

  defmodule Host do
    @behaviour Backplane.AgentRuntime.Goal.Host
    def record_user_instruction(_context, _thread, _instruction), do: :ok

    def start_turn_if_idle(_context, _thread, _request),
      do: {:ok, {:not_submitted, :test_host}}
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "sigma-goal-coordinator-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    goal_root = Path.join(root, ".goals")
    goal_store = start_supervised!({GoalStore, path: goal_root})
    runtime_store = start_supervised!({Store, path: Path.join(root, "session.runtime")})

    writer =
      start_supervised!(
        {Sigma.Session.Writer,
         [
           storage_id: Path.join(root, "renamable-session.jsonl"),
           session_id: "renamable-session",
           cwd: root
         ]}
      )

    on_exit(fn ->
      File.rm_rf!(root)
    end)

    owner = self()

    opts = [
      writer: writer,
      root: goal_root,
      cwd: root,
      runtime_store: runtime_store,
      host_context: %{
        record_instruction: fn thread, instruction ->
          send(owner, {:canonical_goal_instruction, thread, instruction})
          :ok
        end,
        reserve_turn: fn _thread, _request -> {:ok, {:not_submitted, :test_host}} end,
        release_turn: fn _thread, _admission -> :ok end
      }
    ]

    {:ok,
     root: root,
     goal_root: goal_root,
     goal_store: goal_store,
     runtime_store: runtime_store,
     writer: writer,
     opts: opts}
  end

  test "persistent identity comes from the durable header and startup creates no goal", context do
    coordinator = start_coordinator(context.opts)
    assert {:ok, %{thread_id: thread}} = GoalCoordinator.identity(coordinator)
    assert {:ok, selected} = apply(Sigma.Session.Writer, :selected_journal, [context.writer])
    assert [%{"type" => "session", "id" => ^thread}] = selected.entries
    refute thread == "renamable-session"
    assert {:ok, %{goal: nil}} = GoalCoordinator.get(coordinator)
    assert [] == Path.wildcard(Path.join(context.goal_root, "*.goal"))
    assert {:ok, []} = GoalRuns.list(context.goal_root, thread)

    assert {:error, %Error{class: :unsupported_capability}} =
             GoalCoordinator.start_link(Keyword.put(context.opts, :writer, nil))
  end

  test "bind acknowledges its durable index before returning public Goal context", context do
    coordinator = start_coordinator(context.opts)
    assert {:ok, %{thread_id: thread}} = GoalCoordinator.identity(coordinator)

    assert {:ok, %{goal: goal, goal_binding: binding, thread_id: ^thread}} =
             GoalCoordinator.bind(coordinator, attrs("run-1"))

    assert {:ok, ^binding} = Goal.attribution(goal, binding)

    assert {:ok, [%{run_id: "run-1", incarnation: 1, goal_id: nil}]} =
             GoalRuns.list(context.goal_root, thread)

    assert {:error, %Error{class: :forbidden}} =
             GoalCoordinator.bind(
               coordinator,
               Map.put(attrs("run-2"), :thread_id, "foreign")
             )

    assert {:ok, %{goal: nil}} = GoalCoordinator.get(coordinator)
  end

  test "one owner per stable header and shutdown retires its Goal process", context do
    coordinator = start_coordinator(context.opts)
    assert {:error, {:already_started, ^coordinator}} = GoalCoordinator.start_link(context.opts)
    assert {:ok, %{goal: goal}} = GoalCoordinator.bind(coordinator, attrs("run-1"))
    monitor = Process.monitor(goal)
    GenServer.stop(coordinator)
    assert_receive {:DOWN, ^monitor, :process, ^goal, _reason}
    reopened = start_coordinator(context.opts)
    assert {:ok, %{status: :recovery_required}} = GoalCoordinator.identity(reopened)

    assert {:error, %Error{class: :resource_conflict}} =
             GoalCoordinator.bind(reopened, attrs("replacement"))

    assert {:error, %Error{class: :resource_conflict}} = GoalCoordinator.idle(reopened, 1)
  end

  test "an explicit budget fails closed at binding without authoritative usage", context do
    coordinator = start_coordinator(context.opts)
    instruction = %{text: "Create this goal with a budget of 100 tokens"}

    assert {:ok, %{goal: %{token_budget: 100}}} =
             GoalCoordinator.set(
               coordinator,
               %{objective: "Explicit work", token_budget: 100},
               instruction
             )

    assert_receive {:canonical_goal_instruction, _thread, ^instruction}

    assert {:error, %Error{class: :unsupported_capability}} =
             GoalCoordinator.bind(coordinator, attrs("run-1"))
  end

  test "owned runtime store is ready before Agent admission and stops with its coordinator",
       context do
    opts =
      context.opts
      |> Keyword.delete(:runtime_store)
      |> Keyword.put(:runtime_store_path, Path.join(context.root, "owned.runtime"))

    coordinator = start_coordinator(opts)

    assert {:ok, %{goal: goal, thread_id: thread, runtime_store: store}} =
             GoalCoordinator.runtime_context(coordinator)

    assert is_pid(goal) and is_binary(thread) and Process.alive?(store)
    monitor = Process.monitor(store)
    GenServer.stop(coordinator)
    assert_receive {:DOWN, ^monitor, :process, ^store, _reason}

    for path <- [nil, "relative.runtime"] do
      assert {:error, %Error{class: :validation}} =
               GoalCoordinator.start_link(
                 opts
                 |> Keyword.delete(:runtime_store_path)
                 |> Keyword.put(:runtime_store_path, path)
               )
    end
  end

  test "idle reservation returns from Goal before a separate release callback", context do
    owner = self()
    host = context.opts[:host_context]

    host = %{
      host
      | reserve_turn: fn thread, request ->
          send(owner, {:reserved, thread, request.host_generation})
          {:ok, {:started, %{run_id: "automatic", incarnation: 1, turn_id: "automatic"}}}
        end,
        release_turn: fn thread, admission ->
          send(owner, {:released, thread, admission.run_id})
          :ok
        end
    }

    coordinator = start_coordinator(Keyword.put(context.opts, :host_context, host))

    assert {:ok, _} =
             GoalCoordinator.set(coordinator, %{objective: "Explicit work"}, %{
               text: "Continue to finish"
             })

    assert {:ok, {:started, %{run_id: "automatic"}}} = GoalCoordinator.idle(coordinator, 7)
    assert_receive {:reserved, thread, 7}
    assert_receive {:released, ^thread, "automatic"}
    assert {:ok, {:not_submitted, :already_reserved}} = GoalCoordinator.idle(coordinator, 7)
  end

  test "public recovery can fence an old run, redeliver exact receipts, and durably ACK its outbox",
       context do
    {:ok, goal} =
      Goal.start_link(
        thread_id: "public-recovery",
        owner_pid: self(),
        store: GoalStore,
        store_context: context.goal_store,
        host: Host,
        host_context: nil
      )

    assert {:ok, _} =
             Goal.set(goal, %{objective: "Account committed work"}, %{text: "Finish work"})

    {:ok, snapshot} = Goal.snapshot(goal)

    receipt = %{
      receipt_id: "saved-receipt",
      revision: 1,
      thread_id: "public-recovery",
      run_id: "old-run",
      incarnation: 1,
      turn_id: "turn",
      expected_goal_id: snapshot.goal.goal_id,
      type: :usage,
      payload: %{
        identity: "attempt",
        attempt_id: "attempt",
        input_tokens: 15,
        cached_tokens: 5,
        output_tokens: 3
      }
    }

    run = %{
      run_id: "old-run",
      incarnation: 1,
      expected_revision: 0,
      state: :queued,
      deadline: nil,
      outcome: nil,
      children: [],
      context: %{conversation: %{goal_outbox: [receipt]}}
    }

    assert {:ok, _} =
             RuntimeStore.store(Store, context.runtime_store, run, %{
               command: {:admit, 1, %{state: :running}}
             })

    assert {:ok, saved} = Store.load(context.runtime_store, "old-run")

    assert {:ok, %{run: fenced}} =
             RuntimeStore.fence(Store, context.runtime_store, "old-run", 1, 1, 2)

    assert {:ok, _} = Goal.restore(goal)

    assert {:ok, binding} =
             Goal.bind(goal, %{
               thread_id: "public-recovery",
               run_id: "old-run",
               incarnation: 1,
               authority: %{run_id: "old-run", grants: []},
               usage_authoritative: false
             })

    assert {:ok, _} = GoalBridge.redeliver(goal, binding, saved.run)
    assert {:ok, _} = GoalBridge.redeliver(goal, binding, saved.run)
    assert {:ok, %{goal: %{tokens_used: 13}}} = Goal.get(goal)
    conversation = %{goal_outbox: []}

    assert {:ok, %{revision: 3}} =
             RuntimeStore.store(Store, context.runtime_store, fenced, %{
               command:
                 {:conversation_updated, 2,
                  %{run_id: "old-run", incarnation: 2, conversation: conversation}}
             })

    assert {:ok, %{run: %{incarnation: 2, context: %{conversation: %{goal_outbox: []}}}}} =
             Store.load(context.runtime_store, "old-run")

    assert {:error, %Error{class: :resource_conflict}} =
             RuntimeStore.store(Store, context.runtime_store, saved.run, %{
               command:
                 {:conversation_updated, 3,
                  %{run_id: "old-run", incarnation: 1, conversation: conversation}}
             })

    GenServer.stop(goal)
  end

  defp start_coordinator(opts) do
    start_supervised!({GoalCoordinator, opts}, id: make_ref(), restart: :temporary)
  end

  defp attrs(run),
    do: %{
      run_id: run,
      incarnation: 1,
      authority: %{run_id: run, grants: []},
      mode: :execution,
      usage_authoritative: false
    }
end
