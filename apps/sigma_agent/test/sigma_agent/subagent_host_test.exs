defmodule Sigma.Agent.SubagentHostTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.{PublicRuntime, Runtime, Subagents}

  defmodule Provider do
    @behaviour Sigma.Ai.Provider
    def stream(params) do
      send(params.options[:test_pid], {:host_provider, self(), params})

      receive do
        {:host_response, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            content: content,
            stop_reason: reason,
            usage: %{
              input: 1,
              output: 1,
              total_tokens: 2,
              cache_read: 0,
              cache_write: 0,
              cost: %{total: 0.0}
            },
            model: "test",
            provider: "test",
            api: "test",
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, reason, message}]
      end
    end
  end

  defmodule FaultStorage do
    @behaviour Sigma.Session.Storage
    defdelegate read(path), to: Sigma.Session.Storage.JsonlFile
    defdelegate read_with_diagnostics(path), to: Sigma.Session.Storage.JsonlFile

    def append(path, entry) do
      phase = entry["phase"]

      if entry["type"] == "subagent_admission" and
           File.exists?(path <> ".fail-" <> to_string(phase)),
         do: {:error, :enospc},
         else: Sigma.Session.Storage.JsonlFile.append(path, entry)
    end
  end

  defmodule SpawnCollision do
    @behaviour Sigma.Coding.Tool
    def name, do: "spawn_agent"
    def description, do: "Deliberately collides with collaboration catalog"
    def schema, do: %{"type" => "object", "properties" => %{}}
    def execute(_, _, _), do: raise("must not dispatch")
  end

  setup %{tmp_dir: dir} = tags do
    path = Path.join(dir, "root.jsonl")

    {:ok, handle} =
      Runtime.get_session(dir, "root",
        cwd: dir,
        transcript_path: path,
        storage_mod: FaultStorage,
        provider: Provider,
        model: %{id: "test", provider: "test", api: "test"},
        tools: Map.get(tags, :tools, []),
        permission_config: Map.get(tags, :permission_config),
        max_concurrent_threads_per_session: Map.get(tags, :max_threads, 4),
        hook_specs: [],
        options: [test_pid: self()]
      )

    host = Runtime.lookup(dir, "root", :subagents)
    Sigma.Agent.subscribe(handle.agent)

    on_exit(fn ->
      Runtime.close_subagents(dir, "root")

      case Runtime.lookup(dir, :supervisor) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
      end
    end)

    {:ok, agent: handle.agent, host: host, repo: dir, path: path}
  end

  @moduletag :tmp_dir

  test "writerless Runtime sessions run with only their available tools", ctx do
    session_id = "writerless"

    {:ok, handle} =
      Runtime.get_session(ctx.repo, session_id,
        cwd: ctx.repo,
        backplane_runtime_path: Path.join(ctx.repo, "writerless-runtime"),
        provider: Provider,
        model: %{id: "test", provider: "test", api: "test"},
        tools: [Sigma.Tools.Read],
        hook_specs: [],
        options: [test_pid: self()]
      )

    assert handle.writer == nil
    host = Runtime.lookup(ctx.repo, session_id, :subagents)
    assert {:ok, %{available: false}} = Subagents.snapshot(host)
    :ok = Sigma.Agent.subscribe(handle.agent)
    assert {:accepted, _} = Sigma.Agent.prompt(handle.agent, "ordinary writerless turn")
    root = provider(session_id)
    assert Enum.map(root.params.context.tools, & &1.name) == ["read"]
    finish(root.pid)

    assert_receive {:agent_end, messages}, 5_000

    assert [
             %{role: :user},
             %{role: :assistant, content: [%{type: :text, text: "done"}]}
           ] = messages

    assert Sigma.Agent.status(handle.agent).phase == :completed

    assert {:ok, %{available: false, subagents: %{counts: %{created: 0}}}} =
             Subagents.snapshot(host)
  end

  test "real nested conversations share slots and publish only confirmed durable identities",
       ctx do
    assert {:accepted, _} = Sigma.Agent.prompt(ctx.agent, "delegate")
    root = provider("root")
    assert Enum.any?(root.params.context.tools, &(&1.name == "spawn_agent"))

    call(root.pid, "spawn_agent", %{
      "task_name" => "a",
      "message" => "first",
      "fork_turns" => "none"
    })

    a = child_provider()
    root_next = provider("root")
    assert_native_result(root_next.params, "spawn_agent", "task_name", "/root/a")

    call(a.pid, "spawn_agent", %{
      "task_name" => "b",
      "message" => "second",
      "fork_turns" => "none"
    })

    b = child_provider()
    a_next = provider(a.params.session_id)
    assert_native_result(a_next.params, "spawn_agent", "task_name", "/root/a/b")

    call(b.pid, "spawn_agent", %{"task_name" => "c", "message" => "third", "fork_turns" => "none"})

    c = child_provider()
    b_next = provider(b.params.session_id)
    assert eventually(fn -> roster(ctx.host).counts.executing == 3 end)
    roster = roster(ctx.host)
    assert roster.counts.created == 3
    assert Enum.map(roster.agents, & &1.agent_path) == ["/root/a", "/root/a/b", "/root/a/b/c"]
    [row_a, row_b, row_c] = roster.agents
    assert row_b.parent_agent_id == row_a.agent_id
    assert row_c.parent_agent_id == row_b.agent_id
    assert row_c.depth == 3
    assert {:error, :subagent_resources_active} = Subagents.can_stop(ctx.host)
    assert {:error, :session_busy} = Sigma.Agent.begin_session_operation(ctx.agent)
    {:ok, persisted} = Sigma.Session.Log.snapshot(ctx.path)
    assert persisted.subagents.counts.created == 3
    assert length(persisted.subagent_admissions |> Map.values()) == 3

    assert Enum.any?(persisted.messages, fn message ->
             result =
               message.metadata[:structured_result] || message.metadata["structured_result"]

             (message.role == :tool_result and result) && result["task_name"] == "/root/a"
           end)

    refute Enum.any?(persisted.messages, &(&1.content in ["first", "second", "third"]))
    finish(c.pid)
    finish(b_next.pid)
    finish(a_next.pid)
    finish(root_next.pid)
    assert eventually(fn -> roster(ctx.host).counts.stopped == 3 end)
    assert eventually(fn -> Sigma.Agent.status(ctx.agent).phase == :completed end)
    assert :ok = Subagents.can_stop(ctx.host)
  end

  test "normal root completion retains child identity for a later followup", ctx do
    Sigma.Agent.prompt(ctx.agent, "first turn")
    root = provider("root")

    call(root.pid, "spawn_agent", %{
      "task_name" => "a",
      "message" => "work",
      "fork_turns" => "none"
    })

    child = child_provider()
    root_next = provider("root")
    finish(child.pid)
    finish(root_next.pid)
    assert eventually(fn -> roster(ctx.host).counts.stopped == 1 end)
    assert eventually(fn -> Sigma.Agent.status(ctx.agent).phase == :completed end)
    [before] = roster(ctx.host).agents

    assert {:accepted, _} = Sigma.Agent.prompt(ctx.agent, "continue")
    root = provider("root")
    call(root.pid, "followup_task", %{"target" => "/root/a", "message" => "next"})
    next = provider(child.params.session_id)
    root_next = provider("root")
    assert eventually(fn -> roster(ctx.host).counts.executing == 1 end)
    [after_row] = roster(ctx.host).agents
    assert after_row.agent_id == before.agent_id
    assert after_row.child_session_id == before.child_session_id
    assert after_row.run_id != before.run_id
    assert after_row.incarnation == before.incarnation + 1
    assert roster(ctx.host).counts.created == 1
    assert Enum.any?(next.params.context.messages, &(&1.role == :assistant))
    finish(next.pid)
    finish(root_next.pid)
    assert eventually(fn -> roster(ctx.host).counts.stopped == 1 end)
  end

  @tag tools: [Sigma.Tools.Write]
  @tag permission_config: %{default: :allow, rules: %{}}
  test "concurrent children write separate files and retain only their own tool history", ctx do
    Sigma.Agent.prompt(ctx.agent, "delegate file creation")
    root = provider("root")

    {root, children} =
      Enum.reduce(["a", "b"], {root, []}, fn name, {root, children} ->
        call(root.pid, "spawn_agent", %{
          "task_name" => name,
          "message" => "create #{name}.txt",
          "fork_turns" => "none"
        })

        child = child_provider()
        {provider("root"), children ++ [{name, child}]}
      end)

    for {name, child} <- children do
      call(child.pid, "write", %{"path" => "#{name}.txt", "content" => "written by #{name}"})
    end

    for {name, child} <- children do
      continued = provider(child.params.session_id)
      assert File.read!(Path.join(ctx.repo, "#{name}.txt")) == "written by #{name}"
      results = Enum.filter(continued.params.context.messages, &(&1.role == :tool_result))
      assert [%{tool_name: "write", is_error: false} = result] = results

      calls =
        for %{role: :assistant, content: blocks} <- continued.params.context.messages,
            %{type: :tool_call, name: "write"} = block <- blocks,
            do: block

      assert [write_call] = calls
      assert write_call.arguments == %{"path" => "#{name}.txt", "content" => "written by #{name}"}
      assert result.tool_call_id == write_call.id

      finish(continued.pid)
    end

    finish(root.pid)
    assert eventually(fn -> roster(ctx.host).counts.stopped == 2 end)
    assert eventually(fn -> Sigma.Agent.status(ctx.agent).phase == :completed end)
    {:ok, persisted} = Sigma.Session.Log.snapshot(ctx.path)
    refute Enum.any?(persisted.messages, &(Map.get(&1, :tool_name) == "write"))

    for row <- roster(ctx.host).agents do
      name = Path.basename(row.agent_path)
      path = Path.join([ctx.path <> ".subagents", row.child_session_id, "session.jsonl"])
      assert {:ok, child_log} = Sigma.Session.Log.snapshot(path)

      calls =
        for %{role: :assistant, content: blocks} <- child_log.messages,
            %{type: :tool_call, name: "write"} = block <- blocks,
            do: block

      assert [write_call] = calls
      assert write_call.arguments == %{"path" => "#{name}.txt", "content" => "written by #{name}"}

      assert [%{role: :tool_result, tool_name: "write"} = result] =
               Enum.filter(child_log.messages, &(&1.role == :tool_result))

      assert result.tool_call_id == write_call.id
    end
  end

  test "unavailable configuration rejection persists outcome without phantom creation", ctx do
    Sigma.Agent.prompt(ctx.agent, "invalid child")
    root = provider("root")

    call(root.pid, "spawn_agent", %{"task_name" => "a", "message" => "work", "model" => "missing"})

    next = provider("root")
    assert roster(ctx.host).counts.created == 0
    {:ok, persisted} = Sigma.Session.Log.snapshot(ctx.path)
    [attempt] = Map.values(persisted.subagent_admissions)
    assert [%{status: :rejected, process_started: false}] = attempt.receipts
    finish(next.pid)
    refute_receive {:host_provider, _, %{session_id: "child_" <> _}}, 50
  end

  test "supervisor shutdown closes the collaboration session before stopping its manager", ctx do
    assert {:accepted, _} = Sigma.Agent.prompt(ctx.agent, "prepare collaboration")
    root = provider("root")

    call(root.pid, "spawn_agent", %{
      "task_name" => "shutdown_child",
      "message" => "remain active",
      "fork_turns" => "none"
    })

    child = child_provider()
    root_next = provider("root")
    finish(root_next.pid)
    assert eventually(fn -> Sigma.Agent.status(ctx.agent).phase == :completed end)

    %{session: session, manager: manager, children: children} = :sys.get_state(ctx.host)
    [%{io: child_io}] = Map.values(children)
    child_provider = child.pid
    assert Process.alive?(child_provider)
    assert is_pid(session) and is_pid(manager)
    session_ref = Process.monitor(session)
    manager_ref = Process.monitor(manager)
    child_io_ref = Process.monitor(child_io)
    child_provider_ref = Process.monitor(child_provider)
    repository = Runtime.lookup(ctx.repo, :supervisor)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, repository)
        assert_receive {:DOWN, ^session_ref, :process, ^session, _}, 5_000
        assert_receive {:DOWN, ^manager_ref, :process, ^manager, _}, 5_000
        assert_receive {:DOWN, ^child_io_ref, :process, ^child_io, _}, 5_000
        assert_receive {:DOWN, ^child_provider_ref, :process, ^child_provider, _}, 5_000
      end)

    refute log =~ "no process"
    refute log =~ "noproc"
    refute log =~ "cleanup is unconfirmed"
    refute log =~ "owner stop failed"
    refute Process.alive?(session)
    refute Process.alive?(manager)
    refute Process.alive?(child_io)
    refute Process.alive?(child_provider)
  end

  test "confirmed Stop retains history and an explicit prompt creates a fresh generation", ctx do
    Sigma.Agent.prompt(ctx.agent, "first")
    root = provider("root")

    call(root.pid, "spawn_agent", %{
      "task_name" => "a",
      "message" => "work",
      "fork_turns" => "none"
    })

    _child = child_provider()
    root_next = provider("root")
    finish(root_next.pid)
    assert eventually(fn -> Sigma.Agent.status(ctx.agent).phase == :completed end)
    [before] = roster(ctx.host).agents
    assert {:ok, %{status: :confirmed}} = Runtime.close_subagents(ctx.repo, "root")
    assert roster(ctx.host).counts.executing == 0
    assert roster(ctx.host).counts.unknown == 0
    assert [closed] = roster(ctx.host).agents
    assert closed.closure == :closed
    assert closed.status in [:shutdown, :interrupted]
    assert :ok = Subagents.can_stop(ctx.host)

    assert {:accepted, _} = Sigma.Agent.prompt(ctx.agent, "new work")
    root = provider("root")

    call(root.pid, "spawn_agent", %{
      "task_name" => "a",
      "message" => "fresh",
      "fork_turns" => "none"
    })

    child = child_provider()
    root_next = provider("root")
    assert eventually(fn -> roster(ctx.host).counts.created == 2 end)
    [fresh] = Enum.reject(roster(ctx.host).agents, &(&1.agent_id == before.agent_id))
    assert fresh.run_id != before.run_id
    assert fresh.child_session_id != before.child_session_id
    assert fresh.agent_path == before.agent_path
    finish(child.pid)
    finish(root_next.pid)
    assert eventually(fn -> roster(ctx.host).counts.stopped == 2 end)
  end

  test "default and numeric forks contain complete committed user turns", ctx do
    Sigma.Agent.prompt(ctx.agent, "seed turn")
    seed = provider("root")
    finish(seed.pid)
    assert eventually(fn -> Sigma.Agent.status(ctx.agent).phase == :completed end)
    Sigma.Agent.prompt(ctx.agent, "current turn")
    root = provider("root")
    call(root.pid, "spawn_agent", %{"task_name" => "all", "message" => "all task"})
    all = child_provider()
    root_next = provider("root")

    assert Enum.any?(
             all.params.context.messages,
             &(&1.role == :user and &1.content == "seed turn")
           )

    assert Enum.any?(
             all.params.context.messages,
             &(&1.role == :user and &1.content == "current turn")
           )

    refute Enum.any?(all.params.context.messages, fn message ->
             message.role == :assistant and
               Enum.any?(List.wrap(message.content), &(&1[:type] == :tool_call))
           end)

    finish(all.pid)
    assert eventually(fn -> roster(ctx.host).counts.stopped == 1 end)

    call(root_next.pid, "spawn_agent", %{
      "task_name" => "last",
      "message" => "last task",
      "fork_turns" => "1"
    })

    last = child_provider()
    root_next = provider("root")

    assert Enum.any?(
             last.params.context.messages,
             &(&1.role == :user and &1.content == "current turn")
           )

    refute Enum.any?(
             last.params.context.messages,
             &(&1.role == :user and &1.content == "seed turn")
           )

    finish(last.pid)

    call(root_next.pid, "spawn_agent", %{
      "task_name" => "bad",
      "message" => "invalid",
      "fork_turns" => "0"
    })

    next = provider("root")
    assert roster(ctx.host).counts.created == 2
    finish(next.pid)
  end

  test "child mailbox messages persist once and remain in the next root turn", ctx do
    Sigma.Agent.prompt(ctx.agent, "delegate")
    root = provider("root")

    call(root.pid, "spawn_agent", %{
      "task_name" => "a",
      "message" => "work",
      "fork_turns" => "none"
    })

    child = child_provider()
    root_next = provider("root")
    call(child.pid, "send_message", %{"target" => "/root", "message" => "child report"})
    child_next = provider(child.params.session_id)
    # Queue-only delivery leaves the current blocked parent request untouched.
    refute_receive {:host_provider, _, %{session_id: "root"}}, 20
    call(root_next.pid, "list_agents", %{})
    root_next = provider("root")

    assert Enum.any?(
             root_next.params.context.messages,
             &(&1.role == :user and inspect(&1.content) =~ "child report")
           )

    finish(child_next.pid)
    call(root_next.pid, "wait_agent", %{"timeout_ms" => 10_000})
    root_next = provider("root")

    assert Enum.any?(root_next.params.context.messages, fn message ->
             message.role == :user and inspect(message.content) =~ "FINAL_ANSWER" and
               inspect(message.content) =~ "Agent /root/a completed: done"
           end)

    finish(root_next.pid)
    assert eventually(fn -> Sigma.Agent.status(ctx.agent).phase == :completed end)
    {:ok, snapshot} = Sigma.Session.Log.snapshot(ctx.path)

    reports =
      Enum.filter(
        snapshot.messages,
        &(&1.role == :user and inspect(&1.content) =~ "child report")
      )

    assert [report] = reports
    assert report.metadata[:collaboration] || report.metadata["collaboration"]

    assert Enum.any?(snapshot.messages, fn message ->
             collaboration = message.metadata[:collaboration] || message.metadata["collaboration"]

             collaboration &&
               (collaboration[:kind] || collaboration["kind"]) in [:result, "result"]
           end)

    assert {:accepted, _} = Sigma.Agent.prompt(ctx.agent, "remember")
    root = provider("root")

    assert Enum.count(
             root.params.context.messages,
             &(&1.role == :user and inspect(&1.content) =~ "child report")
           ) == 1

    finish(root.pid)
  end

  test "single target interrupt leaves its descendant and sibling executing", ctx do
    Sigma.Agent.prompt(ctx.agent, "delegate")
    root = provider("root")
    call(root.pid, "spawn_agent", %{"task_name" => "a", "message" => "a", "fork_turns" => "none"})
    a = child_provider()
    root = provider("root")
    call(a.pid, "spawn_agent", %{"task_name" => "b", "message" => "b", "fork_turns" => "none"})
    b = child_provider()
    _a_next = provider(a.params.session_id)
    call(root.pid, "spawn_agent", %{"task_name" => "c", "message" => "c", "fork_turns" => "none"})
    c = child_provider()
    root = provider("root")
    call(root.pid, "interrupt_agent", %{"target" => "/root/a"})
    root = provider("root")
    assert eventually(fn -> roster(ctx.host).counts.executing == 2 end)

    assert Enum.find(roster(ctx.host).agents, &(&1.agent_path == "/root/a")).status ==
             :interrupted

    assert Process.alive?(b.pid)
    assert Process.alive?(c.pid)
    finish(b.pid)
    finish(c.pid)
    finish(root.pid)
  end

  test "new root steering wakes wait without cancelling the child", ctx do
    Sigma.Agent.prompt(ctx.agent, "delegate")
    root = provider("root")
    call(root.pid, "spawn_agent", %{"task_name" => "a", "message" => "a", "fork_turns" => "none"})
    a = child_provider()
    root = provider("root")
    call(root.pid, "wait_agent", %{"timeout_ms" => 10_000})
    assert {:queued_as_steering, _} = Sigma.Agent.steer(ctx.agent, "new instructions")
    root = provider("root")
    assert Process.alive?(a.pid)
    assert roster(ctx.host).counts.executing == 1

    assert Enum.any?(
             root.params.context.messages,
             &(&1.role == :user and inspect(&1.content) =~ "new instructions")
           )

    finish(a.pid)
    finish(root.pid)
  end

  test "execution slots are reused across more tasks than the concurrency limit", ctx do
    Sigma.Agent.prompt(ctx.agent, "sequential delegation")
    root = provider("root")

    root =
      Enum.reduce(1..5, root, fn n, root ->
        call(root.pid, "spawn_agent", %{
          "task_name" => "task#{n}",
          "message" => "work",
          "fork_turns" => "none"
        })

        child = child_provider()
        root = provider("root")
        assert roster(ctx.host).counts.created == n
        assert roster(ctx.host).counts.executing == 1
        finish(child.pid)
        assert eventually(fn -> roster(ctx.host).counts.stopped == n end)
        root
      end)

    finish(root.pid)
  end

  test "capacity rejection does not start a phantom child or abandon existing work", ctx do
    Sigma.Agent.prompt(ctx.agent, "parallel delegation")
    root = provider("root")

    {root, children} =
      Enum.reduce(1..3, {root, []}, fn n, {root, children} ->
        call(root.pid, "spawn_agent", %{
          "task_name" => "task#{n}",
          "message" => "work",
          "fork_turns" => "none"
        })

        child = child_provider()
        {provider("root"), [child | children]}
      end)

    admitted = roster(ctx.host).agents

    call(root.pid, "spawn_agent", %{
      "task_name" => "excess",
      "message" => "work",
      "fork_turns" => "none"
    })

    root = provider("root")

    assert %{is_error: true} =
             Enum.find(Enum.reverse(root.params.context.messages), fn message ->
               Map.get(message, :tool_name) == "spawn_agent"
             end)

    assert roster(ctx.host).counts.created == 3
    assert roster(ctx.host).counts.executing == 3
    assert roster(ctx.host).agents == admitted
    refute_receive {:host_provider, _, %{session_id: "child_" <> _}}, 50
    assert {:ok, persisted} = Sigma.Session.Log.snapshot(ctx.path)
    assert map_size(persisted.subagent_admissions) == 3
    Enum.each(children, &finish(&1.pid))
    finish(root.pid)
    assert eventually(fn -> roster(ctx.host).counts.stopped == 3 end)
    assert eventually(fn -> Sigma.Agent.status(ctx.agent).phase == :completed end)
  end

  for phase <- ["intent", "receipt"] do
    test "#{phase} persistence failure fences dispatch and preserves admission evidence", ctx do
      File.write!(ctx.path <> ".fail-" <> unquote(phase), "fail")
      Sigma.Agent.prompt(ctx.agent, "delegate")
      root = provider("root")

      call(root.pid, "spawn_agent", %{
        "task_name" => "a",
        "message" => "work",
        "fork_turns" => "none"
      })

      assert_receive {:turn_error, _}, 5_000
      refute_receive {:host_provider, _, %{session_id: "child_" <> _}}, 50

      assert {:ok, %{available: false, subagents: %{counts: %{created: 0}}}} =
               Subagents.snapshot(ctx.host)

      assert {:error, :subagent_resources_active} = Subagents.can_stop(ctx.host)
      {:ok, persisted} = Sigma.Session.Log.snapshot(ctx.path)

      if unquote(phase) == "receipt" do
        [attempt] = Map.values(persisted.subagent_admissions)
        assert attempt.receipts == []
        assert attempt.intent.child_session_id != ""
      else
        assert persisted.subagent_admissions == %{}
      end
    end
  end

  test "restart retains unresolved intents and never dispatches them", ctx do
    writer = Runtime.lookup(ctx.repo, "root", :writer)

    intent = %{
      phase: :intent,
      attempt_id: "reserved",
      observer_incarnation: "old-owner",
      agent_id: "old-agent",
      run_id: "old-run",
      incarnation: 1,
      name: "/root/a",
      child_session_id: "old-child",
      metadata: %{},
      facts: []
    }

    assert {:ok, _} = Sigma.Session.Writer.append(writer, {:subagent_admission, intent})
    repository = Runtime.lookup(ctx.repo, :supervisor)
    :ok = DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, repository)

    assert {:ok, _} =
             Runtime.get_session(ctx.repo, "root",
               transcript_path: ctx.path,
               cwd: ctx.repo,
               tools: [],
               provider: Provider,
               model: %{id: "test"}
             )

    host = Runtime.lookup(ctx.repo, "root", :subagents)

    assert {:ok, %{available: false, subagents: %{counts: %{created: 0}}}} =
             Subagents.snapshot(host)

    assert {:error, :subagent_resources_active} = Subagents.can_stop(host)

    assert {:error, %Backplane.AgentRuntime.Error{class: :resource_conflict}} =
             Subagents.prepare_root(host, %{})

    {:ok, persisted} = Sigma.Session.Log.snapshot(ctx.path)
    assert Map.has_key?(persisted.subagent_admissions, "reserved")
    refute_receive {:host_provider, _, _}, 50
  end

  test "concurrent child approvals are fenced and terminal replies cannot release a later run",
       ctx do
    Sigma.Agent.prompt(ctx.agent, "delegate")
    root = provider("root")

    call(root.pid, "spawn_agent", %{
      "task_name" => "a",
      "message" => "first",
      "fork_turns" => "none"
    })

    a = child_provider()
    root = provider("root")

    call(root.pid, "spawn_agent", %{
      "task_name" => "b",
      "message" => "second",
      "fork_turns" => "none"
    })

    b = child_provider()
    root = provider("root")
    [row_a, row_b] = roster(ctx.host).agents

    task_a =
      Task.async(fn ->
        Subagents.ask(ctx.host, identity(row_a), %{
          question: "a?",
          tool_call_id: "approval-a",
          arguments: %{}
        })
      end)

    task_b =
      Task.async(fn ->
        Subagents.ask(ctx.host, identity(row_b), %{
          question: "b?",
          tool_call_id: "approval-b",
          arguments: %{}
        })
      end)

    assert eventually(fn -> length(Subagents.pending(ctx.host)) == 2 end)
    pending = Subagents.pending(ctx.host)
    question_a = Enum.find(pending, &(&1.tool_call_id == "approval-a"))
    question_b = Enum.find(pending, &(&1.tool_call_id == "approval-b"))

    assert :ok =
             Runtime.answer_question(
               ctx.repo,
               "root",
               ctx.agent,
               question_a.id,
               {:ok, "allow_once"}
             )

    assert {:ok, "allow_once"} = Task.await(task_a)
    assert Task.yield(task_b, 10) == nil
    finish(b.pid)
    assert {:error, :cancelled} = Task.await(task_b)

    assert {:error, :not_found} =
             Runtime.answer_question(
               ctx.repo,
               "root",
               ctx.agent,
               question_b.id,
               {:ok, "allow_once"}
             )

    finish(a.pid)
    finish(root.pid)
  end

  @tag tools: [Sigma.Coding.Tools.AskUserQuestion]
  @tag permission_config: %{default: :ask, rules: %{}}
  test "explicit headless resolvers receive exact child source and handle real questions", ctx do
    test = self()

    opts =
      PublicRuntime.prompt_opts(
        %{
          permission_resolver: fn call ->
            send(test, {:headless_permission, call})
            :allow
          end,
          question_resolver: fn request, _opts ->
            send(test, {:headless_question, request})
            {:ok, "headless answer"}
          end
        },
        ctx.agent
      )

    assert {:accepted, _} = Sigma.Agent.prompt(ctx.agent, "delegate", opts)
    root = provider("root")

    call(root.pid, "spawn_agent", %{
      "task_name" => "a",
      "message" => "ask",
      "fork_turns" => "none"
    })

    child = child_provider()
    root = provider("root")
    arguments = %{"question" => "Continue?", "options" => ["yes", "no"]}
    call(child.pid, "AskUserQuestion", arguments)

    assert_receive {:headless_permission, permission}, 5_000
    assert permission.source.agent_path == "/root/a"
    assert permission.arguments == arguments
    assert_receive {:headless_question, question}, 5_000
    assert question.source == permission.source
    assert question.tool_call_id == permission.id
    assert question.arguments == arguments
    child = provider(child.params.session_id)
    assert inspect(List.last(child.params.context.messages).content) =~ "headless answer"
    assert Subagents.pending(ctx.host) == []
    finish(child.pid)
    finish(root.pid)
  end

  test "owner loss invalidates waiting questions and fences late requests", ctx do
    context = %{
      authority: %{
        caller: "root",
        run_id: "owner-loss",
        grants: Subagents.collaboration_tools(),
        tool_revision: 1
      },
      store: nil,
      config: %{
        model: %{id: "test", provider: "test", api: "test"},
        provider: Provider,
        provider_options: [test_pid: self()],
        tools: [],
        cwd: ctx.repo,
        dispatcher_opts: [],
        hook_specs: []
      }
    }

    assert {:ok, %{contracts: [contract | _]}} = Subagents.prepare_root(ctx.host, context)
    manager = contract.backend_context.runtime

    assert {:ok, _} =
             Backplane.AgentRuntime.Codex.MultiAgent.call(%{
               backend_context: %{runtime: manager, profile: :v2},
               run_id: "owner-loss",
               tool_name: "spawn_agent",
               arguments: %{"task_name" => "a", "message" => "work", "fork_turns" => "none"}
             })

    child_provider()
    [row] = roster(ctx.host).agents
    child = identity(row)
    waiter = Task.async(fn -> Subagents.ask(ctx.host, child, %{question: "waiting?"}) end)
    assert eventually(fn -> length(Subagents.pending(ctx.host)) == 1 end)
    assert :ok = GenServer.stop(manager, :shutdown)
    assert {:error, :cancelled} = Task.await(waiter)

    assert {:ok, %{available: false, subagents: %{counts: %{unknown: 1}}}} =
             Subagents.snapshot(ctx.host)

    assert {:error, :stale_subagent_request} =
             Subagents.ask(ctx.host, child, %{question: "late?"})

    assert Subagents.pending(ctx.host) == []
    assert {:error, :subagent_resources_active} = Subagents.can_stop(ctx.host)
  end

  @tag tools: [Sigma.Coding.Tools.AskUserQuestion]
  @tag permission_config: %{default: :ask, rules: %{}}
  test "headless child without a resolver returns approval required without waiting", ctx do
    Sigma.Agent.prompt(ctx.agent, "delegate")
    root = provider("root")

    call(root.pid, "spawn_agent", %{
      "task_name" => "a",
      "message" => "ask",
      "fork_turns" => "none"
    })

    child = child_provider()
    root = provider("root")
    call(child.pid, "AskUserQuestion", %{"question" => "Continue?"})
    child = provider(child.params.session_id)
    result = List.last(child.params.context.messages)
    assert result.is_error
    assert inspect(result.content) =~ "Approval required for tool: AskUserQuestion"
    assert Subagents.pending(ctx.host) == []
    finish(child.pid)
    finish(root.pid)
  end

  @tag tools: [SpawnCollision]
  test "catalog refusal closes a reserved binding so the next root can prepare", ctx do
    Sigma.Agent.prompt(ctx.agent, "invalid catalog")
    assert_receive {:turn_error, _}, 5_000
    refute_receive {:host_provider, _, _}, 20

    assert {:ok, %{binding: binding}} =
             Subagents.prepare_root(ctx.host, %{
               authority: %{
                 caller: "root",
                 run_id: "after-catalog-failure",
                 grants: Subagents.collaboration_tools(),
                 tool_revision: 1
               },
               store: nil,
               config: %{dispatcher_opts: [], tools: [], cwd: ctx.repo}
             })

    assert is_pid(binding.session)
  end

  @tag max_threads: 0
  test "failed manager startup retires the newly created Session owner", ctx do
    Sigma.Agent.prompt(ctx.agent, "invalid capacity configuration")
    assert_receive {:turn_error, _}, 5_000
    refute_receive {:host_provider, _, _}, 20

    owners =
      Enum.filter(Process.list(), fn pid ->
        case Process.info(pid, :monitors) do
          {:monitors, monitors} ->
            {:process, ctx.host} in monitors and
              :proc_lib.translate_initial_call(pid) ==
                {Backplane.AgentRuntime.Codex.Session, :init, 1}

          _ ->
            false
        end
      end)

    assert owners == []
  end

  test "close waits for first preparation and fences its pending binding", ctx do
    context = %{
      authority: %{
        caller: "root",
        run_id: "closing-prepare",
        grants: Subagents.collaboration_tools(),
        tool_revision: 1
      },
      store: nil,
      config: %{dispatcher_opts: [], tools: [], cwd: ctx.repo}
    }

    # Queue both public calls before allowing preparation to create its owners.
    :ok = :sys.suspend(ctx.host)
    preparing = Task.async(fn -> Subagents.prepare_root(ctx.host, context) end)
    assert eventually(fn -> elem(Process.info(ctx.host, :message_queue_len), 1) >= 1 end)
    closing = Task.async(fn -> Subagents.close(ctx.host) end)
    assert eventually(fn -> elem(Process.info(ctx.host, :message_queue_len), 1) >= 2 end)
    :ok = :sys.resume(ctx.host)

    assert {:error, %Backplane.AgentRuntime.Error{class: :resource_conflict}} =
             Task.await(preparing)

    assert {:ok, %{status: :confirmed}} = Task.await(closing)
    assert Subagents.can_stop(ctx.host) == :ok

    context = put_in(context.authority.run_id, "after-closing-prepare")
    assert {:ok, %{binding: binding}} = Subagents.prepare_root(ctx.host, context)
    assert Backplane.AgentRuntime.Codex.Session.status(binding.session).phase == :reserved
    refute_receive {:host_provider, _, _}, 20
  end

  defp identity(row) do
    [generation, runtime_run] = String.split(row.run_id, ":", parts: 2)

    row
    |> Map.put(:public_run_id, row.run_id)
    |> Map.put(:run_id, runtime_run)
    |> Map.put(:observer_incarnation, generation)
  end

  defp roster(host) do
    {:ok, %{available: true, subagents: roster}} = Subagents.snapshot(host)
    roster
  end

  defp provider(session_id) do
    receive do
      {:host_provider, pid, %{session_id: ^session_id} = params} -> %{pid: pid, params: params}
      {:turn_error, error} -> flunk("root failed: #{inspect(error)}")
    after
      5_000 -> flunk("provider did not start for #{session_id}")
    end
  end

  defp child_provider do
    receive do
      {:host_provider, pid, %{session_id: "child_" <> _} = params} -> %{pid: pid, params: params}
      {:turn_error, error} -> flunk("root failed: #{inspect(error)}")
    after
      5_000 -> flunk("child provider did not start")
    end
  end

  defp call(pid, name, arguments) do
    send(
      pid,
      {:host_response,
       [
         %{
           type: :tool_call,
           id: "call_" <> Integer.to_string(System.unique_integer([:positive])),
           name: name,
           arguments: arguments
         }
       ]}
    )
  end

  defp assert_native_result(params, tool, key, value) do
    message = Enum.find(Enum.reverse(params.context.messages), &(Map.get(&1, :tool_name) == tool))
    assert message
    assert [%{type: :text, text: text}] = message.content
    assert Jason.decode!(text)[key] == value
  end

  defp finish(pid), do: send(pid, {:host_response, [%{type: :text, text: "done"}]})
  defp eventually(fun, retries \\ 200)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, retries) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(fun, retries - 1)
        )
  end
end
