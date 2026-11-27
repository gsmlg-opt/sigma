defmodule Sigma.Agent.AutomaticRecoveryTerminalTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.TurnState

  setup do
    supervisor = start_supervised!(Task.Supervisor)
    %{supervisor: supervisor}
  end

  test "Stop remains cancelled when the owned task reports a persistence failure", c do
    owner = self()
    cancellation_ref = make_ref()
    source = "stopped-persistence-source"
    failure = {:event_persistence_failed, :message_end, :injected_write_failure}

    task =
      Task.async(fn ->
        receive do
          {:cancel, ^cancellation_ref} -> send(owner, :worker_observed_stop)
        end

        receive do
          :finish_with_persistence_failure -> {:error, failure}
        end
      end)

    on_exit(fn ->
      if Process.alive?(task.pid), do: Process.exit(task.pid, :kill)
    end)

    state = %{
      fixture(c.supervisor)
      | current_turn_task: task,
        turn_state: %TurnState{
          turn_id: source,
          phase: :streaming_provider,
          cancellation_ref: cancellation_ref
        }
    }

    assert {:reply, {:cancelling, ^source}, cancelling} =
             Sigma.Agent.handle_call(:cancel, {self(), make_ref()}, state)

    assert_receive :worker_observed_stop
    assert cancelling.turn_state.phase == :cancelling
    send(task.pid, :finish_with_persistence_failure)
    ref = task.ref
    pid = task.pid
    assert_receive {^ref, {:error, ^failure}} = terminal
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal} = down

    assert {:noreply, settled} = Sigma.Agent.handle_info(terminal, cancelling)
    assert settled.turn_state.phase == :cancelled
    assert settled.turn_state.turn_id == source
    assert settled.last_cancelled_turn_id == source
    assert settled.current_turn_task == nil
    assert settled.pending_host_prompt == nil
    assert settled.host_recovery_task == nil
    assert Task.Supervisor.children(c.supervisor) == []
    assert_receive {:turn_cancelled}
    refute_receive {:turn_error, _}, 0
    refute_receive {:recovery_started, _}, 0

    # Both messages belong to the actual settled Task. Neither delivery can
    # claim the source again or start a replacement preparation.
    assert {:noreply, ^settled} = Sigma.Agent.handle_info(terminal, settled)
    assert {:noreply, ^settled} = Sigma.Agent.handle_info(down, settled)
    assert Task.Supervisor.children(c.supervisor) == []
    refute_receive {:turn_cancelled}, 0
    refute_receive {:turn_error, _}, 0
    refute_receive {:recovery_started, _}, 0
  end

  test "an ineligible synthetic probe restores the failed source without a new prompt", c do
    source = "ineligible-recovery-source"
    previous = %TurnState{turn_id: source, phase: :failed}
    task = Task.async(fn -> {:host_continuation, {:ok, nil}} end)
    ref = task.ref
    assert_receive {^ref, {:host_continuation, {:ok, nil}}} = terminal

    state = %{
      fixture(c.supervisor)
      | turn_state: %TurnState{turn_id: source, phase: :session_operation},
        host_recovery_task: task,
        pending_host_prompt: %{
          item: %{
            turn_id: source,
            continuation_source: source,
            prepared_resources: [],
            metadata: %{automatic_recovery: true}
          },
          cancelled?: false,
          previous_turn_state: previous
        }
    }

    assert {:noreply, settled} = Sigma.Agent.handle_info(terminal, state)
    assert settled.turn_state == previous
    assert settled.pending_host_prompt == nil
    assert settled.host_recovery_task == nil
    assert settled.current_turn_task == nil
    assert Task.Supervisor.children(c.supervisor) == []
    refute_receive {:agent_start, _}, 0
    refute_receive {:recovery_started, _}, 0
    refute_receive {:prompt_admitted, _, _}, 0
    refute_receive {:turn_error, _}, 0
    assert {:noreply, ^settled} = Sigma.Agent.handle_info(terminal, settled)
  end

  @tag :session_delete_lifecycle
  test "an already admitted continuation completes a waiting deletion reservation", c do
    source = "already-admitted-source"
    tag = make_ref()
    monitor = Process.monitor(self())
    decision = %{"target" => %{"run_id" => "existing-target"}, "continuation_id" => "existing"}
    task = Task.async(fn -> {:host_continuation, {:already_admitted, decision}} end)
    ref = task.ref
    assert_receive {^ref, {:host_continuation, {:already_admitted, ^decision}}} = terminal

    state = %{
      fixture(c.supervisor)
      | turn_state: %TurnState{turn_id: source, phase: :session_operation},
        host_recovery_task: task,
        delete_operation: %{
          from: {self(), tag},
          monitor: monitor,
          status: :waiting,
          acquired?: false
        },
        pending_host_prompt: %{
          item: %{prepared_resources: []},
          cancelled?: true,
          previous_turn_state: %TurnState{turn_id: source, phase: :failed}
        }
    }

    assert {:noreply, reserved} = Sigma.Agent.handle_info(terminal, state)
    assert_receive {^tag, :ok}
    assert reserved.host_recovery_task == nil
    assert reserved.pending_host_prompt == nil
    assert reserved.delete_operation.status == :reserved
    assert reserved.turn_state.phase == :session_operation
    Process.demonitor(monitor, [:flush])
  end

  @tag :session_delete_lifecycle
  test "an acquired deletion reservation reopens when its actual owner exits", c do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    tag = make_ref()

    state = %{
      fixture(c.supervisor)
      | native_tools: false,
        goal_integration: nil,
        backplane_store: :retained_store
    }

    assert {:noreply, reserved} =
             Sigma.Agent.handle_call({:begin_session_operation, :delete}, {owner, tag}, state)

    assert reserved.delete_operation.status == :reserved
    monitor = reserved.delete_operation.monitor
    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal} = down
    assert {:noreply, released} = Sigma.Agent.handle_info(down, reserved)
    assert released.delete_operation == nil
    assert released.turn_state.phase == :idle

    assert {:reply, :ok, _} =
             Sigma.Agent.handle_call(:begin_session_operation, {self(), make_ref()}, released)
  end

  defp fixture(supervisor) do
    %Sigma.Agent{
      native_tools: true,
      host_retirement: %{},
      goal_integration: %{coordinator: self()},
      task_supervisor: supervisor,
      subscribers: [self()],
      session_id: "automatic-recovery-terminal",
      model: %{id: "test"}
    }
  end
end
