defmodule Sigma.Agent.BackplaneGoalTerminalRecoveryFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Store, as: RuntimeStore
  alias Sigma.Agent.Backplane.{GoalCoordinator, GoalRuns, GoalStore, Store}
  alias Sigma.Session.Writer

  @moduletag :tmp_dir
  @moduletag :goal_terminal_recovery_functional

  defmodule FaultableFileSystem do
    def ensure_dir(_control, path), do: Store.FileSystem.ensure_dir(path)
    def read(_control, path), do: Store.FileSystem.read(path)

    def write_atomic(control, path, bytes) do
      record = :erlang.binary_to_term(bytes, [:safe])

      reject? =
        case Agent.get(control, & &1) do
          :goal_commit ->
            map_size(get_in(record, [:usage, :reports]) || %{}) > 0

          :runtime_ack ->
            Enum.any?(get_in(record, [:transition, :events]) || [], fn event ->
              event.type == "run.goal_outbox_acknowledged"
            end)

          :allow ->
            false
        end

      if reject?,
        do: {:error, :injected_terminal_goal_failure},
        else: Store.FileSystem.write_atomic(path, bytes)
    end
  end

  setup %{tmp_dir: dir} do
    goal_fault = start_supervised!({Agent, fn -> :allow end}, id: :goal_fault)
    runtime_fault = start_supervised!({Agent, fn -> :allow end}, id: :runtime_fault)
    goal_root = Path.join(dir, "goals")

    goal_store =
      start_supervised!(
        {GoalStore, path: goal_root, filesystem: {FaultableFileSystem, goal_fault}}
      )

    runtime_store =
      start_supervised!(
        {Store, path: Path.join(dir, "runtime"), filesystem: {FaultableFileSystem, runtime_fault}}
      )

    writer =
      start_supervised!(
        {Writer, storage_id: Path.join(dir, "session.jsonl"), session_id: "session", cwd: dir}
      )

    owner = self()

    opts = [
      writer: writer,
      cwd: dir,
      root: goal_root,
      runtime_store: runtime_store,
      host_context: %{
        record_instruction: fn thread, instruction ->
          send(owner, {:terminal_goal_instruction, thread, instruction})
          :ok
        end,
        reserve_turn: fn thread, request ->
          send(owner, {:terminal_goal_reservation, thread, request})
          {:ok, {:not_submitted, :test_host}}
        end,
        release_turn: fn _thread, _admission -> :ok end
      }
    ]

    %{
      opts: opts,
      goal_fault: goal_fault,
      runtime_fault: runtime_fault,
      goal_store: goal_store,
      runtime_store: runtime_store,
      goal_root: goal_root
    }
  end

  for {failure, charged} <- [goal_commit: 0, runtime_ack: 13] do
    test "terminal #{failure} failure retains exact receipts and its cause until durable recovery",
         c do
      coordinator = coordinator!(c.opts)

      assert {:ok, _} =
               GoalCoordinator.set(coordinator, %{objective: "Account completed work"}, %{
                 text: "Finish this explicitly requested work"
               })

      assert_receive {:terminal_goal_instruction, thread, _}

      assert {:ok, bound} =
               GoalCoordinator.bind(coordinator, %{
                 run_id: "terminal",
                 incarnation: 1,
                 mode: :execution,
                 usage_authoritative: false,
                 authority: %{run_id: "terminal", grants: []}
               })

      receipt = %{
        receipt_id: "terminal:usage",
        revision: 1,
        thread_id: thread,
        run_id: "terminal",
        incarnation: 1,
        turn_id: "logical",
        expected_goal_id: bound.goal_binding.expected_goal_id,
        type: :usage,
        payload: %{
          identity: "attempt",
          attempt_id: "attempt",
          input_tokens: 15,
          cached_tokens: 5,
          output_tokens: 3
        }
      }

      terminal!(c.runtime_store, receipt)
      assert {:ok, original} = Store.load(c.runtime_store, "terminal")
      assert {:ok, index} = GoalRuns.list(c.goal_root, thread)
      assert :ok = GenServer.stop(coordinator)
      fault = if unquote(failure) == :goal_commit, do: c.goal_fault, else: c.runtime_fault
      Agent.update(fault, fn _ -> unquote(failure) end)
      reopened = coordinator!(c.opts)

      for _ <- 1..2 do
        assert {:error, %Error{class: :execution_failure} = error} =
                 GoalCoordinator.recover(reopened)

        assert error.cause == :injected_terminal_goal_failure

        assert {:ok, %{status: :recovery_required, recovery_error: ^error}} =
                 GoalCoordinator.identity(reopened)

        assert {:ok, ^original} = Store.load(c.runtime_store, "terminal")
        assert original.run.context.conversation.goal_outbox == [receipt]
        assert {:ok, %{goal: %{tokens_used: unquote(charged)}}} = GoalCoordinator.get(reopened)

        assert {:error, %Error{class: :resource_conflict}} =
                 GoalCoordinator.set(reopened, %{status: :active}, %{text: "Do not admit yet"})

        assert {:error, %Error{class: :resource_conflict}} = GoalCoordinator.idle(reopened, 2)
      end

      refute_receive {:terminal_goal_instruction, _, _}, 0
      refute_receive {:terminal_goal_reservation, _, _}, 0
      Agent.update(fault, fn _ -> :allow end)
      assert {:ok, %{status: :ready, recovered_runs: 1}} = GoalCoordinator.recover(reopened)
      assert {:ok, %{goal: %{tokens_used: 13}}} = GoalCoordinator.get(reopened)
      assert {:ok, acknowledged} = Store.load(c.runtime_store, "terminal")
      assert acknowledged.revision == original.revision + 1
      assert acknowledged.run.state == :completed
      assert acknowledged.run.incarnation == original.run.incarnation
      assert acknowledged.run.outcome == original.run.outcome
      assert acknowledged.run.context.conversation.goal_outbox == []
      assert acknowledged.effects == []
      assert acknowledged.outbox == []
      assert {:ok, ^index} = GoalRuns.list(c.goal_root, thread)
      assert :ok = GenServer.stop(reopened)

      cold = coordinator!(c.opts)
      assert {:ok, %{status: :ready, recovered_runs: 1}} = GoalCoordinator.recover(cold)
      assert {:ok, %{goal: %{tokens_used: 13}}} = GoalCoordinator.get(cold)
      assert {:ok, ^acknowledged} = Store.load(c.runtime_store, "terminal")
      refute_receive {:terminal_goal_instruction, _, _}, 0
      refute_receive {:terminal_goal_reservation, _, _}, 0
    end
  end

  defp coordinator!(opts),
    do: start_supervised!({GoalCoordinator, opts}, id: make_ref(), restart: :temporary)

  defp terminal!(store, receipt) do
    run = %{
      run_id: "terminal",
      incarnation: 1,
      expected_revision: 0,
      state: :queued,
      deadline: nil,
      outcome: nil,
      children: [],
      context: %{conversation: %{goal_outbox: [receipt], retained: "  原文\r\n"}}
    }

    assert {:ok, _} =
             RuntimeStore.store(Store, store, run, %{command: {:admit, 1, %{state: :running}}})

    assert {:ok, running} = Store.load(store, "terminal")

    assert {:ok, _} =
             RuntimeStore.store(Store, store, running.run, %{
               command:
                 {:finish, 2,
                  %{
                    run_id: "terminal",
                    incarnation: 1,
                    status: :completed,
                    outcome: %{status: "completed"}
                  }}
             })
  end
end
