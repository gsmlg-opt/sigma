defmodule Sigma.Agent.BackplaneGoalRootRecoveryFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Error, Kernel}
  alias Backplane.AgentRuntime.Store, as: RuntimeStore
  alias Sigma.Agent.{Runtime, Subagents}
  alias Sigma.Agent.Backplane.{GoalIntegration, GoalRuns, GoalStore, Store}
  alias Sigma.Session.{Log, Writer}

  @moduletag :tmp_dir
  @moduletag :goal_root_recovery_functional
  @session "goal-root-recovery"

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    def output_token_limit(_model, _options), do: 2_000

    def stream(params) do
      send(params.options[:test_pid], {:root_recovery_provider, self(), params})

      receive do
        {:root_recovery_response, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            content: content,
            stop_reason: reason,
            usage: %{input: 15, cache_read: 5, output: 3, total_tokens: 18},
            model: "root-recovery",
            provider: "root-recovery",
            api: "openai-responses",
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, reason, message}]
      end
    end
  end

  defmodule FaultableFileSystem do
    def ensure_dir(_control, path), do: Store.FileSystem.ensure_dir(path)
    def read(_control, path), do: Store.FileSystem.read(path)

    def write_atomic(control, path, bytes) do
      record = :erlang.binary_to_term(bytes, [:safe])
      %{mode: mode, owner: owner} = Agent.get(control, & &1)

      cause =
        case mode do
          {:reject_usage, baseline} ->
            if record[:usage] != baseline, do: :injected_root_goal_usage_failure

          :reject_ack ->
            if Enum.any?(get_in(record, [:transition, :events]) || [], fn event ->
                 event.type == "run.goal_outbox_acknowledged"
               end),
               do: :injected_root_terminal_ack_failure

          {:reject_fence, incarnation} ->
            if is_integer(record[:incarnation]) and record.incarnation > incarnation,
              do: :injected_root_recovery_fence_failure

          {:reject_transition, transition} ->
            if Enum.any?(get_in(record, [:transition, :events]) || [], fn event ->
                 event.type == transition
               end),
               do: :injected_root_recovery_transition_failure

          :allow ->
            nil
        end

      if cause do
        send(owner, {:root_recovery_write_rejected, cause})
        {:error, cause}
      else
        Store.FileSystem.write_atomic(path, bytes)
      end
    end
  end

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "root.jsonl")
    goal_root = Path.join(path <> ".subagents", "goal")
    owner = self()

    goal_fault =
      start_supervised!({Agent, fn -> %{mode: :allow, owner: owner} end}, id: :goal_fault)

    ack_fault =
      start_supervised!({Agent, fn -> %{mode: :allow, owner: owner} end}, id: :ack_fault)

    goal_store =
      start_supervised!(
        {GoalStore, path: goal_root, filesystem: {FaultableFileSystem, goal_fault}}
      )

    opts = [
      cwd: dir,
      transcript_path: path,
      native_tools: true,
      native_memory_root: Path.join(dir, "memories"),
      provider: Provider,
      model: %{
        id: "root-recovery",
        provider: "root-recovery",
        api: "openai-responses",
        context_window: 200_000
      },
      tools: [],
      hook_specs: [],
      permission_config: %{default: :allow, rules: %{}},
      options: [test_pid: self()]
    ]

    assert {:ok, handle} = Runtime.get_session(dir, @session, opts)
    assert :ok = Sigma.Agent.subscribe(handle.agent)

    on_exit(fn ->
      case Runtime.lookup(dir, :supervisor) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
      end

      GoalStore.retire(goal_root)
    end)

    %{
      dir: dir,
      path: path,
      opts: opts,
      goal_root: goal_root,
      goal_store: goal_store,
      goal_fault: goal_fault,
      ack_fault: ack_fault,
      agent: handle.agent,
      writer: Runtime.lookup(dir, @session, :writer),
      host: Runtime.lookup(dir, @session, :subagents)
    }
  end

  for failure <- [:goal_commit, :runtime_ack] do
    test "root Engine resumes after fenced #{failure} recovery without replay or double charge",
         c do
      {thread, identity, retained, receipts, before_tokens} = failed_root!(c)
      set_fault(c.goal_fault, :allow)
      assert :ok = GoalStore.retire(c.goal_root)

      store =
        start_supervised!(
          {Store, path: c.path <> ".runtime", filesystem: {FaultableFileSystem, c.ack_fault}},
          id: :recovered_root_store,
          restart: :temporary
        )

      assert {:ok, ^retained} = Store.load(store, identity.run_id)
      requirements = Kernel.cleanup_requirements(retained.run)
      assert is_map(requirements.provider)

      assert {:ok, %{identity: provider_identity, status: :stopped}} =
               Store.provider_lifecycle(store, requirements.provider)

      assert provider_identity === requirements.provider
      assert requirements.tools == []
      assert requirements.children == []
      assert requirements.dependencies == []

      # failed_root! confirmed the real Session/resources close and the exact
      # Provider task's death. Only that actual Provider work needs settlement;
      # no command or hook was dispatched in this fixture.
      assert {:ok, fenced} =
               RuntimeStore.fence(
                 Store,
                 store,
                 identity.run_id,
                 retained.revision,
                 identity.incarnation,
                 identity.incarnation + 1
               )

      assert fenced.run.context.conversation.goal_outbox === receipts
      assert {:ok, _} = RuntimeStore.store(Store, store, fenced.run, %{command: {:cancel, now()}})
      assert {:ok, cancelling} = Store.load(store, identity.run_id)
      assert Kernel.cleanup_requirements(cancelling.run) == requirements

      assert {:ok, _} =
               RuntimeStore.store(Store, store, cancelling.run, %{
                 command:
                   {:cleanup_settled, now(), %{certainty: :confirmed, settled: requirements}}
               })

      assert {:ok, terminal} = Store.load(store, identity.run_id)
      assert terminal.run.state == :cancelled
      assert terminal.run.incarnation == identity.incarnation + 1
      assert terminal.run.context.conversation.goal_outbox === receipts

      goal_store =
        start_supervised!(
          {GoalStore, path: c.goal_root, filesystem: {FaultableFileSystem, c.goal_fault}},
          id: :recovered_goal_store,
          restart: :temporary
        )

      writer =
        start_supervised!({Writer, storage_id: c.path, session_id: @session, cwd: c.dir},
          id: :recovered_writer,
          restart: :temporary
        )

      assert {:ok, before_record} = GoalStore.load(goal_store, thread)

      {fault, mode, cause, charged} =
        case unquote(failure) do
          :goal_commit ->
            {c.goal_fault, {:reject_usage, before_record.usage},
             :injected_root_goal_usage_failure, 0}

          :runtime_ack ->
            {c.ack_fault, :reject_ack, :injected_root_terminal_ack_failure, 13}
        end

      set_fault(fault, mode)

      for _ <- 1..2 do
        assert {:error, %Error{class: :execution_failure, cause: ^cause}} =
                 GoalIntegration.open(
                   writer: writer,
                   transcript_path: c.path,
                   cwd: c.dir,
                   root: c.goal_root,
                   runtime_store: store,
                   host_context: %{}
                 )

        assert {:ok, ^terminal} = Store.load(store, identity.run_id)
        assert {:ok, %{goal: %{tokens_used: used}}} = GoalStore.load(goal_store, thread)
        assert used == before_tokens + charged
      end

      set_fault(fault, :allow)
      assert :ok = Store.retire(store)
      assert :ok = GoalStore.retire(c.goal_root)
      assert :ok = GenServer.stop(writer, :normal)

      # Production Agent initialization opens fresh Store/Writer/Goal owners;
      # a blocked Goal must not start a Provider merely by being restored.
      assert {:ok, restored} = Runtime.get_session(c.dir, @session, c.opts)

      assert {:ok, %{goal: %{status: :blocked, tokens_used: used}}} =
               Sigma.Agent.goal(restored.agent)

      assert used == before_tokens + 13

      assert {:error, {:already_started, actual_store}} =
               Store.start_link(path: c.path <> ".runtime")

      assert {:ok, acknowledged} = Store.load(actual_store, identity.run_id)
      assert acknowledged.run.state == terminal.run.state
      assert acknowledged.run.outcome == terminal.run.outcome
      assert acknowledged.run.incarnation == terminal.run.incarnation
      assert acknowledged.run.context.conversation.goal_outbox == []
      assert acknowledged.revision == terminal.revision + 1
      assert {:ok, [^identity]} = GoalRuns.list(c.goal_root, thread)
      refute_receive {:root_recovery_provider, _, _}, 100

      assert :ok = Sigma.Agent.subscribe(restored.agent)
      assert {:accepted, _} = Sigma.Agent.prompt(restored.agent, "Perform a fresh ordinary turn")
      fresh = provider!()
      refute fresh.params.turn_id == identity.run_id
      send(fresh.pid, {:root_recovery_response, [%{type: :text, text: "Fresh work completed"}]})
      assert_receive {:agent_end, _}, 8_000
      assert {:ok, ^acknowledged} = Store.load(actual_store, identity.run_id)
      refute_receive {:root_recovery_provider, _, _}, 100
    end
  end

  for failure <- [:goal_commit, :runtime_ack] do
    test "production reopening reconciles a stopped provider-only root after #{failure}", c do
      {thread, identity, retained, receipts, before_tokens} = failed_root!(c)
      set_fault(c.goal_fault, :allow)
      assert :ok = GoalStore.retire(c.goal_root)

      %{store: store, goal_store: goal_store, writer: writer} = recovery_owners!(c)

      journal = File.read!(c.path)
      assert {:ok, ^retained} = Store.load(store, identity.run_id)
      assert {:ok, before_record} = GoalStore.load(goal_store, thread)

      {fault, mode, cause} =
        case unquote(failure) do
          :goal_commit ->
            {c.goal_fault, {:reject_usage, before_record.usage},
             :injected_root_goal_usage_failure}

          :runtime_ack ->
            {c.ack_fault, :reject_ack, :injected_root_terminal_ack_failure}
        end

      set_fault(fault, mode)

      for _ <- 1..2 do
        assert {:error, %Error{class: :execution_failure, cause: ^cause}} =
                 GoalIntegration.open(
                   writer: writer,
                   transcript_path: c.path,
                   cwd: c.dir,
                   root: c.goal_root,
                   runtime_store: store,
                   host_context: %{}
                 )

        assert {:ok, terminal} = Store.load(store, identity.run_id)
        assert terminal.run.state == :cancelled
        assert terminal.run.incarnation == identity.incarnation + 1
        assert terminal.run.context.conversation.goal_outbox === receipts
        assert terminal.revision == retained.revision + 3
        assert File.read!(c.path) === journal
        refute_receive {:root_recovery_provider, _, _}, 20
      end

      set_fault(fault, :allow)
      assert :ok = Store.retire(store)
      assert :ok = GoalStore.retire(c.goal_root)
      assert :ok = GenServer.stop(writer, :normal)

      assert {:ok, restored} = Runtime.get_session(c.dir, @session, c.opts)

      assert {:ok, %{goal: %{status: :blocked, tokens_used: used}}} =
               Sigma.Agent.goal(restored.agent)

      assert used == before_tokens + 13

      assert {:error, {:already_started, actual_store}} =
               Store.start_link(path: c.path <> ".runtime")

      assert {:ok, acknowledged} = Store.load(actual_store, identity.run_id)
      assert acknowledged.run.state == :cancelled
      assert acknowledged.run.incarnation == identity.incarnation + 1
      assert acknowledged.run.context.conversation.goal_outbox == []
      assert acknowledged.revision == retained.revision + 4
      assert {:ok, [^identity]} = GoalRuns.list(c.goal_root, thread)
      assert File.read!(c.path) === journal
      refute_receive {:root_recovery_provider, _, _}, 100

      assert :ok = Sigma.Agent.subscribe(restored.agent)
      assert {:accepted, _} = Sigma.Agent.prompt(restored.agent, "Perform replacement work")
      fresh = provider!()
      refute fresh.params.turn_id == identity.run_id
      send(fresh.pid, {:root_recovery_response, [%{type: :text, text: "Replacement completed"}]})
      assert_receive {:agent_end, _}, 8_000
      assert {:ok, ^acknowledged} = Store.load(actual_store, identity.run_id)
      refute_receive {:root_recovery_provider, _, _}, 100
    end
  end

  for {failure, state, revisions} <-
        [{:fence, :running, 0}, {:cancel, :running, 1}, {:cleanup, :cancelling, 2}] do
    test "automatic root recovery retains a failed #{failure} write and resumes that stage", c do
      {thread, identity, retained, _receipts, before_tokens} = failed_root!(c)
      set_fault(c.goal_fault, :allow)
      assert :ok = GoalStore.retire(c.goal_root)
      %{store: store, goal_store: goal_store, writer: writer} = recovery_owners!(c)
      assert {:ok, before_record} = GoalStore.load(goal_store, thread)
      journal = File.read!(c.path)

      {mode, cause} =
        case unquote(failure) do
          :fence ->
            {{:reject_fence, identity.incarnation}, :injected_root_recovery_fence_failure}

          :cancel ->
            {{:reject_transition, "run.cancelling"}, :injected_root_recovery_transition_failure}

          :cleanup ->
            {{:reject_transition, "run.cancelled"}, :injected_root_recovery_transition_failure}
        end

      set_fault(c.ack_fault, mode)

      snapshots =
        for _ <- 1..2 do
          assert {:error, %Error{class: :execution_failure, cause: ^cause}} =
                   GoalIntegration.open(
                     writer: writer,
                     transcript_path: c.path,
                     cwd: c.dir,
                     root: c.goal_root,
                     runtime_store: store,
                     host_context: %{}
                   )

          assert {:ok, saved} = Store.load(store, identity.run_id)
          assert saved.run.state == unquote(state)
          assert saved.revision == retained.revision + unquote(revisions)
          assert saved.run.incarnation == identity.incarnation + min(unquote(revisions), 1)
          assert saved.run.active_provider === retained.run.active_provider

          assert saved.run.context.conversation.goal_outbox ===
                   retained.run.context.conversation.goal_outbox

          assert {:ok, ^before_record} = GoalStore.load(goal_store, thread)
          assert File.read!(c.path) === journal
          refute_receive {:root_recovery_provider, _, _}, 20
          saved
        end

      assert Enum.at(snapshots, 0) === Enum.at(snapshots, 1)
      set_fault(c.ack_fault, :allow)
      assert :ok = Store.retire(store)
      assert :ok = GoalStore.retire(c.goal_root)
      assert :ok = GenServer.stop(writer, :normal)
      assert {:ok, restored} = Runtime.get_session(c.dir, @session, c.opts)
      assert {:ok, %{goal: %{tokens_used: used}}} = Sigma.Agent.goal(restored.agent)
      assert used == before_tokens + 13

      assert {:error, {:already_started, actual_store}} =
               Store.start_link(path: c.path <> ".runtime")

      assert {:ok, reconciled} = Store.load(actual_store, identity.run_id)
      assert reconciled.run.state == :cancelled
      assert reconciled.run.incarnation == identity.incarnation + 1
      assert reconciled.revision == retained.revision + 4
      assert reconciled.run.context.conversation.goal_outbox == []
      assert File.read!(c.path) === journal
      refute_receive {:root_recovery_provider, _, _}, 100
    end
  end

  test "missing root retirement or Provider facts leave the actual failed run unchanged", c do
    {thread, identity, retained, _receipts, _before_tokens} = failed_root!(c)
    set_fault(c.goal_fault, :allow)
    assert :ok = GoalStore.retire(c.goal_root)
    %{store: store, goal_store: goal_store, writer: writer} = recovery_owners!(c)
    assert {:ok, before_record} = GoalStore.load(goal_store, thread)
    journal = File.read!(c.path)
    host_path = Path.join(c.path <> ".runtime", "host-retirement.etf")
    provider_path = Path.join(c.path <> ".runtime", "provider-lifecycle.etf")
    host_bytes = File.read!(host_path)
    provider_bytes = File.read!(provider_path)
    host_ledger = :erlang.binary_to_term(host_bytes, [:safe])
    provider_ledger = :erlang.binary_to_term(provider_bytes, [:safe])

    for component <- [:native, :async_hooks, :session_end, :current_provider, :earlier_provider] do
      {path, incomplete, original, error_class} =
        case component do
          kind when kind in [:current_provider, :earlier_provider] ->
            provider =
              if kind == :current_provider,
                do: retained.run.active_provider,
                else:
                  Enum.find(
                    Map.values(retained.run.provider_attempts),
                    &(&1 != retained.run.active_provider)
                  )

            assert provider
            ledger = %{provider_ledger | attempts: Map.delete(provider_ledger.attempts, provider)}
            {provider_path, ledger, provider_bytes, :not_found}

          kind ->
            hosts =
              Map.new(host_ledger.hosts, fn {id, host} ->
                updated =
                  if kind == :native, do: %{host | native: %{}}, else: Map.put(host, kind, nil)

                {id, updated}
              end)

            {host_path, %{host_ledger | hosts: hosts}, host_bytes, :resource_conflict}
        end

      incomplete_bytes = :erlang.term_to_binary(incomplete, compressed: 6)
      assert :ok = File.write(path, incomplete_bytes)

      assert {:error, %Error{class: ^error_class}} =
               GoalIntegration.open(
                 writer: writer,
                 transcript_path: c.path,
                 cwd: c.dir,
                 root: c.goal_root,
                 runtime_store: store,
                 host_context: %{}
               )

      assert {:ok, ^retained} = Store.load(store, identity.run_id)
      assert {:ok, ^before_record} = GoalStore.load(goal_store, thread)
      assert File.read!(path) === incomplete_bytes
      assert File.read!(c.path) === journal
      refute_receive {:root_recovery_provider, _, _}, 20
      assert :ok = File.write(path, original)
    end

    assert :ok = Store.retire(store)
    assert :ok = GoalStore.retire(c.goal_root)
    assert :ok = GenServer.stop(writer, :normal)
    assert {:ok, _restored} = Runtime.get_session(c.dir, @session, c.opts)
    assert File.read!(c.path) === journal
    refute_receive {:root_recovery_provider, _, _}, 100
  end

  test "an ordinary storage failure reconciles its exact Provider outbox without a Goal", c do
    repository = Runtime.lookup(c.dir, :supervisor)
    assert :ok = DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, repository)
    assert :ok = GoalStore.retire(c.goal_root)

    store =
      start_supervised!(
        {Store, path: c.path <> ".runtime", filesystem: {FaultableFileSystem, c.ack_fault}},
        id: :provider_outbox_store,
        restart: :temporary
      )

    assert {:ok, handle} =
             Runtime.get_session(c.dir, @session, Keyword.put(c.opts, :backplane_store, store))

    assert :ok = Sigma.Agent.subscribe(handle.agent)

    assert {:accepted, _} =
             Sigma.Agent.prompt(handle.agent, "Perform ordinary work without a Goal")

    root = provider!()
    monitor = Process.monitor(root.pid)
    assert {:ok, journal_snapshot} = Log.snapshot(c.path)
    assert {:ok, [identity]} = GoalRuns.list(c.goal_root, journal_snapshot.session_id)
    assert is_nil(identity.goal_id)
    assert {:ok, active} = Store.load(store, identity.run_id)
    assert [intent] = active.outbox
    assert intent.type == :provider
    assert intent.operation.attempt_id == active.run.active_provider.attempt_id

    set_fault(c.ack_fault, {:reject_transition, "run.conversation_updated"})
    send(root.pid, {:root_recovery_response, [%{type: :text, text: "Uncommitted response"}]})

    assert_receive {:root_recovery_write_rejected, :injected_root_recovery_transition_failure},
                   8_000

    assert_receive {:DOWN, ^monitor, :process, _, _}, 8_000
    assert_receive {:agent_end, _}, 8_000
    assert {:ok, retained} = Store.load(store, identity.run_id)
    assert retained.outbox === [intent]
    assert retained.run.active_provider === active.run.active_provider
    assert get_in(retained, [:run, :context, :conversation, :goal_outbox]) in [nil, []]

    set_fault(c.ack_fault, :allow)
    assert {:ok, %{status: :confirmed, capture: :durable}} = Sigma.Agent.retire_host(handle.agent)
    repository = Runtime.lookup(c.dir, :supervisor)
    assert :ok = DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, repository)
    assert :ok = Store.retire(store)
    assert :ok = GoalStore.retire(c.goal_root)
    journal = File.read!(c.path)

    assert {:ok, restored} = Runtime.get_session(c.dir, @session, c.opts)
    assert {:ok, %{goal: nil}} = Sigma.Agent.goal(restored.agent)

    assert {:error, {:already_started, actual_store}} =
             Store.start_link(path: c.path <> ".runtime")

    assert {:ok, reconciled} = Store.load(actual_store, identity.run_id)
    assert reconciled.run.state == :cancelled
    assert reconciled.run.incarnation == identity.incarnation + 1
    assert reconciled.run.context === retained.run.context
    assert reconciled.outbox == []
    assert reconciled.revision == retained.revision + 3
    assert File.read!(c.path) === journal
    refute_receive {:root_recovery_provider, _, _}, 100

    assert :ok = Sigma.Agent.subscribe(restored.agent)
    assert {:accepted, _} = Sigma.Agent.prompt(restored.agent, "Start a new ordinary run")
    fresh = provider!()
    refute fresh.params.turn_id == identity.run_id
    send(fresh.pid, {:root_recovery_response, [%{type: :text, text: "New work completed"}]})
    assert_receive {:agent_end, _}, 8_000
    assert {:ok, ^reconciled} = Store.load(actual_store, identity.run_id)
  end

  defp recovery_owners!(c) do
    store =
      start_supervised!(
        {Store, path: c.path <> ".runtime", filesystem: {FaultableFileSystem, c.ack_fault}},
        id: :automatic_root_store,
        restart: :temporary
      )

    goal_store =
      start_supervised!(
        {GoalStore, path: c.goal_root, filesystem: {FaultableFileSystem, c.goal_fault}},
        id: :automatic_goal_store,
        restart: :temporary
      )

    writer =
      start_supervised!({Writer, storage_id: c.path, session_id: @session, cwd: c.dir},
        id: :automatic_writer,
        restart: :temporary
      )

    %{store: store, goal_store: goal_store, writer: writer}
  end

  defp failed_root!(c) do
    assert {:accepted, _} =
             Sigma.Agent.prompt(
               c.agent,
               "Create a Goal, block automatic continuation and do actual root work"
             )

    root = provider!()

    send(root.pid, {
      :root_recovery_response,
      [
        %{
          type: :tool_call,
          id: "create-root-goal",
          name: "create_goal",
          arguments: %{"objective" => "Account the actual root response exactly once"},
          input_kind: :function
        }
      ]
    })

    root = provider!()

    send(root.pid, {
      :root_recovery_response,
      [
        %{
          type: :tool_call,
          id: "block-root-goal",
          name: "update_goal",
          arguments: %{"status" => "blocked"},
          input_kind: :function
        }
      ]
    })

    root = provider!()
    assert {:ok, %{goal: %{status: :blocked}}} = Sigma.Agent.goal(c.agent)

    assert {:ok, snapshot} = Log.snapshot(c.path)
    assert {:ok, [identity]} = GoalRuns.list(c.goal_root, snapshot.session_id)
    assert {:ok, goal_record} = GoalStore.load(c.goal_store, snapshot.session_id)
    assert {:error, {:already_started, store}} = Store.start_link(path: c.path <> ".runtime")
    producer = Process.monitor(root.pid)
    set_fault(c.goal_fault, {:reject_usage, goal_record.usage})
    send(root.pid, {:root_recovery_response, [%{type: :text, text: "Actual root response"}]})
    assert_receive {:root_recovery_write_rejected, :injected_root_goal_usage_failure}, 8_000
    assert_receive {:DOWN, ^producer, :process, _, _}, 8_000
    assert_receive {:agent_end, _}, 8_000
    assert {:ok, %{status: :confirmed}} = Subagents.close(c.host)
    assert {:ok, retained} = Store.load(store, identity.run_id)
    receipts = retained.run.context.conversation.goal_outbox
    assert [_ | _] = receipts
    assert Enum.all?(receipts, &(&1.type == :usage and &1.incarnation == identity.incarnation))
    assert retained.effects == []
    assert retained.outbox == []

    repository = Runtime.lookup(c.dir, :supervisor)
    assert :ok = DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, repository)

    for pid <- [root.pid, repository, c.agent, c.writer, c.host, store],
        do: refute(Process.alive?(pid))

    {snapshot.session_id, identity, retained, receipts, goal_record.goal.tokens_used}
  end

  defp provider! do
    receive do
      {:root_recovery_provider, pid, %{session_id: @session} = params} ->
        %{pid: pid, params: params}
    after
      8_000 -> flunk("actual root recovery Provider did not start")
    end
  end

  defp set_fault(control, mode), do: Agent.update(control, &%{&1 | mode: mode})
  defp now, do: System.system_time(:millisecond)
end
