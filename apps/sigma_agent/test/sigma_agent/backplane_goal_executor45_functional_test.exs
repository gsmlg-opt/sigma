defmodule Sigma.Agent.BackplaneGoalExecutor45FunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Error
  alias Sigma.Agent.{Message, TurnState}
  alias Sigma.Agent.Backplane.{GoalCoordinator, GoalIntegration, GoalStore, Store}
  alias Sigma.Session.Writer

  @moduletag :tmp_dir
  @moduletag :codex_alignment_functional
  @identity ~w(run_id turn_id incarnation host_generation reservation_token)a

  defmodule FaultableFileSystem do
    def ensure_dir(_faults, path), do: Store.FileSystem.ensure_dir(path)
    def read(_faults, path), do: Store.FileSystem.read(path)

    def write_atomic(faults, path, bytes) do
      failed? =
        Agent.get_and_update(faults, fn state ->
          {state.fail?, %{state | writes: state.writes + 1}}
        end)

      if failed?,
        do: {:error, :injected_goal_settlement_write_failure},
        else: Store.FileSystem.write_atomic(path, bytes)
    end
  end

  setup %{tmp_dir: dir} do
    owner = self()
    tasks = start_supervised!(Task.Supervisor)
    faults = start_supervised!({Agent, fn -> %{fail?: false, writes: 0} end})
    goal_root = Path.join(dir, "goals")

    goal_store =
      start_supervised!({GoalStore, path: goal_root, filesystem: {FaultableFileSystem, faults}})

    runtime_store = start_supervised!({Store, path: Path.join(dir, "runtime")})

    writer =
      start_supervised!(
        {Writer, storage_id: Path.join(dir, "session.jsonl"), session_id: "executor", cwd: dir}
      )

    host = %{
      record_instruction: fn _thread, instruction ->
        message =
          Message.user("instruction-#{System.unique_integer([:positive])}", instruction.text)

        with {:ok, _} <- Writer.append(writer, {:message_end, message}), do: :ok
      end,
      reserve_turn: fn _thread, request ->
        send(owner, {:executor_reserved, request})

        {:ok,
         {:started,
          %{
            run_id: "executor-run-#{request.host_generation}",
            incarnation: 1,
            turn_id: "executor-turn-#{request.host_generation}"
          }}}
      end,
      release_turn: fn _thread, admission ->
        coordinator = self()
        control = :atomics.new(1, [])

        {:ok, executor} =
          Task.Supervisor.start_child(tasks, fn ->
            prepare = fn ->
              send(owner, {:executor_preparing, self(), admission})

              receive do
                :prepare_ok ->
                  {:ok, :prepared}

                :prepare_missing_run ->
                  # An actual public Store read supplies the preparation error.
                  # The separate monitor/gate, not record absence, proves no start.
                  result = Store.load(runtime_store, admission.run_id)
                  send(owner, {:executor_preparation_result, self(), result})
                  result
              end
            end

            execute = fn ->
              send(owner, {:executor_effect, self(), admission})
              :executed
            end

            result =
              GoalIntegration.execute_admission(
                %{coordinator: coordinator},
                admission,
                prepare,
                execute
              )

            send(owner, {:executor_result, self(), result})

            # Keep this real Task alive after preparation/execute returns so the
            # test distinguishes a returned value from the actual monitored DOWN.
            receive do
              :finish_executor -> :ok
            end
          end)

        send(owner, {:executor_released, executor, control, admission})
        {:ok, %{executor: executor, control: control}}
      end
    }

    opts = [
      writer: writer,
      cwd: dir,
      root: goal_root,
      runtime_store: runtime_store,
      owner_pid: owner,
      host_context: host
    ]

    coordinator = coordinator!(opts)

    assert {:ok, _} =
             GoalCoordinator.set(coordinator, %{objective: "Finish requested ordinary work"}, %{
               text: "Continue the explicitly requested Goal"
             })

    assert {:ok, %{thread_id: thread}} = GoalCoordinator.identity(coordinator)

    %{
      coordinator: coordinator,
      goal_store: goal_store,
      runtime_store: runtime_store,
      thread: thread,
      opts: opts,
      tasks: tasks,
      faults: faults
    }
  end

  test "preparation failure settles only after the exact Task exits and permits another idle",
       c do
    original = record!(c)
    {executor, control, admission} = idle!(c.coordinator, 1)
    fail_preparation!(executor)
    assert Process.alive?(executor)
    assert executor in Task.Supervisor.children(c.tasks)
    assert :atomics.get(control, 1) == 0
    assert record!(c) == original
    assert {:ok, {:not_submitted, :already_reserved}} = GoalCoordinator.idle(c.coordinator, 2)
    refute_receive {:goal_executor_settled, _, _, _, _, _}, 20
    refute_receive {:executor_effect, _, _}, 0

    finish_executor!(executor)
    assert_settled!(c.coordinator, executor, control, admission, :preparation_failed)
    assert :atomics.get(control, 1) == 4
    settled = record!(c)
    assert_receipt!(settled, original, admission, :preparation_failed)

    {next, next_control, next_admission} = idle!(c.coordinator, 3)
    refute next_admission.reservation_token == admission.reservation_token
    execute!(next, next_control, next_admission)
    assert record!(c) == settled
  end

  for {reason, seal} <- [cancelled: 2, superseded: 3] do
    test "#{reason} wins the host gate before effects and survives coordinator reopening", c do
      assert_host_gate!(c, unquote(reason), unquote(seal))
    end
  end

  test "a queued force-cancel timer retains an already received real preparation error", c do
    original = record!(c)
    owner = self()

    task =
      Task.Supervisor.async_nolink(c.tasks, fn ->
        assert {:error, %Error{class: :not_found} = error} =
                 Store.load(c.runtime_store, "missing-force-cancel-preparation")

        {:goal_unstarted, error}
      end)

    ref = task.ref
    executor = task.pid
    assert_receive {^ref, {:goal_unstarted, %Error{class: :not_found} = actual}} = result, 5_000
    assert_receive {:DOWN, ^ref, :process, ^executor, :normal} = down, 5_000
    refute Process.alive?(executor)

    turn_id = "force-cancel-preparation"
    timer_message = {:force_cancel, turn_id, ref}
    timer = Process.send_after(self(), timer_message, 0)
    assert_receive ^timer_message, 5_000
    control = :atomics.new(1, [])

    state = %Sigma.Agent{
      current_turn_task: task,
      goal_executor_control: control,
      goal_executor_settlement: nil,
      goal_resume_pending: true,
      turn_state: %TurnState{turn_id: turn_id, phase: :cancelling, cancel_timer: timer},
      on_event: fn event ->
        send(owner, {:unexpected_preparation_event, event})
        :ok
      end,
      subscribers: [owner]
    }

    assert {:noreply, pending} = Sigma.Agent.handle_info(result, state)
    assert pending.pending_goal_result == %{error: actual}
    assert pending.current_turn_task == task
    assert pending.turn_state.phase == :cancelling
    assert pending.turn_state.cancel_timer == nil

    # The actual Task result and DOWN have already been received. The queued
    # timer still calls Task.shutdown on that dead Task; its noproc disposition
    # cannot replace the original preparation failure while settlement is pending.
    assert {:noreply, after_timer} = Sigma.Agent.handle_info(timer_message, pending)
    assert after_timer.pending_goal_result == %{error: actual}
    assert after_timer.current_turn_task == task
    assert after_timer.turn_state.phase == :cancelling
    assert after_timer.goal_executor_settlement == nil
    assert after_timer.goal_resume_pending

    assert {:noreply, after_down} = Sigma.Agent.handle_info(down, after_timer)
    assert after_down.pending_goal_result == %{error: actual}
    assert after_down.current_turn_task == task
    assert after_down.turn_state.phase == :cancelling
    assert record!(c) == original
    refute_receive {:unexpected_preparation_event, _}, 0
    refute_receive {:turn_error, _}, 0
    refute_receive {:agent_end, _}, 0
  end

  test "an executor that opens its effect gate never produces an unstarted receipt on exit", c do
    original = record!(c)
    {executor, control, admission} = idle!(c.coordinator, 1)
    execute!(executor, control, admission)
    assert :atomics.get(control, 1) == 1
    assert record!(c) == original

    assert {:ok, %{status: :ready, recovery_error: nil}} =
             GoalCoordinator.identity(c.coordinator)

    refute_receive {:goal_executor_settled, _, _, _, _, _}, 30
    assert record!(c).admission_settlements == %{}
  end

  test "a failed settlement write seals the Task and public recovery retries persistence only",
       c do
    original = record!(c)
    {executor, control, admission} = idle!(c.coordinator, 1)
    fail_preparation!(executor)
    Agent.update(c.faults, &%{&1 | fail?: true})
    finish_executor!(executor)

    assert_receive {:goal_executor_settled, coordinator, ^executor, ^control, ^admission,
                    {:error, %Error{class: :execution_failure} = actual}},
                   5_000

    assert coordinator == c.coordinator
    assert inspect(actual) =~ "injected_goal_settlement_write_failure"
    assert :atomics.get(control, 1) == 4
    assert record!(c) == original

    # Actual DOWN has already sealed this exact executor, while its failed
    # storage ACK may still be in the Agent mailbox. A later Stop cannot
    # relabel that immutable settlement as a new cancellation.
    ref = Process.monitor(executor)
    task = %Task{pid: executor, ref: ref, owner: self(), mfa: {:erlang, :apply, 2}}
    turn = %Sigma.Agent.TurnState{turn_id: admission.run_id, phase: :streaming_provider}

    pending = %Sigma.Agent{
      current_turn_task: task,
      goal_executor_control: control,
      turn_state: turn
    }

    assert {:reply, {:error, :no_active_turn}, ^pending} =
             Sigma.Agent.handle_call(:cancel, {self(), make_ref()}, pending)

    assert {:reply, :ok, ^pending} =
             Sigma.Agent.handle_call(
               {:cancel_prompt, admission.run_id},
               {self(), make_ref()},
               pending
             )

    Process.demonitor(ref, [:flush])

    assert {:ok, %{status: :recovery_required, recovery_error: ^actual}} =
             GoalCoordinator.identity(c.coordinator)

    assert {:error, %Error{class: :resource_conflict}} =
             GoalCoordinator.idle(c.coordinator, 2)

    refute_receive {:executor_effect, _, _}, 0
    Agent.update(c.faults, &%{&1 | fail?: false})
    writes = Agent.get(c.faults, & &1.writes)

    assert {:ok, %{status: :ready, recovered_runs: 0}} =
             GoalCoordinator.recover(c.coordinator)

    assert_settled!(c.coordinator, executor, control, admission, :preparation_failed)
    settled = record!(c)
    assert_receipt!(settled, original, admission, :preparation_failed)
    assert Agent.get(c.faults, & &1.writes) == writes + 1

    assert {:ok, %{status: :ready, recovered_runs: 0}} =
             GoalCoordinator.recover(c.coordinator)

    assert record!(c) == settled
    assert Agent.get(c.faults, & &1.writes) == writes + 1
    refute_receive {:executor_preparing, _, _}, 0
    refute_receive {:executor_released, _, _, _}, 0
    refute_receive {:executor_effect, _, _}, 0
  end

  defp coordinator!(opts),
    do: start_supervised!({GoalCoordinator, opts}, id: make_ref(), restart: :temporary)

  defp assert_host_gate!(c, reason, seal) do
    original = record!(c)
    {executor, control, admission} = idle!(c.coordinator, 1)
    assert :ok = :atomics.compare_exchange(control, 1, 0, seal)
    send(executor, :prepare_ok)

    assert_receive {:executor_result, ^executor, {:goal_unstarted, %Error{class: :cancelled}}},
                   5_000

    assert Process.alive?(executor)
    assert record!(c) == original
    refute_receive {:executor_effect, _, _}, 0
    finish_executor!(executor)
    assert_settled!(c.coordinator, executor, control, admission, reason)
    assert :atomics.get(control, 1) == 4
    settled = record!(c)
    assert_receipt!(settled, original, admission, reason)

    if reason == :cancelled do
      assert settled.continuation_deferral ==
               Map.put(Map.take(admission, @identity), :reason, :cancelled)
    else
      assert settled.continuation_deferral == nil
    end

    assert :ok = GenServer.stop(c.coordinator)
    reopened = coordinator!(c.opts)
    assert record!(c) == settled

    if reason == :cancelled do
      assert {:ok, {:not_submitted, :deferred}} = GoalCoordinator.idle(reopened, 2)
      assert record!(c) == settled
      refute_receive {:executor_released, _, _, _}, 0
    else
      {next, next_control, next_admission} = idle!(reopened, 2)
      execute!(next, next_control, next_admission)
      assert record!(c) == settled
    end
  end

  defp idle!(coordinator, generation) do
    assert {:ok, {:started, admission}} = GoalCoordinator.idle(coordinator, generation)
    assert_receive {:executor_reserved, request}, 5_000
    assert request.reservation_token == admission.reservation_token
    assert_receive {:executor_released, executor, control, ^admission}, 5_000
    assert_receive {:executor_preparing, ^executor, ^admission}, 5_000
    {executor, control, admission}
  end

  defp fail_preparation!(executor) do
    send(executor, :prepare_missing_run)

    assert_receive {:executor_preparation_result, ^executor,
                    {:error, %Error{class: :not_found} = error}},
                   5_000

    assert_receive {:executor_result, ^executor, {:goal_unstarted, ^error}}, 5_000
  end

  defp execute!(executor, control, admission) do
    send(executor, :prepare_ok)
    assert_receive {:executor_effect, ^executor, ^admission}, 5_000
    assert :atomics.get(control, 1) == 1
    assert_receive {:executor_result, ^executor, :executed}, 5_000
    finish_executor!(executor)
  end

  defp finish_executor!(executor) do
    monitor = Process.monitor(executor)
    send(executor, :finish_executor)
    assert_receive {:DOWN, ^monitor, :process, ^executor, :normal}, 5_000
  end

  defp assert_settled!(coordinator, executor, control, admission, reason) do
    assert_receive {:goal_executor_settled, ^coordinator, ^executor, ^control, ^admission,
                    {:ok, {:settled, ^reason}}},
                   5_000
  end

  defp record!(c) do
    assert {:ok, record} = GoalStore.load(c.goal_store, c.thread)
    record
  end

  defp assert_receipt!(record, original, admission, reason) do
    identity = Map.take(admission, @identity)

    assert record.admission_settlements == %{
             admission.reservation_token => %{
               thread_id: original.thread_id,
               expected_goal_id: original.goal.goal_id,
               admission: identity,
               reason: reason,
               response: {:settled, reason},
               attestation: %{
                 admission: identity,
                 executor: :confirmed_down,
                 runtime_admission: :never_started,
                 future_start: :fenced,
                 effects: :none_dispatched
               }
             }
           }

    assert record.revision == original.revision + 1
    # The public Goal clock may account elapsed active wall time at this CAS.
    assert Map.delete(record.goal, :time_used_seconds) ==
             Map.delete(original.goal, :time_used_seconds)

    assert record.goal.time_used_seconds >= original.goal.time_used_seconds
  end
end
