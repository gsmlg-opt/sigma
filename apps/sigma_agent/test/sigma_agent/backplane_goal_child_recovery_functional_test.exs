defmodule Sigma.Agent.BackplaneGoalChildRecoveryFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Error, Goal, GoalBridge, Kernel, Recovery}
  alias Sigma.Agent.{Runtime, Subagents}
  alias Sigma.Agent.Backplane.{ChildIO, GoalDescendants, GoalHost, GoalRuns, GoalStore, Store}
  alias Sigma.Session.{Log, Writer}

  @moduletag :tmp_dir
  @moduletag :goal_child_recovery_functional
  @session "goal-child-recovery"

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    def output_token_limit(_model, _options), do: 2_000

    def stream(params) do
      send(params.options[:test_pid], {:recovery_provider, self(), params})

      receive do
        {:recovery_response, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            content: content,
            stop_reason: reason,
            usage: %{input: 15, cache_read: 5, output: 3, total_tokens: 18},
            model: "goal-recovery",
            provider: "goal-recovery",
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
            if record[:usage] != baseline, do: :injected_child_goal_usage_failure

          :reject_ack ->
            if Enum.any?(get_in(record, [:transition, :events]) || [], fn event ->
                 event.type == "run.goal_outbox_acknowledged"
               end),
               do: :injected_child_terminal_ack_failure

          :allow ->
            nil
        end

      if cause do
        send(owner, {:recovery_write_rejected, cause})
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

    assert {:ok, handle} =
             Runtime.get_session(dir, @session,
               cwd: dir,
               transcript_path: path,
               native_tools: true,
               native_memory_root: Path.join(dir, "memories"),
               provider: Provider,
               model: %{
                 id: "goal-recovery",
                 provider: "goal-recovery",
                 api: "openai-responses",
                 context_window: 200_000
               },
               tools: [],
               hook_specs: [],
               permission_config: %{default: :allow, rules: %{}},
               options: [test_pid: self()]
             )

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
    test "real child receipts survive production cancellation and cold #{failure} recovery", c do
      {child, root, admission, io, original_store, thread} = failed_child!(c)

      assert {:ok, retained} =
               Store.load(original_store, admission.intent.metadata["runtime_run_id"])

      original_receipts = retained.run.context.conversation.goal_outbox
      assert [_ | _] = original_receipts
      assert Enum.all?(original_receipts, &(&1.type == :usage))
      assert Enum.all?(original_receipts, &(&1.incarnation == admission.intent.incarnation))
      assert retained.effects == []
      assert retained.outbox == []

      # Production retirement now performs the exact provider-only recovery
      # before closing the owned repository. Original receipts remain unchanged.
      stop_repository!(c, child, root, io, original_store)
      set_fault(c.goal_fault, :allow)
      assert :ok = GoalStore.retire(c.goal_root)
      refute Process.alive?(c.goal_store)

      store =
        start_supervised!(
          {Store,
           path: Path.join([c.path <> ".subagents", child.params.session_id, "runtime"]),
           filesystem: {FaultableFileSystem, c.ack_fault}},
          id: :recovered_child_store,
          restart: :temporary
        )

      assert {:ok, terminal} = Store.load(store, retained.run.run_id)
      assert terminal.run.state == :cancelled
      assert terminal.run.incarnation == admission.intent.incarnation + 1
      assert terminal.revision == retained.revision + 3
      assert terminal.run.context.conversation.goal_outbox === original_receipts
      assert {:ok, %{hosts: hosts}} = Store.host_retirement(store, :all)
      [host] = Map.values(hosts)
      [binding] = Map.values(host.bindings)
      assert binding.root_header_id == thread
      assert binding.child_session_id == child.params.session_id
      assert binding.run_id == retained.run.run_id
      assert binding.run_incarnation == admission.intent.incarnation
      assert {:ok, %{status: :confirmed}} = Store.host_retirement(store, binding)
      requirements = Kernel.cleanup_requirements(retained.run)
      assert is_map(requirements.provider)

      assert {:ok, %{identity: provider_identity, status: :stopped}} =
               Store.provider_lifecycle(store, requirements.provider)

      assert provider_identity === requirements.provider
      assert requirements.tools == []
      assert requirements.children == []
      assert requirements.dependencies == []

      assert {:ok, classification} =
               Recovery.recover(
                 Map.put(retained.run, :effects, [requirements.provider]),
                 %{incarnation: retained.run.incarnation + 1}
               )

      assert [_] = classification.uncertain_effects
      refute Enum.any?(classification.effects, & &1.safe_to_resume?)

      assert Kernel.cleanup_requirements(terminal.run) ==
               %{provider: nil, tools: [], children: [], dependencies: []}

      writer =
        start_supervised!({Writer, storage_id: c.path, session_id: @session, cwd: c.dir},
          id: :recovered_writer,
          restart: :temporary
        )

      assert {:ok, roots} = GoalRuns.list(c.goal_root, thread)

      goal_store =
        start_supervised!(
          {GoalStore, path: c.goal_root, filesystem: {FaultableFileSystem, c.goal_fault}},
          id: :recovered_goal_store
        )

      assert {:ok, before_record} = GoalStore.load(goal_store, thread)
      before_tokens = before_record.goal.tokens_used
      goal = goal!(goal_store, thread)
      assert {:ok, _} = Goal.restore(goal)

      assert {:ok, [loaded]} =
               GoalDescendants.load(writer, c.path, roots, before_record.goal.goal_id)

      assert loaded.identity.incarnation == admission.intent.incarnation
      assert loaded.snapshot.run.incarnation > loaded.identity.incarnation
      assert loaded.snapshot.run.context.conversation.goal_outbox === original_receipts

      {fault, mode, cause, charged} =
        case unquote(failure) do
          :goal_commit ->
            {c.goal_fault, {:reject_usage, before_record.usage},
             :injected_child_goal_usage_failure, 0}

          :runtime_ack ->
            {c.ack_fault, :reject_ack, :injected_child_terminal_ack_failure, 13}
        end

      set_fault(fault, mode)

      for _ <- 1..2 do
        assert {:error, %Error{class: :execution_failure, cause: ^cause}} = account(goal, loaded)
        assert {:ok, ^terminal} = Store.load(store, terminal.run.run_id)
        assert {:ok, %{goal: %{tokens_used: used}}} = Goal.get(goal)
        assert used == before_tokens + charged
      end

      # Restart actual Goal and Store processes after the failed acknowledgement;
      # only persisted bytes and original Writer identities feed the retry.
      set_fault(fault, :allow)
      assert :ok = GenServer.stop(goal, :normal)
      assert :ok = GoalStore.retire(c.goal_root)
      assert :ok = Store.retire(store)
      assert :ok = GenServer.stop(writer, :normal)
      refute Process.alive?(goal)
      refute Process.alive?(store)
      refute Process.alive?(writer)

      assert {:ok, new_store} = Store.start_link(path: loaded.store_path)
      assert {:ok, new_goal_store} = GoalStore.open(path: c.goal_root)

      assert {:ok, new_writer} =
               Writer.start_link(storage_id: c.path, session_id: @session, cwd: c.dir)

      cold_goal = goal!(new_goal_store, thread)
      assert {:ok, _} = Goal.restore(cold_goal)

      assert {:ok, [cold]} =
               GoalDescendants.load(new_writer, c.path, roots, before_record.goal.goal_id)

      assert cold.snapshot.run.context.conversation.goal_outbox === original_receipts
      assert :ok = account(cold_goal, cold)
      assert {:ok, %{goal: %{tokens_used: used}}} = Goal.get(cold_goal)
      assert used == before_tokens + 13
      assert {:ok, acknowledged} = Store.load(new_store, terminal.run.run_id)
      assert acknowledged.run.incarnation == terminal.run.incarnation
      assert acknowledged.run.state == :cancelled
      assert acknowledged.run.outcome == terminal.run.outcome
      assert acknowledged.run.context.conversation.goal_outbox == []
      assert acknowledged.revision == terminal.revision + 1

      assert {:ok, []} =
               GoalDescendants.load(new_writer, c.path, roots, before_record.goal.goal_id)

      assert {:ok, ^acknowledged} = Store.load(new_store, terminal.run.run_id)
      refute_receive {:recovery_provider, _, _}, 0
      assert :ok = GenServer.stop(cold_goal, :normal)
      assert :ok = GenServer.stop(new_writer, :normal)
      assert :ok = Store.retire(new_store)
    end
  end

  test "descendant loading preserves production child recovery and the unknown root", c do
    {child, root, admission, io, original_store, thread} = failed_child!(c)
    run_id = admission.intent.metadata["runtime_run_id"]
    assert {:ok, retained} = Store.load(original_store, run_id)
    receipts = retained.run.context.conversation.goal_outbox

    # Let the real cancellation persist its aggregate failure before shutting
    # down the repository; termination may otherwise leave a cancelling record.
    assert {:error, {:already_started, live_root_store}} =
             Store.start_link(path: c.path <> ".runtime")

    assert {:cancelling, _} = Sigma.Agent.cancel(c.agent)

    assert eventually(fn ->
             case Store.load(live_root_store, root.params.turn_id) do
               {:ok, %{run: %{state: :unknown_outcome}}} -> true
               _ -> false
             end
           end)

    stop_repository!(c, child, root, io, original_store)
    set_fault(c.goal_fault, :allow)
    assert :ok = GoalStore.retire(c.goal_root)

    child_path = Path.join([c.path <> ".subagents", child.params.session_id])
    journals = [c.path, Path.join(child_path, "session.jsonl")]
    journal_bytes = Map.new(journals, &{&1, File.read!(&1)})

    store =
      start_supervised!(
        {Store,
         path: Path.join(child_path, "runtime"), filesystem: {FaultableFileSystem, c.ack_fault}},
        id: :automatic_child_store
      )

    root_store = start_supervised!({Store, path: c.path <> ".runtime"}, id: :original_root)
    assert {:ok, root_before} = Store.load(root_store, root.params.turn_id)
    assert root_before.run.state == :unknown_outcome

    writer =
      start_supervised!({Writer, storage_id: c.path, session_id: @session, cwd: c.dir},
        id: :automatic_writer
      )

    goal_store =
      start_supervised!(
        {GoalStore, path: c.goal_root, filesystem: {FaultableFileSystem, c.goal_fault}},
        id: :automatic_goal_store
      )

    assert {:ok, record} = GoalStore.load(goal_store, thread)
    assert {:ok, roots} = GoalRuns.list(c.goal_root, thread)

    assert {:ok, [loaded]} =
             GoalDescendants.load(writer, c.path, roots, record.goal.goal_id)

    terminal = loaded.snapshot
    assert terminal.run.state == :cancelled
    assert terminal.run.incarnation == admission.intent.incarnation + 1
    assert terminal.revision == retained.revision + 3
    assert terminal.run.context.conversation.goal_outbox === receipts
    assert loaded.identity.incarnation == admission.intent.incarnation
    assert {:ok, [^loaded]} = GoalDescendants.load(writer, c.path, roots, record.goal.goal_id)
    assert {:ok, ^terminal} = Store.load(store, run_id)

    goal = goal!(goal_store, thread)
    assert {:ok, _} = Goal.restore(goal)
    set_fault(c.goal_fault, {:reject_usage, record.usage})

    assert {:error, %Error{cause: :injected_child_goal_usage_failure}} = account(goal, loaded)
    assert {:ok, %{goal: %{tokens_used: tokens}}} = Goal.get(goal)
    assert tokens == record.goal.tokens_used
    set_fault(c.goal_fault, :allow)
    set_fault(c.ack_fault, :reject_ack)

    for _ <- 1..2 do
      assert {:error, %Error{cause: :injected_child_terminal_ack_failure}} = account(goal, loaded)
      assert {:ok, %{goal: %{tokens_used: tokens}}} = Goal.get(goal)
      assert tokens == record.goal.tokens_used + 13
      assert {:ok, ^terminal} = Store.load(store, run_id)
    end

    set_fault(c.ack_fault, :allow)
    assert :ok = account(goal, loaded)
    assert {:ok, []} = GoalDescendants.load(writer, c.path, roots, record.goal.goal_id)
    assert {:ok, acknowledged} = Store.load(store, run_id)
    assert acknowledged.revision == terminal.revision + 1
    assert acknowledged.run.incarnation == terminal.run.incarnation
    assert acknowledged.run.context.conversation.goal_outbox == []
    assert {:ok, ^root_before} = Store.load(root_store, root.params.turn_id)
    assert Map.new(journals, &{&1, File.read!(&1)}) == journal_bytes
    refute_receive {:recovery_provider, _, _}, 0
  end

  for missing <- ["host-retirement.etf", "provider-lifecycle.etf"] do
    test "descendant recovery retains its original run when #{missing} evidence is missing", c do
      {child, root, admission, io, original_store, thread} = failed_child!(c)
      run_id = admission.intent.metadata["runtime_run_id"]
      assert {:ok, retained} = Store.load(original_store, run_id)
      path = Path.join([c.path <> ".subagents", child.params.session_id, "runtime"])
      [record] = Path.wildcard(Path.join(path, "*.runtime"))

      # Keep the real run record unreadable while closing actual resources.
      # This stops automatic Store reconciliation after native/hooks/Provider
      # retirement. Restore the untouched committed bytes only after all old
      # owners exit, then exercise one missing component at a time.
      File.rename!(record, record <> ".saved")
      File.mkdir!(record)

      try do
        stop_repository!(c, child, root, io, original_store, :before_reconciliation)
      after
        File.rmdir!(record)
        File.rename!(record <> ".saved", record)
      end

      assert {:ok, verified_store} = Store.start_link(path: path)
      assert {:ok, ^retained} = Store.load(verified_store, run_id)
      assert {:ok, %{hosts: hosts}} = Store.host_retirement(verified_store, :all)
      [host] = Map.values(hosts)
      [binding] = Map.values(host.bindings)
      assert {:ok, %{status: :confirmed}} = Store.host_retirement(verified_store, binding)

      assert {:ok, %{status: :stopped}} =
               Store.provider_lifecycle(
                 verified_store,
                 Kernel.cleanup_requirements(retained.run).provider
               )

      assert :ok = Store.retire(verified_store)
      evidence = Path.join(path, unquote(missing))
      assert :ok = File.rename(evidence, evidence <> ".unavailable")

      writer =
        start_supervised!({Writer, storage_id: c.path, session_id: @session, cwd: c.dir},
          id: :missing_evidence_writer
        )

      store = start_supervised!({Store, path: path}, id: :missing_evidence_store)
      assert {:ok, roots} = GoalRuns.list(c.goal_root, thread)
      [receipt | _] = retained.run.context.conversation.goal_outbox

      for _ <- 1..2 do
        assert {:error, %Error{}} =
                 GoalDescendants.load(writer, c.path, roots, receipt.expected_goal_id)

        assert {:ok, ^retained} = Store.load(store, run_id)
      end

      refute_receive {:recovery_provider, _, _}, 0
    end
  end

  defp failed_child!(c) do
    assert {:accepted, _} = Sigma.Agent.prompt(c.agent, "Create a Goal and delegate actual work")
    root = provider!(@session)
    send_call(root, "create_goal", %{"objective" => "Account the actual child exactly once"})
    root = provider!(@session)

    send_call(root, "spawn_agent", %{
      "task_name" => "contributor",
      "message" => "Perform ordinary Provider work",
      "fork_turns" => "none"
    })

    child = provider!(:child)
    root = provider!(@session)
    assert {:ok, %{admissions: admissions}} = Writer.subagent_state(c.writer)

    admission =
      Enum.find_value(admissions, fn {_id, admission} ->
        if admission.intent.child_session_id == child.params.session_id and
             admission.intent.run_id == child.params.turn_id,
           do: admission
      end)

    assert admission
    assert Enum.any?(admission.receipts, & &1.process_started)
    assert {:ok, sources} = Subagents.archive_sources(c.host)

    source =
      Enum.find(sources.children, &(&1.identity.child_session_id == child.params.session_id))

    assert source
    assert {:ok, store} = ChildIO.store(source.io)
    assert {:ok, snapshot} = Log.snapshot(c.path)
    assert {:ok, goal_record} = GoalStore.load(c.goal_store, snapshot.session_id)
    set_fault(c.goal_fault, {:reject_usage, goal_record.usage})
    send(child.pid, {:recovery_response, [%{type: :text, text: "Actual child response"}]})
    assert_receive {:recovery_write_rejected, :injected_child_goal_usage_failure}, 8_000

    assert eventually(fn ->
             case Store.load(store, admission.intent.metadata["runtime_run_id"]) do
               {:ok, saved} ->
                 get_in(saved, [:run, :context, :conversation, :goal_outbox]) not in [nil, []]

               _ ->
                 false
             end
           end)

    assert eventually(fn ->
             case Subagents.snapshot(c.host) do
               {:ok, %{subagents: roster}} ->
                 Enum.any?(
                   roster.agents,
                   &(&1.agent_id == admission.intent.agent_id and
                       (&1.status == :unknown_outcome or &1.closure == :unknown))
                 )

               _ ->
                 false
             end
           end)

    # Do not retry the uncertain child. Stop the owned tree before reconciliation.
    {child, root, admission, source.io, store, snapshot.session_id}
  end

  defp stop_repository!(c, child, root, io, store, mode \\ :confirmed) do
    owners = :sys.get_state(c.host)

    processes =
      [child.pid, root.pid, c.agent, c.writer, c.host, io, store] ++
        Map.values(Map.take(owners, [:manager, :session, :codex_resources, :lifetime_recovery]))

    monitors =
      for pid <- Enum.uniq(processes), is_pid(pid), do: {pid, Process.monitor(pid)}

    case mode do
      :confirmed ->
        assert {:error,
                %Error{
                  class: :resource_conflict,
                  message: "archive has unsettled accepted input or delivery obligations"
                } = error} = Subagents.close(c.host)

        assert {:ok, sources} = Subagents.archive_sources(c.host)
        assert match?({:ok, %{status: :confirmed}}, sources.execution_result)
        assert sources.execution_closed
        refute sources.generation_closed
        assert sources.completion_stage == :pending
        assert sources.archive_result == {:error, error}

        assert eventually(fn ->
                 state = :sys.get_state(c.agent)
                 is_nil(state.current_turn_task) and is_nil(state.goal_idle_task)
               end)

      :before_reconciliation ->
        assert {:error, %Error{class: :unknown_outcome} = error} = Subagents.close(c.host)
        assert inspect(error) =~ "eisdir"
    end

    repository = Runtime.lookup(c.dir, :supervisor)
    assert is_pid(repository)
    assert :ok = DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, repository)

    for {pid, ref} <- monitors do
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 15_000
      refute Process.alive?(pid)
    end

    for pid <- [repository, c.agent, c.writer, io, store], do: refute(Process.alive?(pid))

    if mode == :confirmed do
      ledger =
        (c.path <> ".subagents/lifetime-recovery.etf")
        |> File.read!()
        |> :erlang.binary_to_term([:safe])

      stages =
        for {reference, stage} <- ledger.evidence,
            String.starts_with?(reference, "child-export-stage:"),
            do: stage

      assert stages != []
      assert Enum.all?(stages, &(&1["record_type"] == "child_export_stage"))

      assert Enum.any?(
               stages,
               &(&1["host_metadata"]["child_session_id"] == child.params.session_id)
             )

      assert Enum.all?(stages, &(&1["source_checkpoint"]["goal_outbox"] != []))
    end
  end

  defp goal!(store, thread) do
    start_supervised!(
      {Goal,
       thread_id: thread,
       owner_pid: self(),
       store: GoalStore,
       store_context: store,
       host: GoalHost,
       host_context: %{
         record_instruction: fn _, _ -> flunk("recovery recorded a new instruction") end,
         reserve_turn: fn _, _ -> flunk("recovery admitted new work") end,
         release_turn: fn _, _ -> flunk("recovery released new work") end
       }},
      id: make_ref(),
      restart: :temporary
    )
  end

  defp account(goal, child) do
    attrs =
      child.parent
      |> Map.delete(:goal_id)
      |> Map.put(:authority, %{run_id: child.parent.run_id, grants: []})

    assert {:ok, parent} = Goal.bind(goal, attrs)
    assert {:ok, binding} = Goal.delegate(goal, parent, child.identity)

    result =
      with {:ok, _} <- GoalBridge.redeliver(goal, binding, child.snapshot.run),
           do: GoalDescendants.acknowledge(child)

    assert {:ok, :unbound} = Goal.unbind(goal, binding)
    assert {:ok, :unbound} = Goal.unbind(goal, parent)
    result
  end

  defp set_fault(control, mode), do: Agent.update(control, &%{&1 | mode: mode})

  defp send_call(provider, name, args) do
    send(
      provider.pid,
      {:recovery_response,
       [
         %{
           type: :tool_call,
           id: "recovery-#{System.unique_integer([:positive])}",
           name: name,
           arguments: args,
           input_kind: :function
         }
       ]}
    )
  end

  defp provider!(session) do
    receive do
      {:recovery_provider, pid, %{session_id: "child_" <> _} = params} when session == :child ->
        %{pid: pid, params: params}

      {:recovery_provider, pid, %{session_id: ^session} = params} ->
        %{pid: pid, params: params}
    after
      8_000 -> flunk("actual Provider did not start for #{session}")
    end
  end

  defp eventually(fun, attempts \\ 400)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end
end
