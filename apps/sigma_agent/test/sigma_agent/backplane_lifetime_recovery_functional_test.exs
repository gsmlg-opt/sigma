defmodule Sigma.Agent.BackplaneLifetimeRecoveryFunctionalTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.{Runtime, Subagents}
  alias Sigma.Agent.Backplane.{ChildIO, GoalCoordinator, GoalStore, LifetimeRecovery, Store}
  alias Sigma.Session.{Log, Writer}

  @moduletag :tmp_dir
  @moduletag :lifetime_recovery_functional
  @session "lifetime-recovery"

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

      if match?({:block_lifetime_after_ack, _}, mode) and
           Enum.any?(
             get_in(record, [:transition, :events]) || [],
             &(&1.type == "run.goal_outbox_acknowledged")
           ) do
        {:block_lifetime_after_ack, evidence} = mode

        with :ok <- Store.FileSystem.write_atomic(path, bytes),
             :ok <- File.rename(evidence, evidence <> ".before-refresh"),
             :ok <- File.mkdir(evidence) do
          Agent.update(control, &%{&1 | mode: :allow})
          send(owner, {:lifetime_goal_ack_committed, record.run.run_id})
          :ok
        end
      else
        cause =
          case mode do
            {:reject_usage, baseline} ->
              if record[:usage] != baseline, do: :injected_child_goal_usage_failure

            {:hold_usage_failure, baseline, gate} ->
              if record[:usage] != baseline do
                send(owner, {:lifetime_goal_usage_blocked, self(), gate})

                receive do
                  {:release_goal_usage_failure, ^gate} -> :injected_child_goal_usage_failure
                after
                  8_000 -> :injected_child_goal_gate_timeout
                end
              end

            :reject_ack ->
              if Enum.any?(get_in(record, [:transition, :events]) || [], fn event ->
                   event.type == "run.goal_outbox_acknowledged"
                 end),
                 do: :injected_child_terminal_ack_failure

            :allow ->
              nil

            {:block_lifetime_after_ack, _} ->
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
  end

  setup %{tmp_dir: dir} = context do
    basename = if context[:file_stage], do: @session <> ".jsonl", else: "root.jsonl"
    path = Path.join(dir, basename)
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

    end_marker = Path.join(dir, "session-end.log")
    end_gate = Path.join(dir, "session-end.release")

    hooks =
      if context[:retirement_hook] do
        script = Path.join(dir, "session-end.sh")

        File.write!(script, """
        printf 'once\\n' >> '#{end_marker}'
        while ! test -f '#{end_gate}'; do sleep 0.01; done
        """)

        [
          %Sigma.Coding.Hooks.Spec{
            event: :session_end,
            matcher: :any,
            handler: %Sigma.Coding.Hooks.Spec.Command{
              cmd: "sh '#{script}'",
              timeout_ms: 5_000
            },
            origin: {:user, dir},
            trusted?: true,
            dialect: :codex
          }
        ]
      else
        []
      end

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
               hook_specs: hooks,
               permission_config: %{default: :allow, rules: %{}},
               options: [test_pid: self()]
             )

    on_exit(fn ->
      File.touch(end_gate)

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
      host: Runtime.lookup(dir, @session, :subagents),
      end_marker: end_marker,
      end_gate: end_gate
    }
  end

  test "ordinary turns retain the evidence owner and a real successful child followup", c do
    assert {:accepted, _} = Sigma.Agent.prompt(c.agent, "Delegate a response")
    root = provider!(@session)

    send_call(root, "spawn_agent", %{
      "task_name" => "contributor",
      "message" => "Respond",
      "fork_turns" => "none"
    })

    child = provider!(:child)
    root = provider!(@session)
    writer = LifetimeRecovery.locate(c.path)
    assert is_pid(writer) and Process.alive?(writer)
    respond!(child, "first child")
    assert eventually(fn -> stopped_children(c.host) == 1 end)
    respond!(root, "first root")
    assert eventually(fn -> Sigma.Agent.status(c.agent).phase == :completed end)

    assert {:accepted, _} = Sigma.Agent.prompt(c.agent, "Follow up")
    root = provider!(@session)
    assert LifetimeRecovery.locate(c.path) == writer

    send_call(root, "followup_task", %{
      "target" => "/root/contributor",
      "message" => "Respond again"
    })

    followup = provider!(:child)
    root = provider!(@session)
    assert followup.params.session_id == child.params.session_id
    refute followup.params.turn_id == child.params.turn_id
    respond!(followup, "second child")
    assert eventually(fn -> stopped_children(c.host) == 1 end)
    respond!(root, "second root")
    assert eventually(fn -> Sigma.Agent.status(c.agent).phase == :completed end)
    assert {:ok, %{status: :confirmed}} = Sigma.Agent.retire_host(c.agent)
    refute Process.alive?(writer)
    assert LifetimeRecovery.locate(c.path) == nil
    evidence = ledger!(c.path)
    assert map_size(evidence.executors) == 4
    assert Enum.all?(evidence.executors, fn {_identity, fact} -> fact.status == :stopped end)

    assert Enum.all?(evidence.receipts, fn {_id, receipt} ->
             receipt["retirement"] == "confirmed"
           end)
  end

  @tag :detached_cancellation
  test "public Stop confirms detached execution before completing retained child archives", c do
    {child, root} = detached_child!(c)
    child_ref = Process.monitor(child.pid)
    assert {:ok, %{subagents: %{counts: %{executing: 1}}}} = Subagents.snapshot(c.host)
    assert {:ok, original} = root_snapshot(c.path, root.params.turn_id)

    owners =
      Map.take(:sys.get_state(c.host), [:manager, :session, :codex_resources, :lifetime_recovery])

    assert Enum.all?(owners, fn {_name, pid} -> is_pid(pid) and Process.alive?(pid) end)
    assert {:ok, command} = Sigma.Protocol.Envelope.command("turn.cancel", @session)
    context = %{repo_path: c.dir, sessions_dir: c.dir}
    assert {:ok, cancelled} = Sigma.Agent.PublicRuntime.execute(command, context)

    assert cancelled.payload["cancellation"] == %{
             "status" => "cancelled_children",
             "turnId" => nil
           }

    assert_receive {:DOWN, ^child_ref, :process, _, _}, 8_000

    assert {:ok, %{subagents: %{counts: %{executing: 0, unknown: 0}}}} =
             Subagents.snapshot(c.host)

    assert {:ok, sources} = Subagents.archive_sources(c.host)
    assert sources.execution_closed
    refute sources.generation_closed
    assert sources.archive_result == :pending
    assert sources.completion_stage == :pending
    assert Enum.all?(owners, fn {_name, pid} -> Process.alive?(pid) end)
    assert Backplane.AgentRuntime.Codex.Session.status(owners.session).phase == :closed
    assert :sys.get_state(c.agent).host_retirement_facts == %{}
    assert Sigma.Agent.status(c.agent).phase == :completed
    assert {:ok, ^original} = root_snapshot(c.path, root.params.turn_id)
    refute_receive {:recovery_provider, _, _}, 0

    before_retry = runtime_bytes(c.path)

    assert {:error, %{type: "session.error"}} =
             Sigma.Agent.PublicRuntime.execute(command, context)

    assert runtime_bytes(c.path) == before_retry
    assert {:ok, ^sources} = Subagents.archive_sources(c.host)

    assert {:ok, %{status: :confirmed, capture: :durable}} = Sigma.Agent.retire_host(c.agent)

    assert {:ok, %{generation_closed: true, completion_stage: :completed}} =
             Subagents.archive_sources(c.host)

    refute Process.alive?(owners.lifetime_recovery)
    refute Process.alive?(owners.session)
    assert {:ok, ^original} = root_snapshot(c.path, root.params.turn_id)
    refute_receive {:recovery_provider, _, _}, 0
  end

  @tag :detached_cancellation
  test "public Stop retains an actual child retirement write failure before confirming execution",
       c do
    {child, root} = detached_child!(c)
    child_ref = Process.monitor(child.pid)
    assert {:ok, original} = root_snapshot(c.path, root.params.turn_id)

    receipt =
      Path.join([
        c.path <> ".subagents",
        child.params.session_id,
        "runtime",
        "host-retirement.etf"
      ])

    File.rename!(receipt, receipt <> ".saved")
    File.mkdir!(receipt)

    try do
      assert {:ok, command} = Sigma.Protocol.Envelope.command("turn.cancel", @session)

      assert {:error, %{type: "session.error"} = failed} =
               Sigma.Agent.PublicRuntime.execute(command, %{repo_path: c.dir, sessions_dir: c.dir})

      assert failed.error.code == "runtime_error"
      assert_receive {:DOWN, ^child_ref, :process, _, _}, 8_000
      assert {:ok, sources} = Subagents.archive_sources(c.host)
      refute sources.execution_closed
      refute sources.generation_closed
      assert {:error, %Backplane.AgentRuntime.Error{} = actual} = sources.execution_result
      assert inspect(actual) =~ "eisdir"
      assert :sys.get_state(c.agent).host_retirement_facts == %{}
      assert {:ok, ^original} = root_snapshot(c.path, root.params.turn_id)
    after
      File.rmdir!(receipt)
      File.rename!(receipt <> ".saved", receipt)
    end

    assert {:ok, %{status: :confirmed}} = Subagents.close_execution(c.host)
    assert {:ok, %{status: :confirmed, capture: :durable}} = Sigma.Agent.retire_host(c.agent)
    assert {:ok, %{generation_closed: true}} = Subagents.archive_sources(c.host)
    assert {:ok, ^original} = root_snapshot(c.path, root.params.turn_id)
    refute_receive {:recovery_provider, _, _}, 0
  end

  test "prospective failed child closure permits a new root without replay or changed attribution",
       c do
    {original, admission, _thread, goal_before} = retired_failure!(c)

    assert {:ok, child_terminal} =
             child_snapshot(
               c.path,
               admission.intent.child_session_id,
               admission.intent.metadata["runtime_run_id"]
             )

    child_receipts = child_terminal.run.context.conversation.goal_outbox
    assert [_ | _] = child_receipts
    assert Enum.all?(child_receipts, &(&1.incarnation == admission.intent.incarnation))
    evidence_before = ledger!(c.path)

    assert Enum.all?(evidence_before.receipts, fn {_id, receipt} ->
             receipt["retirement"] == "confirmed"
           end)

    stop_repository!(c)
    assert :ok = GoalStore.retire(c.goal_root)

    assert {:ok, resumed} = Runtime.get_session(c.dir, @session, session_options(c))
    assert {:ok, after_goal} = Sigma.Agent.goal(resumed.agent)
    assert after_goal.goal.tokens_used == goal_before.goal.tokens_used + 13
    assert {:ok, %{coordinator: coordinator}} = GenServer.call(resumed.agent, :goal_handle)
    assert {:ok, %{status: :ready, recovered_runs: 0}} = GoalCoordinator.recover(coordinator)
    assert {:ok, ^after_goal} = Sigma.Agent.goal(resumed.agent)
    assert {:ok, ^original} = root_snapshot(c.path, original.run.run_id)

    assert {:ok, acknowledged} =
             child_snapshot(c.path, admission.intent.child_session_id, child_terminal.run.run_id)

    assert acknowledged.run.context.conversation.goal_outbox == []
    assert acknowledged.run.incarnation == child_terminal.run.incarnation
    assert acknowledged.run.state == child_terminal.run.state

    assert {:ok, %{admissions: admissions}} =
             Writer.subagent_state(Runtime.lookup(c.dir, @session, :writer))

    assert admissions[admission.intent.attempt_id].intent == admission.intent
    assert {:ok, %{goal: goal_record}} = Sigma.Agent.goal(resumed.agent)
    assert goal_record.tokens_used == after_goal.goal.tokens_used
    refute_receive {:recovery_provider, _, _}, 0

    evidence_after = ledger!(c.path)

    assert Enum.any?(evidence_after.receipts, fn {id, receipt} ->
             receipt["revision"] > evidence_before.receipts[id]["revision"]
           end)

    assert {:accepted, _} = Sigma.Agent.prompt(resumed.agent, "New ordinary root work")
    next = provider!(@session)
    refute next.params.turn_id == original.run.run_id

    send_call(next, "followup_task", %{
      "target" => "/root/contributor",
      "message" => "Continue the archived child after cold recovery"
    })

    followup = provider!(:child)
    next = provider!(@session)
    assert followup.params.session_id == admission.intent.child_session_id
    refute followup.params.turn_id == admission.intent.run_id
    respond!(followup, "new child followup response")
    host = Runtime.lookup(c.dir, @session, :subagents)
    assert eventually(fn -> stopped_children(host) == 1 end)
    respond!(next, "new root response")
    assert eventually(fn -> Sigma.Agent.status(resumed.agent).phase == :completed end)
    assert {:ok, ^original} = root_snapshot(c.path, original.run.run_id)
    refute_receive {:recovery_provider, _, %{session_id: "child_" <> _}}, 0
  end

  test "nested failed children reseal Goal receipts before their ancestor", c do
    assert {:accepted, _} = Sigma.Agent.prompt(c.agent, "Delegate nested work")
    root = provider!(@session)
    send_call(root, "create_goal", %{"objective" => "Account nested work once"})
    root = provider!(@session)

    send_call(root, "spawn_agent", %{
      "task_name" => "contributor",
      "message" => "Delegate a response",
      "fork_turns" => "none"
    })

    parent = provider!(:child)
    root = provider!(@session)

    send_call(parent, "spawn_agent", %{
      "task_name" => "descendant",
      "message" => "Respond",
      "fork_turns" => "none"
    })

    assert eventually(fn ->
             {:ok, %{subagents: roster}} = Subagents.snapshot(c.host)
             Enum.any?(roster.agents, &(&1.agent_path == "/root/contributor/descendant"))
           end)

    {:ok, %{subagents: roster}} = Subagents.snapshot(c.host)
    descendant_row = Enum.find(roster.agents, &(&1.agent_path == "/root/contributor/descendant"))
    descendant = provider!(descendant_row.child_session_id)
    parent = provider!(parent.params.session_id)
    assert {:ok, snapshot} = Log.snapshot(c.path)
    assert {:ok, before_goal} = GoalStore.load(c.goal_store, snapshot.session_id)
    assert {:ok, %{admissions: admissions}} = Writer.subagent_state(c.writer)
    child_sessions = [parent.params.session_id, descendant.params.session_id]

    admissions =
      Enum.filter(Map.values(admissions), &(&1.intent.child_session_id in child_sessions))

    assert length(admissions) == 2
    set_fault(c.goal_fault, {:reject_usage, before_goal.usage})

    for provider <- [descendant, parent] do
      respond!(provider, "Actual nested response")
      assert_receive {:recovery_write_rejected, :injected_child_goal_usage_failure}, 8_000
    end

    for admission <- admissions do
      assert eventually(fn ->
               case child_snapshot(
                      c.path,
                      admission.intent.child_session_id,
                      admission.intent.metadata["runtime_run_id"]
                    ) do
                 {:ok, saved} ->
                   get_in(saved, [:run, :context, :conversation, :goal_outbox]) not in [nil, []]

                 _ ->
                   false
               end
             end)
    end

    set_fault(c.goal_fault, :allow)
    assert {:cancelling, _} = Sigma.Agent.cancel(c.agent)

    assert eventually(fn ->
             case root_snapshot(c.path, root.params.turn_id) do
               {:ok, %{run: %{state: :unknown_outcome}}} -> true
               _ -> false
             end
           end)

    assert eventually(fn -> is_nil(:sys.get_state(c.agent).current_turn_task) end)
    assert eventually(fn -> is_nil(:sys.get_state(c.agent).goal_idle_task) end)

    parent_admission =
      Enum.find(admissions, &(&1.intent.child_session_id == parent.params.session_id))

    assert {:ok, parent_saved} =
             child_snapshot(
               c.path,
               parent_admission.intent.child_session_id,
               parent_admission.intent.metadata["runtime_run_id"]
             )

    assert parent_saved.run.last_provider_result.terminal.stop_reason == :tool_use
    assert parent_saved.run.last_provider_result.message.stop_reason == :tool_use
    assert_pending_archive!(c, before_goal)
    assert {:ok, original} = root_snapshot(c.path, root.params.turn_id)
    stop_repository!(c)
    assert :ok = GoalStore.retire(c.goal_root)
    assert {:ok, resumed} = Runtime.get_session(c.dir, @session, session_options(c))
    assert {:ok, goal} = Sigma.Agent.goal(resumed.agent)
    assert goal.goal.tokens_used == before_goal.goal.tokens_used + 26
    assert {:ok, ^original} = root_snapshot(c.path, original.run.run_id)

    for admission <- admissions do
      assert {:ok, recovered} =
               child_snapshot(
                 c.path,
                 admission.intent.child_session_id,
                 admission.intent.metadata["runtime_run_id"]
               )

      assert recovered.run.context.conversation.goal_outbox == []
      assert recovered.run.incarnation == admission.intent.incarnation + 1
    end

    bytes = runtime_bytes(c.path)
    assert {:ok, %{coordinator: coordinator}} = GenServer.call(resumed.agent, :goal_handle)
    assert {:ok, %{status: :ready, recovered_runs: 0}} = GoalCoordinator.recover(coordinator)
    assert runtime_bytes(c.path) == bytes
    assert {:ok, ^goal} = Sigma.Agent.goal(resumed.agent)
    refute_receive {:recovery_provider, _, _}, 0
  end

  test "missing prospective lifetime evidence rejects reopening without changing the old run",
       c do
    {original, _admission, _thread, _goal} = retired_failure!(c)
    stop_repository!(c)
    assert :ok = GoalStore.retire(c.goal_root)
    evidence = Path.join(c.path <> ".subagents", "lifetime-recovery.etf")
    File.rename!(evidence, evidence <> ".unavailable")
    before = runtime_bytes(c.path)

    for _ <- 1..2 do
      assert {:error, _} = Runtime.get_session(c.dir, @session, session_options(c))
      assert runtime_bytes(c.path) == before
      assert {:ok, ^original} = root_snapshot(c.path, original.run.run_id)
      refute_receive {:recovery_provider, _, _}, 0
    end
  end

  test "a fresh BEAM recovers a failed child once and admits only new root work", c do
    {original, admission, _thread, goal_before} = retired_failure!(c)
    stop_repository!(c)
    assert :ok = GoalStore.retire(c.goal_root)

    root_path =
      Enum.find_value(runtime_bytes(c.path), fn {path, bytes} ->
        if :erlang.binary_to_term(bytes, [:safe]).run.run_id == original.run.run_id, do: path
      end)

    root_before = runtime_bytes(c.path)[root_path]
    assert is_binary(root_before)

    executable = System.find_executable("elixir")
    assert executable
    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])
    probe = Path.expand("../support/lifetime_recovery_probe.exs", __DIR__)

    args =
      ["--erl", "+S 2:2"] ++
        paths ++
        [
          probe,
          c.dir,
          c.path,
          Integer.to_string(goal_before.goal.tokens_used + 13),
          original.run.run_id
        ]

    {output, status} = System.cmd(executable, args, stderr_to_stdout: true)
    assert status == 0, output
    assert output =~ "cold lifetime recovery confirmed"
    assert {:ok, ^original} = root_snapshot(c.path, original.run.run_id)
    assert runtime_bytes(c.path)[root_path] == root_before

    assert {:ok, recovered} =
             child_snapshot(
               c.path,
               admission.intent.child_session_id,
               admission.intent.metadata["runtime_run_id"]
             )

    assert recovered.run.context.conversation.goal_outbox == []

    [request] =
      c.dir |> Path.join("cold-provider.jsonl") |> File.read!() |> String.split("\n", trim: true)

    assert %{"session_id" => @session, "turn_id" => turn_id} = Jason.decode!(request)
    refute turn_id == original.run.run_id
  end

  test "a child Goal ACK followed by a receipt write failure can restart without replay", c do
    {original, admission, _thread, goal_before} = retired_failure!(c)
    stop_repository!(c)
    assert :ok = GoalStore.retire(c.goal_root)
    child_path = Path.join([c.path <> ".subagents", admission.intent.child_session_id, "runtime"])

    store =
      start_supervised!({Store, path: child_path, filesystem: {FaultableFileSystem, c.ack_fault}},
        id: :ack_failure_reader,
        restart: :temporary
      )

    evidence = Path.join(c.path <> ".subagents", "lifetime-recovery.etf")
    set_fault(c.ack_fault, {:block_lifetime_after_ack, evidence})
    assert {:error, _} = Runtime.get_session(c.dir, @session, session_options(c))
    run_id = admission.intent.metadata["runtime_run_id"]
    assert_receive {:lifetime_goal_ack_committed, ^run_id}, 8_000
    assert {:ok, acknowledged} = Store.load(store, run_id)
    assert acknowledged.run.context.conversation.goal_outbox == []
    assert File.dir?(evidence)
    File.rmdir!(evidence)
    File.rename!(evidence <> ".before-refresh", evidence)
    before = runtime_bytes(c.path)
    assert {:ok, resumed} = Runtime.get_session(c.dir, @session, session_options(c))
    assert {:ok, goal} = Sigma.Agent.goal(resumed.agent)
    assert goal.goal.tokens_used == goal_before.goal.tokens_used + 13
    assert runtime_bytes(c.path) == before
    assert {:ok, ^acknowledged} = Store.load(store, run_id)
    assert {:ok, ^original} = root_snapshot(c.path, original.run.run_id)
    assert {:ok, %{coordinator: coordinator}} = GenServer.call(resumed.agent, :goal_handle)
    assert {:ok, %{status: :ready, recovered_runs: 0}} = GoalCoordinator.recover(coordinator)
    assert {:ok, ^goal} = Sigma.Agent.goal(resumed.agent)
    refute_receive {:recovery_provider, _, _}, 0
    assert {:accepted, _} = Sigma.Agent.prompt(resumed.agent, "New work after receipt repair")
    respond!(provider!(@session), "new work")
    assert eventually(fn -> Sigma.Agent.status(resumed.agent).phase == :completed end)
  end

  for kind <- ["child", "manager", "session"] do
    test "a durable receipt without its actual #{kind} public ACK does not admit a new root", c do
      {original, _admission, _thread, _goal} = retired_failure!(c)
      stop_repository!(c)
      assert :ok = GoalStore.retire(c.goal_root)
      evidence_path = Path.join(c.path <> ".subagents", "lifetime-recovery.etf")
      ledger = ledger!(c.path)
      prefix = unquote(kind) <> "-ack:"
      removed = Enum.count(ledger.evidence, fn {ref, _} -> String.starts_with?(ref, prefix) end)
      assert removed > 0
      evidence = Map.reject(ledger.evidence, fn {ref, _} -> String.starts_with?(ref, prefix) end)
      File.write!(evidence_path, :erlang.term_to_binary(%{ledger | evidence: evidence}))
      before = runtime_bytes(c.path)
      assert {:error, _} = Runtime.get_session(c.dir, @session, session_options(c))
      assert runtime_bytes(c.path) == before
      assert {:ok, ^original} = root_snapshot(c.path, original.run.run_id)
      refute_receive {:recovery_provider, _, _}, 0
    end
  end

  test "a failed root admission write prevents the next Provider request", c do
    assert {:accepted, _} = Sigma.Agent.prompt(c.agent, "First turn")
    respond!(provider!(@session), "first")
    assert eventually(fn -> Sigma.Agent.status(c.agent).phase == :completed end)
    assert :ok = Sigma.Agent.subscribe(c.agent)
    evidence = Path.join(c.path <> ".subagents", "lifetime-recovery.etf")
    File.rename!(evidence, evidence <> ".saved")
    File.mkdir!(evidence)

    try do
      assert {:accepted, _} = Sigma.Agent.prompt(c.agent, "Must fail before Provider")
      assert_receive {:turn_error, error}, 8_000
      assert inspect(error) =~ "eisdir"
      assert_receive {:agent_end, _}, 8_000
      refute_receive {:recovery_provider, _, _}, 0
    after
      File.rmdir!(evidence)
      File.rename!(evidence <> ".saved", evidence)
    end
  end

  test "ordinary shutdown retires a failed child root before cold production reopening", c do
    {_child, root, _admission, _io, _store, thread} = failed_child!(c)
    assert {:ok, before_goal} = GoalStore.load(c.goal_store, thread)
    set_fault(c.goal_fault, :allow)
    assert {:cancelling, _} = Sigma.Agent.cancel(c.agent)

    assert eventually(fn -> Sigma.Agent.status(c.agent).phase in [:failed, :cancelled] end)
    assert eventually(fn -> is_nil(:sys.get_state(c.agent).goal_idle_task) end)
    assert {:ok, original} = root_snapshot(c.path, root.params.turn_id)
    assert original.run.state == :unknown_outcome
    # Engine closes native resources. The Agent must still be able to write its
    # independent root hooks/SessionEnd facts during normal subtree shutdown.
    assert :ok = Subagents.can_stop(c.host)
    root_store = :sys.get_state(c.agent).backplane_store
    assert {:ok, %{hosts: hosts}} = Store.host_retirement(root_store, :all)
    assert Enum.any?(hosts, fn {_id, host} -> is_nil(host.session_end) end)
    assert {:ok, runs} = Sigma.Agent.Backplane.GoalRuns.list(c.goal_root, thread)
    identity = Enum.find(runs, &(&1.run_id == root.params.turn_id))
    assert identity

    assert {:error, %Backplane.AgentRuntime.Error{}} =
             Sigma.Agent.Backplane.LifetimeEvidence.allow_root(
               root_store,
               identity,
               original,
               c.path
             )

    stop_repository!(c)
    assert :ok = GoalStore.retire(c.goal_root)
    assert {:ok, saved} = Log.snapshot(c.path)

    resume_options =
      session_options(c)
      |> Keyword.put(:messages, saved.messages)
      |> Keyword.put(:context_messages, saved.context_messages)
      |> Keyword.put(:context_window, saved.context_window)
      |> Keyword.put(:active_leaf, saved.active_leaf_id)
      |> Keyword.put(:context_revision, length(saved.branch_entry_ids))
      |> Keyword.put(:context_source, :journal_replay)

    assert {:ok, resumed} = Runtime.get_session(c.dir, @session, resume_options)
    assert {:ok, %{goal: goal}} = Sigma.Agent.goal(resumed.agent)
    assert goal.tokens_used == before_goal.goal.tokens_used + 13
    assert {:ok, ^original} = root_snapshot(c.path, root.params.turn_id)
    refute_receive {:recovery_provider, _, _}, 0

    assert {:accepted, _} = Sigma.Agent.prompt(resumed.agent, "New root after ordinary shutdown")
    next = provider!(@session)
    assert next.params.turn_id != original.run.run_id
    assert inspect(next.params.context.messages) =~ "Create a Goal and delegate actual work"
    respond!(next, "ordinary shutdown recovered")
    assert eventually(fn -> Sigma.Agent.status(resumed.agent).phase == :completed end)
    assert {:ok, ^original} = root_snapshot(c.path, root.params.turn_id)
  end

  test "the next real prompt retires a failed live host before fresh root admission", c do
    {_child, root, admission, _io, _store, thread} = failed_child!(c)
    assert {:ok, before_goal} = GoalStore.load(c.goal_store, thread)
    set_fault(c.goal_fault, :allow)
    assert {:cancelling, _} = Sigma.Agent.cancel(c.agent)
    assert eventually(fn -> Sigma.Agent.status(c.agent).phase in [:failed, :cancelled] end)
    assert eventually(fn -> is_nil(:sys.get_state(c.agent).goal_idle_task) end)
    assert {:ok, original} = root_snapshot(c.path, root.params.turn_id)
    assert original.run.state == :unknown_outcome
    old_host = :sys.get_state(c.agent).host_retirement.identity.host_lifetime_id
    assert :ok = Sigma.Agent.subscribe(c.agent)

    assert {:accepted, info} =
             Sigma.Agent.prompt(c.agent, "Continue live after the actual child failure",
               attachments: [%{name: "retained.txt", mime_type: "text/plain"}]
             )

    next = provider!(@session)
    assert next.params.turn_id == info.turn_id
    refute next.params.turn_id == root.params.turn_id
    assert inspect(next.params.context.messages) =~ "Create a Goal and delegate actual work"
    assert inspect(next.params.context.messages) =~ "Continue live after the actual child failure"
    current_host = :sys.get_state(c.agent).host_retirement.identity.host_lifetime_id
    refute current_host == old_host
    assert {:ok, %{goal: goal}} = Sigma.Agent.goal(c.agent)
    assert goal.tokens_used == before_goal.goal.tokens_used + 13
    assert {:ok, ^original} = root_snapshot(c.path, root.params.turn_id)

    assert {:ok, child} =
             child_snapshot(
               c.path,
               admission.intent.child_session_id,
               admission.intent.metadata["runtime_run_id"]
             )

    assert child.run.context.conversation.goal_outbox == []
    assert {:ok, saved} = Log.snapshot(c.path)
    user = Enum.find(saved.messages, &(&1.id == info.message_id))
    assert user.content == "Continue live after the actual child failure"
    assert user.attachments == [%{"name" => "retained.txt", "mime_type" => "text/plain"}]
    respond!(next, "live recovery completed")

    assert eventually(fn -> Sigma.Agent.status(c.agent).phase == :completed end),
           inspect({Sigma.Agent.status(c.agent), received_errors()})

    assert {:ok, ^original} = root_snapshot(c.path, root.params.turn_id)
    refute_receive {:recovery_provider, _, _}, 0
  end

  @tag :archive_stages_functional
  test "confirmed execution retirement survives archive and Goal failures until live completion",
       c do
    {_child, root, admission, _io, _store, thread} = failed_child!(c)
    assert {:ok, before_goal} = GoalStore.load(c.goal_store, thread)
    assert {:cancelling, _} = Sigma.Agent.cancel(c.agent)
    assert eventually(fn -> Sigma.Agent.status(c.agent).phase in [:failed, :cancelled] end)
    assert eventually(fn -> is_nil(:sys.get_state(c.agent).goal_idle_task) end)

    assert {:ok, %{status: :confirmed}} = apply(Subagents, :close_execution, [c.host])

    owners =
      Map.take(:sys.get_state(c.host), [:manager, :session, :codex_resources, :lifetime_recovery])

    assert Enum.all?(owners, fn {_name, pid} -> is_pid(pid) and Process.alive?(pid) end)

    assert {:ok, retained} =
             child_snapshot(
               c.path,
               admission.intent.child_session_id,
               admission.intent.metadata["runtime_run_id"]
             )

    refute retained.run.context.conversation.goal_outbox == []
    assert {:error, %Backplane.AgentRuntime.Error{} = archive_error} = Subagents.close(c.host)
    assert {:ok, %{status: :confirmed}} = apply(Subagents, :close_execution, [c.host])
    assert {:ok, sources} = Subagents.archive_sources(c.host)
    assert sources.execution_closed
    refute sources.generation_closed
    assert sources.archive_result == {:error, archive_error}
    assert Enum.all?(owners, fn {_name, pid} -> Process.alive?(pid) end)
    assert :ok = Sigma.Agent.subscribe(c.agent)

    assert {:accepted, rejected} =
             Sigma.Agent.prompt(c.agent, "Wait for the original Goal writer")

    assert_receive {:turn_error, %Backplane.AgentRuntime.Error{} = actual}, 8_000
    assert actual.cause == :injected_child_goal_usage_failure
    assert_receive {:turn_failed, turn_id}, 8_000
    assert turn_id == rejected.turn_id
    refute_receive {:recovery_provider, _, _}, 0
    assert {:ok, %{goal: failed_goal}} = GoalStore.load(c.goal_store, thread)
    assert failed_goal.tokens_used == before_goal.goal.tokens_used
    assert Enum.all?(owners, fn {_name, pid} -> Process.alive?(pid) end)
    assert {:ok, %{status: :confirmed}} = apply(Subagents, :close_execution, [c.host])

    set_fault(c.goal_fault, :allow)
    assert {:accepted, info} = Sigma.Agent.prompt(c.agent, "Finish the retained live archive")
    next = provider!(@session)
    assert next.params.turn_id == info.turn_id
    refute next.params.turn_id in [root.params.turn_id, rejected.turn_id]
    refute inspect(next.params.context.messages) =~ "Wait for the original Goal writer"
    assert {:ok, %{goal: goal}} = Sigma.Agent.goal(c.agent)
    assert goal.tokens_used == before_goal.goal.tokens_used + 13

    assert {:ok, child} =
             child_snapshot(
               c.path,
               admission.intent.child_session_id,
               admission.intent.metadata["runtime_run_id"]
             )

    assert child.run.context.conversation.goal_outbox == []
    assert Enum.all?(owners, fn {_name, pid} -> not Process.alive?(pid) end)
    assert {:ok, saved} = Log.snapshot(c.path)
    refute Enum.any?(saved.messages, &(&1.id == rejected.message_id))
    respond!(next, "Live archive completion confirmed")

    assert eventually(fn -> Sigma.Agent.status(c.agent).phase == :completed end),
           inspect({Sigma.Agent.status(c.agent), received_errors()})

    refute_receive {:recovery_provider, _, _}, 0
  end

  @tag :archive_stage_boundaries
  test "execution close remains available while the full archive stage is waiting", c do
    {_child, root, admission, _io, _store, thread} = failed_child!(c)
    assert {:ok, before_goal} = GoalStore.load(c.goal_store, thread)
    cancel_failed_root!(c)
    assert {:ok, %{status: :confirmed}} = Subagents.close_execution(c.host)
    recovery = LifetimeRecovery.locate(c.path)
    assert is_pid(recovery)
    assert :ok = :sys.suspend(recovery)

    full = Task.async(fn -> Subagents.close(c.host) end)

    staging =
      try do
        assert eventually(fn ->
                 Enum.any?(:sys.get_state(c.host).jobs, fn {_ref, {_from, kind}} ->
                   kind == :close
                 end)
               end)

        staging = Task.async(fn -> Subagents.stage_shutdown(c.host) end)
        execution = Task.async(fn -> Subagents.close_execution(c.host) end)
        assert {:ok, {:ok, %{status: :confirmed}}} = Task.yield(execution, 1_000)
        assert {:ok, %{status: :confirmed}} = Subagents.close_execution(c.host)
        assert Task.yield(full, 0) == nil
        assert Task.yield(staging, 0) == nil

        assert eventually(fn -> :sys.get_state(c.host).shutdown_stage_waiters != [] end)
        staging
      after
        :sys.resume(recovery)
      end

    assert {:error, %Backplane.AgentRuntime.Error{} = original} = Task.await(full, 8_000)
    assert :ok = Task.await(staging, 8_000)
    assert {:ok, %{status: :confirmed}} = Subagents.close_execution(c.host)
    assert {:ok, sources} = Subagents.archive_sources(c.host)
    assert sources.execution_closed
    refute sources.generation_closed
    assert sources.archive_result == {:error, original}
    refute_receive {:recovery_provider, _, _}, 0

    assert {:ok, root_before} = root_snapshot(c.path, root.params.turn_id)
    stop_repository!(c)
    assert :ok = GoalStore.retire(c.goal_root)
    assert {:ok, resumed} = Runtime.get_session(c.dir, @session, session_options(c))
    assert {:ok, %{goal: goal}} = Sigma.Agent.goal(resumed.agent)
    assert goal.tokens_used == before_goal.goal.tokens_used + 13
    assert {:ok, ^root_before} = root_snapshot(c.path, root.params.turn_id)

    assert {:ok, acknowledged} =
             child_snapshot(
               c.path,
               admission.intent.child_session_id,
               admission.intent.metadata["runtime_run_id"]
             )

    assert acknowledged.run.context.conversation.goal_outbox == []
    refute_receive {:recovery_provider, _, _}, 0
  end

  @tag :archive_stage_boundaries
  test "shutdown stages a completed archive failure before its Agent callback consumes the result",
       c do
    {original, admission, _thread, before_goal} = retired_failure!(c)
    gate = make_ref()
    owner = self()
    set_fault(c.goal_fault, {:hold_usage_failure, before_goal.usage, gate})

    {caller, caller_ref} =
      spawn_monitor(fn ->
        result =
          try do
            Sigma.Agent.retire_host(c.agent)
          catch
            :exit, reason -> {:exit, reason}
          end

        send(owner, {:retirement_caller_stopped, result})
      end)

    assert_receive {:lifetime_goal_usage_blocked, writer, ^gate}, 8_000
    state = :sys.get_state(c.agent)
    assert state.host_retirement_stage == :completion

    assert %{result: {:ok, %{status: :confirmed, capture: :durable}}} =
             state.host_retirement_facts

    task = state.host_retirement_task
    task_ref = Process.monitor(task.pid)
    assert :ok = :sys.suspend(c.agent)

    try do
      set_fault(c.goal_fault, {:reject_usage, before_goal.usage})
      send(writer, {:release_goal_usage_failure, gate})
      assert_receive {:DOWN, ^task_ref, :process, _, :normal}, 8_000

      assert eventually(fn ->
               {:messages, messages} = Process.info(c.agent, :messages)

               Enum.any?(messages, fn
                 {ref,
                  {:host_completion,
                   {:error,
                    %Backplane.AgentRuntime.Error{cause: :injected_child_goal_usage_failure}}}} ->
                   ref == task.ref

                 _ ->
                   false
               end)
             end)

      stop_repository!(c)
      assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}, 8_000
    after
      send(writer, {:release_goal_usage_failure, gate})

      if Process.alive?(c.agent), do: :sys.resume(c.agent)
      if Process.alive?(caller), do: Process.exit(caller, :kill)
    end

    assert :ok = GoalStore.retire(c.goal_root)
    assert {:ok, resumed} = Runtime.get_session(c.dir, @session, session_options(c))
    assert {:ok, %{goal: goal}} = Sigma.Agent.goal(resumed.agent)
    assert goal.tokens_used == before_goal.goal.tokens_used + 13
    assert {:ok, ^original} = root_snapshot(c.path, original.run.run_id)

    assert {:ok, acknowledged} =
             child_snapshot(
               c.path,
               admission.intent.child_session_id,
               admission.intent.metadata["runtime_run_id"]
             )

    assert acknowledged.run.context.conversation.goal_outbox == []
    refute_receive {:recovery_provider, _, _}, 0

    assert {:accepted, _} =
             Sigma.Agent.prompt(resumed.agent, "New work after completed-task shutdown")

    next = provider!(@session)
    refute next.params.turn_id == original.run.run_id
    respond!(next, "completed-task shutdown recovered")
    assert eventually(fn -> Sigma.Agent.status(resumed.agent).phase == :completed end)
  end

  @tag :archive_stage_boundaries
  test "explicit retirement preserves failed Goal completion and retries the live archive once",
       c do
    {_child, root, admission, _io, _store, thread} = failed_child!(c)
    cancel_failed_root!(c)
    assert {:ok, before_goal} = GoalStore.load(c.goal_store, thread)
    assert {:ok, original} = root_snapshot(c.path, root.params.turn_id)
    recovery = LifetimeRecovery.locate(c.path)

    assert {:error, %Backplane.AgentRuntime.Error{} = actual} = Sigma.Agent.retire_host(c.agent)
    assert actual.cause == :injected_child_goal_usage_failure
    state = :sys.get_state(c.agent)
    assert {:ok, %{status: :confirmed}} = state.host_retirement_facts.result
    assert state.host_retirement_facts.completion == {:error, actual}
    assert Process.alive?(recovery)

    assert {:ok, %{execution_closed: true, generation_closed: false}} =
             Subagents.archive_sources(c.host)

    set_fault(c.goal_fault, :allow)
    assert {:ok, %{status: :confirmed, capture: :durable}} = Sigma.Agent.retire_host(c.agent)

    assert {:ok, %{generation_closed: true, completion_stage: :completed}} =
             Subagents.archive_sources(c.host)

    refute Process.alive?(recovery)
    assert {:ok, %{goal: goal}} = Sigma.Agent.goal(c.agent)
    assert goal.tokens_used == before_goal.goal.tokens_used + 13

    assert {:ok, child} =
             child_snapshot(
               c.path,
               admission.intent.child_session_id,
               admission.intent.metadata["runtime_run_id"]
             )

    assert child.run.context.conversation.goal_outbox == []
    assert {:ok, ^original} = root_snapshot(c.path, root.params.turn_id)
    bytes = File.read!(Path.join(c.path <> ".subagents", "lifetime-recovery.etf"))
    assert {:ok, %{status: :confirmed, capture: :durable}} = Sigma.Agent.retire_host(c.agent)
    assert {:ok, %{goal: ^goal}} = Sigma.Agent.goal(c.agent)
    assert File.read!(Path.join(c.path <> ".subagents", "lifetime-recovery.etf")) == bytes
    refute_receive {:recovery_provider, _, _}, 0
  end

  @tag :archive_stage_boundaries
  test "ending a session operation cannot adopt a host before retained archives complete", c do
    failed_child!(c)
    cancel_failed_root!(c)
    assert {:error, %Backplane.AgentRuntime.Error{} = actual} = Sigma.Agent.retire_host(c.agent)
    original = :sys.get_state(c.agent)
    assert {:error, ^actual} = Sigma.Agent.end_session_operation(c.agent)
    retained = :sys.get_state(c.agent)
    assert retained.host_retirement == original.host_retirement
    assert retained.host_retirement_facts.result == original.host_retirement_facts.result
    assert retained.hook_async_runtime == original.hook_async_runtime
    assert retained.turn_state.phase == :session_operation

    assert {:rejected, :session_busy} =
             Sigma.Agent.prompt(c.agent, "Cannot bypass the pending archive")

    refute_receive {:recovery_provider, _, _}, 0

    set_fault(c.goal_fault, :allow)
    assert :ok = Sigma.Agent.end_session_operation(c.agent)
    ready = :sys.get_state(c.agent)
    assert ready.turn_state.phase == :idle
    refute ready.host_retirement.identity == original.host_retirement.identity
    assert ready.host_retirement_facts == %{}
    assert {:ok, %{generation_closed: true}} = Subagents.archive_sources(c.host)
    refute_receive {:recovery_provider, _, _}, 0
  end

  @tag :archive_stage_boundaries
  @tag :file_stage
  test "Runtime rename completes live child Goal ACK and archives before moving any owner", c do
    {_child, root, admission, _io, _store, thread} = failed_child!(c)
    cancel_failed_root!(c)
    assert {:ok, before_goal} = GoalStore.load(c.goal_store, thread)
    assert {:ok, original} = root_snapshot(c.path, root.params.turn_id)
    set_fault(c.goal_fault, :allow)
    target = Path.join(c.dir, "renamed.jsonl")

    assert {:ok, %{session_id: "renamed"}} =
             Runtime.rename_session(c.dir, @session, "renamed", c.dir)

    refute Process.alive?(c.agent)
    refute File.exists?(c.path)
    refute File.exists?(c.path <> ".runtime")
    refute File.exists?(c.path <> ".subagents")
    assert {:ok, ^original} = root_snapshot(target, root.params.turn_id)

    assert {:ok, child} =
             child_snapshot(
               target,
               admission.intent.child_session_id,
               admission.intent.metadata["runtime_run_id"]
             )

    assert child.run.context.conversation.goal_outbox == []

    assert Enum.any?(ledger!(target).evidence, fn {reference, archive} ->
             String.starts_with?(reference, "child-archive:") and
               get_in(archive, ["host_metadata", "sigma_identity", "agent_id"]) ==
                 admission.intent.agent_id
           end)

    goal_store =
      start_supervised!({GoalStore, path: Path.join(target <> ".subagents", "goal")},
        id: :moved_stage_goal
      )

    assert {:ok, %{goal: goal}} = GoalStore.load(goal_store, thread)
    assert goal.tokens_used == before_goal.goal.tokens_used + 13
    refute_receive {:recovery_provider, _, _}, 0
    refute File.exists?(c.path <> ".runtime")
  end

  @tag retirement_hook: true
  test "cancelling a retained prompt joins host recovery without starting its Provider", c do
    {_child, root, _admission, _io, _store, _thread} = failed_child!(c)
    set_fault(c.goal_fault, :allow)
    assert {:cancelling, _} = Sigma.Agent.cancel(c.agent)
    assert eventually(fn -> Sigma.Agent.status(c.agent).phase in [:failed, :cancelled] end)
    assert eventually(fn -> is_nil(:sys.get_state(c.agent).goal_idle_task) end)
    assert {:ok, original} = root_snapshot(c.path, root.params.turn_id)
    owner = self()
    resource = %{root: Path.join(c.dir, "prepared"), release: fn -> send(owner, :released) end}

    assert {:accepted, info} =
             Sigma.Agent.prompt(c.agent, "Cancel before this prompt has effects",
               prepared_resources: [resource]
             )

    try do
      assert eventually(fn -> File.exists?(c.end_marker) end)
      assert %{phase: :session_operation, turn_id: turn} = Sigma.Agent.status(c.agent)
      assert turn == info.turn_id
      assert {:error, :session_busy} = Sigma.Agent.end_session_operation(c.agent)
      assert {:error, :session_busy} = Sigma.Agent.retire_goal(c.agent)
      assert {:rejected, :session_busy} = Sigma.Agent.prompt(c.agent, "Cannot race recovery")
      assert {:cancelling, turn} = Sigma.Agent.cancel(c.agent)
      assert turn == info.turn_id
      assert :ok = Sigma.Agent.cancel_prompt(c.agent, info.turn_id)
    after
      File.touch!(c.end_gate)
    end

    assert eventually(fn -> Sigma.Agent.status(c.agent).phase == :cancelled end)
    assert_receive :released, 1_000
    refute_receive :released, 0
    assert File.read!(c.end_marker) == "once\n"
    refute_receive {:recovery_provider, _, _}, 0
    assert {:ok, saved} = Log.snapshot(c.path)
    refute Enum.any?(saved.messages, &(&1.id == info.message_id))
    assert {:ok, ^original} = root_snapshot(c.path, root.params.turn_id)
    replacement = :sys.get_state(c.agent).host_retirement.identity.host_lifetime_id
    assert {:accepted, _} = Sigma.Agent.prompt(c.agent, "Use the already prepared replacement")
    next = provider!(@session)
    assert :sys.get_state(c.agent).host_retirement.identity.host_lifetime_id == replacement
    assert File.read!(c.end_marker) == "once\n"
    respond!(next, "replacement completed")
    assert eventually(fn -> Sigma.Agent.status(c.agent).phase == :completed end)
  end

  @tag retirement_hook: true
  test "a retirement write failure retains its effects and releases the unsubmitted prompt", c do
    {_child, root, _admission, _io, _store, _thread} = failed_child!(c)
    set_fault(c.goal_fault, :allow)
    assert {:cancelling, _} = Sigma.Agent.cancel(c.agent)
    assert eventually(fn -> Sigma.Agent.status(c.agent).phase in [:failed, :cancelled] end)
    assert eventually(fn -> is_nil(:sys.get_state(c.agent).goal_idle_task) end)
    assert {:ok, original} = root_snapshot(c.path, root.params.turn_id)
    assert :ok = Sigma.Agent.subscribe(c.agent)
    receipt = Path.join(c.path <> ".runtime", "host-retirement.etf")
    owner = self()
    resource = %{root: Path.join(c.dir, "prepared"), release: fn -> send(owner, :released) end}

    try do
      assert {:accepted, info} =
               Sigma.Agent.prompt(c.agent, "Must remain unsubmitted after retirement failure",
                 prepared_resources: [resource]
               )

      assert eventually(fn -> File.exists?(c.end_marker) end)
      File.rename!(receipt, receipt <> ".saved")
      File.mkdir!(receipt)
      File.touch!(c.end_gate)
      assert_receive {:turn_error, error}, 8_000
      assert inspect(error) =~ "eisdir"
      assert_receive {:turn_failed, turn}, 8_000
      assert turn == info.turn_id
      assert_receive :released, 1_000
      refute_receive :released, 0
      assert File.read!(c.end_marker) == "once\n"
      refute_receive {:recovery_provider, _, _}, 0
      assert {:ok, saved} = Log.snapshot(c.path)
      refute Enum.any?(saved.messages, &(&1.id == info.message_id))
      assert {:ok, ^original} = root_snapshot(c.path, root.params.turn_id)
    after
      File.touch!(c.end_gate)
      File.rmdir!(receipt)
      File.rename!(receipt <> ".saved", receipt)
    end

    assert {:accepted, _} =
             Sigma.Agent.prompt(c.agent, "A real new prompt retries only persistence")

    next = provider!(@session)
    assert File.read!(c.end_marker) == "once\n"
    respond!(next, "receipt retry completed")
    assert eventually(fn -> Sigma.Agent.status(c.agent).phase == :completed end)
    assert {:ok, ^original} = root_snapshot(c.path, root.params.turn_id)
  end

  @tag retirement_hook: true
  test "accepted followups advance after cancelling the one retained during recovery", c do
    {_child, root, _admission, _io, _store, _thread} = failed_child!(c)
    set_fault(c.goal_fault, :allow)
    assert {:queued_as_follow_up, first} = Sigma.Agent.follow_up(c.agent, "Cancel queued item")
    assert {:queued_as_follow_up, second} = Sigma.Agent.follow_up(c.agent, "Keep queued item")
    assert {:cancelling, _} = Sigma.Agent.cancel(c.agent)

    try do
      assert eventually(fn -> File.exists?(c.end_marker) end)
      assert Sigma.Agent.status(c.agent).turn_id == first.turn_id
      assert :ok = Sigma.Agent.cancel_prompt(c.agent, first.turn_id)
    after
      File.touch!(c.end_gate)
    end

    next = provider!(@session)
    assert next.params.turn_id == second.turn_id
    refute inspect(next.params.context.messages) =~ "Cancel queued item"
    assert inspect(next.params.context.messages) =~ "Keep queued item"
    assert File.read!(c.end_marker) == "once\n"
    respond!(next, "queued recovery completed")
    assert eventually(fn -> Sigma.Agent.status(c.agent).phase == :completed end)
    assert {:ok, original} = root_snapshot(c.path, root.params.turn_id)
    assert original.run.state == :unknown_outcome
    assert Sigma.Agent.status(c.agent).follow_up_queue_count == 0
  end

  test "failed retry inspection restores the original Agent context before another prompt", c do
    assert {:accepted, _} = Sigma.Agent.prompt(c.agent, "Committed context before retry")
    respond!(provider!(@session), "committed response")
    assert eventually(fn -> Sigma.Agent.status(c.agent).phase == :completed end)
    original = Sigma.Agent.messages(c.agent)
    assert :ok = Sigma.Agent.begin_session_operation(c.agent)
    receipt = Path.join(c.path <> ".runtime", "host-retirement.etf")
    File.rename!(receipt, receipt <> ".saved")
    File.mkdir!(receipt)
    ref = make_ref()

    try do
      assert {:accepted, _} =
               Sigma.Agent.retry(c.agent, [], "Rejected retry content", "original-turn",
                 retry_admission_notify: {self(), ref}
               )

      assert_receive {:retry_admission, ^ref, {:error, error}}, 8_000
      assert inspect(error) =~ "eisdir"
      assert eventually(fn -> Sigma.Agent.status(c.agent).phase == :failed end)
      assert Sigma.Agent.messages(c.agent) == original
      refute_receive {:recovery_provider, _, _}, 0
    after
      File.rmdir!(receipt)
      File.rename!(receipt <> ".saved", receipt)
    end

    assert {:accepted, _} = Sigma.Agent.prompt(c.agent, "Use the original committed context")
    next = provider!(@session)
    assert inspect(next.params.context.messages) =~ "Committed context before retry"
    refute inspect(next.params.context.messages) =~ "Rejected retry content"
    respond!(next, "retry projection restored")
    assert eventually(fn -> Sigma.Agent.status(c.agent).phase == :completed end)
  end

  defp retired_failure!(c) do
    {_child, root, admission, _io, _store, thread} = failed_child!(c)
    assert {:ok, goal_before} = GoalStore.load(c.goal_store, thread)
    set_fault(c.goal_fault, :allow)
    assert {:cancelling, _} = Sigma.Agent.cancel(c.agent)

    assert eventually(fn ->
             case root_snapshot(c.path, root.params.turn_id) do
               {:ok, %{run: %{state: :unknown_outcome}}} -> true
               _ -> false
             end
           end)

    assert eventually(fn -> Sigma.Agent.status(c.agent).phase in [:failed, :cancelled] end)
    # The turn phase settles before the independent Goal idle task returns.
    # Join that task before requesting host retirement; busy is not closure.
    assert eventually(fn -> is_nil(:sys.get_state(c.agent).goal_idle_task) end)
    assert_pending_archive!(c, goal_before)
    assert is_pid(LifetimeRecovery.locate(c.path))
    assert {:ok, original} = root_snapshot(c.path, root.params.turn_id)
    assert original.run.state == :unknown_outcome
    assert is_map(original.run.active_provider)

    intent =
      original.run.execution_intents["provider:" <> original.run.active_provider.attempt_id]

    assert intent.status == :uncertain
    assert intent.operation.attempt_id == original.run.active_provider.attempt_id
    {original, admission, thread, goal_before}
  end

  defp stop_repository!(c) do
    repository = Runtime.lookup(c.dir, :supervisor)
    assert is_pid(repository)

    owners = :sys.get_state(c.host)

    processes =
      [repository, c.agent, c.writer, c.host, :sys.get_state(c.agent).backplane_store] ++
        Map.values(Map.take(owners, [:manager, :session, :codex_resources, :lifetime_recovery])) ++
        Enum.map(owners.children, fn {_id, child} -> child.io end)

    monitors =
      for pid <- Enum.uniq(processes), is_pid(pid), do: {pid, Process.monitor(pid)}

    pending =
      if match?({:reject_usage, _}, Agent.get(c.goal_fault, & &1.mode)) do
        for {path, bytes} <- runtime_bytes(c.path),
            String.starts_with?(path, c.path <> ".subagents/"),
            record = :erlang.binary_to_term(bytes, [:safe]),
            get_in(record, [:run, :context, :conversation, :goal_outbox]) not in [nil, []],
            into: %{},
            do: {path, {bytes, record}}
      else
        %{}
      end

    assert :ok = DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, repository)

    for {pid, ref} <- monitors do
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 15_000
      refute Process.alive?(pid)
    end

    assert LifetimeRecovery.locate(c.path) == nil

    if map_size(pending) > 0 do
      stages =
        for {reference, stage} <- ledger!(c.path).evidence,
            String.starts_with?(reference, "child-export-stage:"),
            do: stage

      assert length(stages) >= map_size(pending)

      for {path, {bytes, record}} <- pending do
        assert File.read!(path) == bytes
        stage = Enum.find(stages, &(&1["child_identity"]["run_id"] == record.run.run_id))
        assert stage
        assert stage["record_type"] == "child_export_stage"
        assert stage["source_checkpoint"]["revision"] == record.revision
        assert stage["source_checkpoint"]["goal_outbox"] != []
      end
    end

    set_fault(c.goal_fault, :allow)
  end

  defp assert_pending_archive!(c, goal_before) do
    set_fault(c.goal_fault, {:reject_usage, goal_before.usage})

    assert {:error,
            %Backplane.AgentRuntime.Error{
              class: :resource_conflict,
              message: "archive has unsettled accepted input or delivery obligations"
            } = archive_error} = Subagents.close(c.host)

    assert {:error, %Backplane.AgentRuntime.Error{cause: :injected_child_goal_usage_failure}} =
             Sigma.Agent.retire_host(c.agent)

    assert %{result: {:ok, %{status: :confirmed, capture: :durable}}} =
             :sys.get_state(c.agent).host_retirement_facts

    assert {:ok, sources} = Subagents.archive_sources(c.host)
    assert sources.execution_closed
    assert match?({:ok, %{status: :confirmed}}, sources.execution_result)
    refute sources.generation_closed
    assert sources.completion_stage == :pending
    assert sources.archive_result == {:error, archive_error}
  end

  defp respond!(provider, text),
    do: send(provider.pid, {:recovery_response, [%{type: :text, text: text}]})

  defp stopped_children(host) do
    {:ok, %{subagents: roster}} = Subagents.snapshot(host)
    roster.counts.stopped
  end

  defp ledger!(path),
    do:
      :erlang.binary_to_term(
        File.read!(Path.join(path <> ".subagents", "lifetime-recovery.etf")),
        [:safe]
      )

  defp root_snapshot(path, run), do: with_store(path <> ".runtime", &Store.load(&1, run))

  defp child_snapshot(path, child, run),
    do: with_store(Path.join([path <> ".subagents", child, "runtime"]), &Store.load(&1, run))

  defp with_store(path, fun) do
    case Store.start_link(path: path) do
      {:ok, store} ->
        result = fun.(store)
        assert :ok = Store.retire(store)
        result

      {:error, {:already_started, store}} ->
        fun.(store)
    end
  end

  defp runtime_bytes(path) do
    [path <> ".runtime/*.runtime", path <> ".subagents/*/runtime/*.runtime"]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Map.new(&{&1, File.read!(&1)})
  end

  defp session_options(c) do
    [
      cwd: c.dir,
      transcript_path: c.path,
      native_tools: true,
      native_memory_root: Path.join(c.dir, "memories"),
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
    ]
  end

  defp detached_child!(c) do
    assert {:accepted, _} = Sigma.Agent.prompt(c.agent, "Delegate work that outlives this turn")
    root = provider!(@session)

    send_call(root, "spawn_agent", %{
      "task_name" => "contributor",
      "message" => "Wait for a response",
      "fork_turns" => "none"
    })

    child = provider!(:child)
    root = provider!(@session)
    respond!(root, "Root finished while the child remains active")
    assert eventually(fn -> Sigma.Agent.status(c.agent).phase == :completed end)
    assert eventually(fn -> is_nil(:sys.get_state(c.agent).goal_idle_task) end)
    {child, root}
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

  defp set_fault(control, mode), do: Agent.update(control, &%{&1 | mode: mode})

  defp cancel_failed_root!(c) do
    assert {:cancelling, _} = Sigma.Agent.cancel(c.agent)
    assert eventually(fn -> Sigma.Agent.status(c.agent).phase in [:failed, :cancelled] end)
    assert eventually(fn -> is_nil(:sys.get_state(c.agent).goal_idle_task) end)
  end

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

  defp received_errors do
    {:messages, messages} = Process.info(self(), :messages)
    for {:turn_error, error} <- messages, do: error
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
