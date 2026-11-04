defmodule Sigma.Agent.BackplaneGoalCoordinatorFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Error, Goal}
  alias Backplane.AgentRuntime.Store, as: RuntimeStore
  alias Sigma.Agent.Backplane.{GoalCoordinator, GoalRuns, GoalStore, Store}
  alias Sigma.Agent.Runtime

  @moduletag :tmp_dir

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    def stream(params) do
      send(params.options[:test_pid], {:ordinary_goal_prompt, params})

      message = %{
        role: :assistant,
        content: [%{type: :text, text: "ordinary prompt completed"}],
        stop_reason: :stop,
        usage: %{input: 1, output: 1, total_tokens: 2},
        model: "test",
        provider: "test",
        api: "openai-responses",
        timestamp: System.system_time(:millisecond)
      }

      [{:start, %{message | content: []}}, {:done, :stop, message}]
    end
  end

  setup %{tmp_dir: dir} do
    goal_root = Path.join(dir, "goals")
    goal_store = start_supervised!({GoalStore, path: goal_root})
    store = start_supervised!({Store, path: Path.join(dir, "runtime")})
    name = {:via, Registry, {Sigma.Agent.RepositoryRegistry, {:functional_goal_writer, dir}}}

    writer =
      start_supervised!(
        {Sigma.Session.Writer,
         name: name, storage_id: Path.join(dir, "session.jsonl"), session_id: "goal", cwd: dir}
      )

    opts = [
      writer: name,
      cwd: dir,
      root: goal_root,
      runtime_store: store,
      host_context: %{
        record_instruction: fn _thread, _instruction -> :ok end,
        reserve_turn: fn _thread, _request -> {:ok, {:not_submitted, :test_host}} end,
        release_turn: fn _thread, _admission -> :ok end
      }
    ]

    on_exit(fn ->
      case Runtime.lookup(dir, :supervisor) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
      end
    end)

    %{opts: opts, store: store, goal_root: goal_root, goal_store: goal_store, writer: writer}
  end

  test "a Registry Writer reference binds the immutable header and monitors its actual owner",
       c do
    coordinator = coordinator!(c.opts)
    assert {:ok, %{thread_id: thread}} = GoalCoordinator.identity(coordinator)
    assert {:ok, selected} = Sigma.Session.Writer.selected_journal(c.opts[:writer])
    assert [%{"type" => "session", "id" => ^thread}] = selected.entries
    monitor = Process.monitor(coordinator)
    assert :ok = GenServer.stop(c.writer, :normal)
    assert_receive {:DOWN, ^monitor, :process, ^coordinator, :normal}, 5_000
  end

  test "clean terminal indexed runs recover after cold coordinator startup without rewriting snapshots",
       c do
    coordinator = coordinator!(c.opts)
    create_goal!(coordinator)
    assert {:ok, context} = GoalCoordinator.bind(coordinator, attrs("clean"))
    persist_run!(c.store, "clean", [], :completed)
    assert {:ok, original} = Store.load(c.store, "clean")
    assert {:ok, index} = GoalRuns.list(c.goal_root, context.thread_id)
    assert :ok = GenServer.stop(coordinator)

    reopened = coordinator!(c.opts)
    assert {:ok, %{status: :recovery_required}} = GoalCoordinator.identity(reopened)
    assert {:ok, %{status: :ready, recovered_runs: 1}} = GoalCoordinator.recover(reopened)
    assert {:ok, %{status: :ready, recovery_error: nil}} = GoalCoordinator.identity(reopened)
    assert {:ok, ^original} = Store.load(c.store, "clean")
    assert {:ok, ^index} = GoalRuns.list(c.goal_root, context.thread_id)
    assert {:ok, %{status: :ready, recovered_runs: 0}} = GoalCoordinator.recover(reopened)
    assert {:ok, _} = GoalCoordinator.bind(reopened, attrs("next"))
    refute_receive {:ordinary_goal_prompt, _}, 0
  end

  test "clean history from before and during an older Goal does not bind to a replacement Goal",
       c do
    coordinator = coordinator!(c.opts)
    assert {:ok, early} = GoalCoordinator.bind(coordinator, attrs("before-goal"))
    assert early.goal_binding.expected_goal_id == nil
    persist_run!(c.store, "before-goal", [], :completed)
    create_goal!(coordinator)
    assert {:ok, older} = GoalCoordinator.bind(coordinator, attrs("older-goal"))
    persist_run!(c.store, "older-goal", [], :completed)
    assert {:ok, before_run} = Store.load(c.store, "before-goal")
    assert {:ok, older_run} = Store.load(c.store, "older-goal")
    assert {:ok, index} = GoalRuns.list(c.goal_root, older.thread_id)
    assert :ok = GenServer.stop(coordinator)

    # The ordinary public host lifecycle clears the previous Goal and creates
    # its successor; old terminal run identities remain in the durable index.
    assert {:ok, owner} =
             Goal.start_link(
               thread_id: older.thread_id,
               owner_pid: self(),
               store: GoalStore,
               store_context: c.goal_store,
               host: Sigma.Agent.Backplane.GoalHost,
               host_context: c.opts[:host_context]
             )

    assert {:ok, _} = Goal.clear(owner, %{text: "Replace the previous requested Goal"})

    assert {:ok, _} =
             Goal.set(owner, %{objective: "Later explicit work"}, %{
               text: "Start the replacement Goal"
             })

    assert {:ok, replacement} = Goal.snapshot(owner)
    refute replacement.goal.goal_id == older.goal_binding.expected_goal_id
    assert :ok = GenServer.stop(owner)

    reopened = coordinator!(c.opts)
    assert {:ok, %{status: :ready, recovered_runs: 0}} = GoalCoordinator.recover(reopened)

    assert {:ok, %{goal: %{objective: "Later explicit work", tokens_used: 0}}} =
             GoalCoordinator.get(reopened)

    assert {:ok, ^replacement} = GoalStore.load(c.goal_store, older.thread_id)
    assert {:ok, ^before_run} = Store.load(c.store, "before-goal")
    assert {:ok, ^older_run} = Store.load(c.store, "older-goal")
    assert {:ok, ^index} = GoalRuns.list(c.goal_root, older.thread_id)
    assert {:ok, %{status: :ready, recovery_error: nil}} = GoalCoordinator.identity(reopened)
    refute_receive {:ordinary_goal_prompt, _}, 0
  end

  test "retained terminal receipts recover exactly once through the public terminal ACK", c do
    coordinator = coordinator!(c.opts)
    create_goal!(coordinator)
    assert {:ok, context} = GoalCoordinator.bind(coordinator, attrs("retained"))
    assert {:ok, record} = GoalStore.load(c.goal_store, context.thread_id)
    receipt = receipt(context.thread_id, record.goal.goal_id, "retained")
    persist_run!(c.store, "retained", [receipt], :completed)
    assert {:ok, original} = Store.load(c.store, "retained")
    assert original.run.context.conversation.goal_outbox == [receipt]
    assert {:ok, index} = GoalRuns.list(c.goal_root, context.thread_id)
    assert :ok = GenServer.stop(coordinator)
    reopened = coordinator!(c.opts)

    assert {:ok, %{status: :recovery_required}} = GoalCoordinator.identity(reopened)
    assert {:ok, %{goal: %{tokens_used: 0}}} = GoalCoordinator.get(reopened)

    # The running-conversation checkpoint remains invalid for a terminal run;
    # recovery must use the published exact-receipt terminal ACK instead.
    assert {:error, %Error{}} =
             RuntimeStore.store(Store, c.store, original.run, %{
               command:
                 {:conversation_updated, 3,
                  %{run_id: "retained", incarnation: 1, conversation: %{goal_outbox: []}}}
             })

    assert {:ok, ^original} = Store.load(c.store, "retained")
    assert {:ok, %{status: :ready, recovered_runs: 1}} = GoalCoordinator.recover(reopened)
    assert {:ok, %{status: :ready, recovery_error: nil}} = GoalCoordinator.identity(reopened)
    assert {:ok, %{goal: %{tokens_used: 13}}} = GoalCoordinator.get(reopened)
    assert {:ok, acknowledged} = Store.load(c.store, "retained")
    assert acknowledged.revision == original.revision + 1
    assert acknowledged.run.state == original.run.state
    assert acknowledged.run.incarnation == original.run.incarnation
    assert acknowledged.run.outcome == original.run.outcome
    assert acknowledged.run.context.conversation.goal_outbox == []
    assert acknowledged.effects == []
    assert acknowledged.outbox == []
    assert {:ok, ^index} = GoalRuns.list(c.goal_root, context.thread_id)

    assert {:ok, %{status: :ready, recovered_runs: 0}} = GoalCoordinator.recover(reopened)
    assert {:ok, ^acknowledged} = Store.load(c.store, "retained")
    assert :ok = GenServer.stop(reopened)
    cold = coordinator!(c.opts)
    assert {:ok, %{status: :ready, recovered_runs: 1}} = GoalCoordinator.recover(cold)
    assert {:ok, %{goal: %{tokens_used: 13}}} = GoalCoordinator.get(cold)
    assert {:ok, ^acknowledged} = Store.load(c.store, "retained")
    refute_receive {:ordinary_goal_prompt, _}, 0
  end

  test "missing and running indexed runs remain diagnosed without replacing their evidence", c do
    coordinator = coordinator!(c.opts)
    assert {:ok, _} = GoalCoordinator.bind(coordinator, attrs("missing"))
    assert :ok = GenServer.stop(coordinator)
    reopened = coordinator!(c.opts)
    assert {:error, %Error{class: :not_found}} = GoalCoordinator.recover(reopened)
    assert {:ok, %{status: :recovery_required}} = GoalCoordinator.identity(reopened)

    persist_run!(c.store, "missing", [], :running)
    assert {:ok, original} = Store.load(c.store, "missing")
    assert {:error, %Error{class: :resource_conflict}} = GoalCoordinator.recover(reopened)
    assert {:ok, ^original} = Store.load(c.store, "missing")
    refute_receive {:ordinary_goal_prompt, _}, 0
  end

  test "uncertain terminal cleanup remains a recovery boundary", c do
    coordinator = coordinator!(c.opts)
    assert {:ok, _} = GoalCoordinator.bind(coordinator, attrs("uncertain"))
    persist_run!(c.store, "uncertain", [], :running)
    assert {:ok, running} = Store.load(c.store, "uncertain")
    assert {:ok, _} = RuntimeStore.store(Store, c.store, running.run, %{command: {:cancel, 2}})
    assert {:ok, cancelling} = Store.load(c.store, "uncertain")

    assert {:ok, _} =
             RuntimeStore.store(Store, c.store, cancelling.run, %{
               command:
                 {:cleanup_settled, 3,
                  %{certainty: :uncertain, evidence: %{reason: "unconfirmed effect"}}}
             })

    assert {:ok, original} = Store.load(c.store, "uncertain")
    assert original.run.state == :unknown_outcome
    assert :ok = GenServer.stop(coordinator)
    reopened = coordinator!(c.opts)
    assert {:error, %Error{class: :resource_conflict}} = GoalCoordinator.recover(reopened)
    assert {:ok, ^original} = Store.load(c.store, "uncertain")
    assert {:ok, %{status: :recovery_required}} = GoalCoordinator.identity(reopened)
  end

  test "explicit cancellation withdraws the lease and durably defers without pausing the Goal",
       c do
    host = %{
      c.opts[:host_context]
      | reserve_turn: fn _thread, _request ->
          {:ok, {:started, %{run_id: "cancelled-lease", incarnation: 1, turn_id: "logical"}}}
        end,
        release_turn: fn _thread, _admission -> {:ok, {:not_submitted, :cancelled}} end
    }

    opts = Keyword.put(c.opts, :host_context, host)
    coordinator = coordinator!(opts)
    create_goal!(coordinator)
    assert {:ok, {:not_submitted, :cancelled}} = GoalCoordinator.idle(coordinator, 1)
    assert {:ok, %{goal: %{status: :active, tokens_used: 0}}} = GoalCoordinator.get(coordinator)
    assert :ok = GenServer.stop(coordinator)
    reopened = coordinator!(opts)
    assert {:ok, {:not_submitted, :deferred}} = GoalCoordinator.idle(reopened, 2)
    assert {:ok, %{goal: %{status: :active, tokens_used: 0}}} = GoalCoordinator.get(reopened)
  end

  test "a real ordinary prompt supersedes an unreleased lease and the next idle reserves again",
       c do
    assert {:ok, handle} =
             Runtime.get_session(c.tmp_dir, "ordinary-goal",
               cwd: c.tmp_dir,
               transcript_path: Path.join(c.tmp_dir, "ordinary-goal.jsonl"),
               provider: Provider,
               model: %{id: "test", provider: "test", api: "openai-responses"},
               tools: [],
               hook_specs: [],
               options: [test_pid: self()]
             )

    :ok = Sigma.Agent.subscribe(handle.agent)
    control = start_supervised!({Agent, fn -> %{lease: nil, prompted: false} end})
    owner = self()

    host = %{
      c.opts[:host_context]
      | reserve_turn: fn _thread, request ->
          assert Sigma.Agent.status(handle.agent).phase in [:idle, :completed]
          Agent.update(control, &%{&1 | lease: request})
          send(owner, {:goal_reserved, request})

          {:ok,
           {:started,
            %{
              run_id: "automatic-#{request.host_generation}",
              incarnation: 1,
              turn_id: "logical-#{request.host_generation}"
            }}}
        end,
        release_turn: fn _thread, admission ->
          assert Agent.get(control, & &1.lease.reservation_token) == admission.reservation_token

          if Agent.get(control, & &1.prompted) do
            :ok
          else
            # The host fences this exact slot before returning a definitive
            # no-submission result. Actual Agent admission starts the user turn.
            Agent.update(control, &%{&1 | lease: nil, prompted: true})

            assert {:accepted, _} =
                     Sigma.Agent.prompt(handle.agent, "User supersedes continuation")

            {:ok, {:not_submitted, :superseded}}
          end
        end
    }

    coordinator = coordinator!(Keyword.put(c.opts, :host_context, host))
    create_goal!(coordinator)
    assert {:ok, {:not_submitted, :superseded}} = GoalCoordinator.idle(coordinator, 1)
    assert_receive {:goal_reserved, first}, 5_000
    assert_receive {:ordinary_goal_prompt, params}, 5_000
    assert inspect(params.context.messages) =~ "User supersedes continuation"
    assert_receive {:agent_end, _}, 5_000
    assert {:ok, {:started, second}} = GoalCoordinator.idle(coordinator, 2)
    assert_receive {:goal_reserved, next}, 5_000
    assert second.reservation_token == next.reservation_token
    refute second.reservation_token == first.reservation_token
    assert {:ok, %{status: :ready}} = GoalCoordinator.identity(coordinator)
    Agent.update(control, &%{&1 | lease: nil})

    assert {:ok, {:withdrawn, :superseded}} =
             GoalCoordinator.withdraw_admission(coordinator, second, :superseded)
  end

  defp coordinator!(opts),
    do: start_supervised!({GoalCoordinator, opts}, id: make_ref(), restart: :temporary)

  defp create_goal!(coordinator),
    do:
      assert(
        {:ok, _} =
          GoalCoordinator.set(coordinator, %{objective: "Finish ordinary work"}, %{
            text: "Continue this requested work"
          })
      )

  defp attrs(run),
    do: %{
      run_id: run,
      incarnation: 1,
      mode: :execution,
      usage_authoritative: false,
      authority: %{run_id: run, grants: []}
    }

  defp persist_run!(store, id, receipts, state) do
    run = %{
      run_id: id,
      incarnation: 1,
      expected_revision: 0,
      state: :queued,
      deadline: nil,
      outcome: nil,
      children: [],
      context: %{conversation: %{goal_outbox: receipts}}
    }

    assert {:ok, _} =
             RuntimeStore.store(Store, store, run, %{command: {:admit, 1, %{state: :running}}})

    if state == :completed do
      assert {:ok, saved} = Store.load(store, id)

      assert {:ok, _} =
               RuntimeStore.store(Store, store, saved.run, %{
                 command:
                   {:finish, 2,
                    %{
                      run_id: id,
                      incarnation: 1,
                      status: :completed,
                      outcome: %{status: "completed"}
                    }}
               })
    end
  end

  defp receipt(thread, goal_id, run),
    do: %{
      receipt_id: "#{run}:usage",
      revision: 1,
      thread_id: thread,
      run_id: run,
      incarnation: 1,
      turn_id: "turn",
      expected_goal_id: goal_id,
      type: :usage,
      payload: %{
        identity: "attempt",
        attempt_id: "attempt",
        input_tokens: 15,
        cached_tokens: 5,
        output_tokens: 3
      }
    }
end
