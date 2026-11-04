defmodule Sigma.Agent.Backplane.GoalRecoveryTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Conversation, Error, Goal, ToolRegistry}
  alias Backplane.AgentRuntime.Codex.Session
  alias Sigma.Agent.Backplane.{GoalCoordinator, GoalStore, Store}

  @moduletag :tmp_dir

  defmodule Provider do
    @behaviour Backplane.AgentRuntime.ConversationAdapter

    def stream(request, context) do
      send(context.test, {:goal_recovery_provider, request.run_id})

      [
        %{
          type: :response_completed,
          message: %{role: :assistant, content: "committed work"},
          usage: %{input_tokens: 15, cached_tokens: 5, output_tokens: 3}
        }
      ]
    end
  end

  defmodule FaultableFileSystem do
    def ensure_dir(_control, path), do: Store.FileSystem.ensure_dir(path)
    def read(_control, path), do: Store.FileSystem.read(path)

    def write_atomic(control, path, bytes) do
      record = :erlang.binary_to_term(bytes, [:safe])

      reject? =
        case Agent.get(control, & &1) do
          :reject_usage ->
            map_size(get_in(record, [:usage, :reports]) || %{}) > 0

          :reject_ack ->
            conversation = get_in(record, [:run, :context, :conversation]) || %{}
            conversation[:goal_outbox] == [] and is_map(conversation[:goal_usage])

          _ ->
            false
        end

      if reject?,
        do: {:error, :injected_goal_recovery_failure},
        else: Store.FileSystem.write_atomic(path, bytes)
    end
  end

  setup context do
    root = context.tmp_dir
    goal_root = Path.join(root, ".goals")
    goal_fault = start_supervised!({Agent, fn -> :allow end}, id: :goal_fault)
    runtime_fault = start_supervised!({Agent, fn -> :allow end}, id: :runtime_fault)

    goal_store =
      start_supervised!(
        {GoalStore, path: goal_root, filesystem: {FaultableFileSystem, goal_fault}}
      )

    runtime_store =
      start_supervised!(
        {Store,
         path: Path.join(root, "session.runtime"),
         filesystem: {FaultableFileSystem, runtime_fault}}
      )

    writer =
      start_supervised!(
        {Sigma.Session.Writer,
         storage_id: Path.join(root, "session.jsonl"), session_id: "session", cwd: root}
      )

    owner = self()

    opts = [
      writer: writer,
      cwd: root,
      root: goal_root,
      runtime_store: runtime_store,
      host_context: %{
        record_instruction: fn thread, instruction ->
          send(owner, {:goal_recovery_instruction, thread, instruction})
          :ok
        end,
        reserve_turn: fn thread, request ->
          send(owner, {:goal_recovery_reservation, thread, request})
          {:ok, {:not_submitted, :test_host}}
        end,
        release_turn: fn _thread, _admission -> :ok end
      }
    ]

    {:ok,
     opts: opts,
     goal_store: goal_store,
     runtime_store: runtime_store,
     goal_fault: goal_fault,
     runtime_fault: runtime_fault}
  end

  for {failure, charged} <- [undelivered: 0, ack_lost: 13] do
    test "unreconciled #{failure} receipts block Goal mutations before recording instructions",
         context do
      %{saved: saved, thread: thread} = pending(context, unquote(failure))
      Agent.update(context.goal_fault, fn _ -> :allow end)
      Agent.update(context.runtime_fault, fn _ -> :allow end)
      coordinator = start_coordinator(context.opts)

      assert {:ok, %{status: :recovery_required}} = GoalCoordinator.identity(coordinator)
      assert {:ok, goal_before} = GoalStore.load(context.goal_store, thread)
      assert goal_before.goal.tokens_used == unquote(charged)

      # Both snapshots are nonterminal; the undelivered receipt still has the
      # Provider identity, while the lost-ACK case has settled that effect.
      assert saved.run.state == :running

      if unquote(failure) == :undelivered,
        do: assert(is_map(saved.run.active_provider)),
        else: assert(is_nil(saved.run.active_provider))

      assert Enum.any?(saved.run.context.conversation.goal_outbox, &(&1.type == :usage))

      for mutation <- [
            %{status: :active},
            %{token_budget: 10},
            %{objective: "A later instruction"}
          ] do
        assert {:error, %Error{class: :resource_conflict}} =
                 GoalCoordinator.set(coordinator, mutation, %{text: "Do not cross recovery"})
      end

      assert {:error, %Error{class: :resource_conflict}} =
               GoalCoordinator.bind(coordinator, attrs("replacement"))

      assert {:error, %Error{class: :resource_conflict}} = GoalCoordinator.idle(coordinator, 2)
      assert {:ok, ^goal_before} = GoalStore.load(context.goal_store, thread)
      assert {:ok, ^saved} = Store.load(context.runtime_store, "committed-run")
      refute_receive {:goal_recovery_instruction, _, _}, 30
      refute_receive {:goal_recovery_provider, _}, 30
      refute_receive {:goal_recovery_reservation, _, _}, 30
    end
  end

  defp pending(context, failure) do
    coordinator = start_coordinator(context.opts)
    assert {:ok, %{thread_id: thread}} = GoalCoordinator.identity(coordinator)

    assert {:ok, _} =
             GoalCoordinator.set(
               coordinator,
               %{objective: "Account committed work", token_budget: 100},
               %{text: "Account this work with the requested budget"}
             )

    assert_receive {:goal_recovery_instruction, ^thread, _}

    assert {:ok, %{goal: goal, goal_binding: goal_binding}} =
             GoalCoordinator.bind(coordinator, attrs("committed-run"))

    authority = attrs("committed-run").authority
    session = start_supervised!({Session, owner_pid: self()}, id: make_ref())
    assert {:ok, session_binding} = Session.bind(session, authority)

    conversation =
      start_supervised!(
        {Conversation,
         run_id: "committed-run",
         store: Store,
         context: context.runtime_store,
         provider: Provider,
         provider_context: %{test: self()},
         subscriber: self(),
         registry: %ToolRegistry{},
         tools: [],
         authority: authority,
         session_binding: session_binding,
         goal: goal,
         goal_binding: goal_binding,
         thread_id: thread,
         run_timeout: :infinity},
        id: make_ref(),
        restart: :temporary
      )

    if failure == :undelivered,
      do: Agent.update(context.goal_fault, fn _ -> :reject_usage end),
      else: Agent.update(context.runtime_fault, fn _ -> :reject_ack end)

    assert {:ok, _} = Conversation.prompt(conversation, "Perform exactly one provider request")
    assert_receive {:goal_recovery_provider, "committed-run"}
    assert_receive {:agent_runtime, "committed-run", %{type: :storage_failed}}, 5_000
    assert {:ok, saved} = Store.load(context.runtime_store, "committed-run")
    assert Enum.any?(saved.run.context.conversation.goal_outbox, &(&1.type == :usage))
    assert {:ok, %{goal: %{tokens_used: tokens}}} = Goal.get(goal)
    assert tokens == if(failure == :undelivered, do: 0, else: 13)
    GenServer.stop(conversation)
    GenServer.stop(coordinator)
    %{saved: saved, thread: thread}
  end

  defp attrs(run),
    do: %{
      run_id: run,
      incarnation: 1,
      authority: %{run_id: run, grants: []},
      mode: :execution,
      usage_authoritative: true
    }

  defp start_coordinator(opts),
    do: start_supervised!({GoalCoordinator, opts}, id: make_ref(), restart: :temporary)
end
