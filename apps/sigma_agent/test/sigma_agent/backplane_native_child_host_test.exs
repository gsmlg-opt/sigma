defmodule Sigma.Agent.BackplaneNativeChildHostTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.{PublicRuntime, Runtime, Subagents}
  alias Sigma.Agent.Backplane.{ChildIO, PlanProjection, Store}
  alias Sigma.Session.{Log, Writer}

  @moduletag :tmp_dir

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    def output_token_limit(_model, opts), do: opts[:max_tokens]

    def stream(params) do
      send(params.options[:test_pid], {:native_provider, self(), params})

      receive do
        {:native_response, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            content: content,
            stop_reason: reason,
            usage: %{input: 1, output: 1, total_tokens: 2, cost: %{total: 0.0}},
            model: "test",
            provider: "test",
            api: "openai-responses",
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, reason, message}]
      end
    end
  end

  setup %{tmp_dir: dir} = tags do
    path = Path.join(dir, "native-child-root.jsonl")

    assert {:ok, handle} =
             Runtime.get_session(dir, "native-root",
               cwd: dir,
               transcript_path: path,
               provider: Provider,
               model: %{
                 id: "test",
                 provider: "test",
                 api: "openai-responses",
                 context_window: Map.get(tags, :context_window)
               },
               native_tools: true,
               native_memory_root: Path.join(dir, "memories"),
               tools: [],
               permission_config: Map.get(tags, :permission_config),
               hook_specs: [],
               options: [test_pid: self(), max_tokens: Map.get(tags, :max_tokens)]
             )

    :ok = Sigma.Agent.subscribe(handle.agent)
    host = Runtime.lookup(dir, "native-root", :subagents)

    on_exit(fn ->
      case Runtime.lookup(dir, :supervisor) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
      end
    end)

    %{agent: handle.agent, host: host, path: path, dir: dir}
  end

  test "managed child catalog includes published apply_patch", c do
    root = prompt!(c.agent)
    {child, root} = spawn!(root, "a")
    assert Enum.any?(child.params.context.tools, &(&1.name == "apply_patch"))
    finish!(child)
    finish!(root)
  end

  test "an admitted managed child raw patch creates its file", c do
    root = prompt!(c.agent)
    {child, root} = spawn!(root, "a")
    patch = "*** Begin Patch\n*** Add File: child-patch.txt\n+created once\n*** End Patch"
    child = call!(child, "apply_patch", patch)
    refute result!(child, "apply_patch").is_error
    assert structured!(child, "apply_patch")["status"] == "applied"
    assert File.read!(Path.join(c.dir, "child-patch.txt")) == "created once\n"
    finish!(child)
    finish!(root)
  end

  test "real Deno managed child dispatch applies a raw patch", c do
    assert is_binary(System.find_executable("deno"))
    root = prompt!(c.agent)
    {child, root} = spawn!(root, "a")

    patch =
      "*** Begin Patch\n*** Add File: child-deno-patch.txt\n+created once\n*** End Patch"

    child =
      call!(child, "exec", """
      const names = ALL_TOOLS.map(tool => tool.tool_name);
      const result = await tools.apply_patch(#{Jason.encode!(patch)});
      return {result, names};
      """)

    assert %{
             "status" => "completed",
             "value" => %{"result" => %{"status" => "applied"}, "names" => names}
           } =
             structured!(child, "exec")

    assert "apply_patch" in names
    assert File.read!(Path.join(c.dir, "child-deno-patch.txt")) == "created once\n"
    finish!(child)
    finish!(root)
  end

  test "managed children receive the applicable native profile and truthful context control", c do
    root = prompt!(c.agent)
    {child, root} = spawn!(root, "a")
    names = Enum.map(child.params.context.tools, & &1.name)

    for name <-
          ~w(exec_command write_stdin apply_patch update_plan view_image clock::curr_time clock::sleep exec wait get_context_remaining) do
      assert name in names
    end

    for name <-
          ~w(request_user_input request_user_input_async send_message_to_user_async new_context) do
      refute name in names
    end

    assert Enum.all?(Subagents.collaboration_tools(), &(&1 in names))
    child = call!(child, "get_context_remaining", %{})
    remaining = result!(child, "get_context_remaining")
    refute remaining.is_error
    assert Map.has_key?(structured!(child, "get_context_remaining"), "tokens_left")
    # A mock model has no authoritative context window. Unknown must stay nil.
    assert structured!(child, "get_context_remaining")["tokens_left"] == nil
    child = call!(child, "list_agents", %{})
    refute result!(child, "list_agents").is_error
    finish!(child)
    finish!(root)
  end

  test "successful followup retains child commands and confirmed Plan history", c do
    root = prompt!(c.agent)
    {child, root} = spawn!(root, "a")

    child =
      call!(child, "update_plan", %{"plan" => [%{"step" => "Child plan", "status" => "pending"}]})

    refute result!(child, "update_plan").is_error

    child =
      call!(child, "exec_command", %{
        "cmd" => "read value; printf '%s' \"$value\"",
        "yield_time_ms" => 20
      })

    command = structured!(child, "exec_command")
    assert command["status"] == "running"
    assert is_integer(command["session_id"])
    finish!(child)
    assert eventually(fn -> roster(c.host).counts.stopped == 1 end)
    [before] = roster(c.host).agents
    assert {:ok, saved} = Log.snapshot(child_path(c, before))
    assert %{"plan" => [%{"step" => "Child plan"}]} = PlanProjection.latest(saved.messages)
    assert {:ok, root_saved} = Log.snapshot(c.path)
    assert PlanProjection.latest(root_saved.messages) == nil

    send_call(root, "followup_task", %{"target" => "/root/a", "message" => "continue"})
    next = provider!(child.params.session_id)
    root = provider!("native-root")
    [after_row] = roster(c.host).agents
    assert after_row.agent_id == before.agent_id
    assert after_row.child_session_id == before.child_session_id
    assert after_row.run_id != before.run_id
    assert Enum.any?(next.params.context.messages, &(Map.get(&1, :tool_name) == "update_plan"))

    next =
      call!(next, "write_stdin", %{
        "session_id" => command["session_id"],
        "chars" => "retained\n",
        "yield_time_ms" => 1_000
      })

    assert structured!(next, "write_stdin")["output"] =~ "retained"
    finish!(next)
    finish!(root)
    assert eventually(fn -> Sigma.Agent.status(c.agent).phase == :completed end)
    assert eventually(fn -> roster(c.host).counts.stopped == 1 end)
    {store, store_path} = child_store!(c, child.params.session_id)
    assert {:ok, ledger} = Store.host_retirement(store, :all)
    [host] = Map.values(ledger.hosts)
    assert map_size(host.bindings) == 2

    assert {:ok, %{admissions: admissions}} =
             Writer.subagent_state(Runtime.lookup(c.dir, "native-root", :writer))

    child_admissions =
      admissions
      |> Map.values()
      |> Enum.filter(&(&1.intent.child_session_id == child.params.session_id))

    assert MapSet.new(Enum.map(child_admissions, & &1.intent.run_id)) ==
             MapSet.new([child.params.turn_id, next.params.turn_id])

    assert MapSet.new(Enum.map(host.bindings, fn {_key, binding} -> binding.run_id end)) ==
             MapSet.new(Enum.map(child_admissions, & &1.intent.metadata["runtime_run_id"]))

    assert host.native == %{}
    assert host.async_hooks == nil
    assert {:ok, %{status: :confirmed}} = Subagents.close(c.host)
    reopened = start_supervised!({Store, path: store_path}, id: :retired_followup_store)

    for {_key, binding} <- host.bindings do
      assert {:ok, %{status: :confirmed}} = Store.host_retirement(reopened, binding)
    end
  end

  @tag max_tokens: 128, context_window: 100_000
  test "child remaining budget falls as its current committed context grows", c do
    root = prompt!(c.agent)
    {child, root} = spawn!(root, "a")
    child = call!(child, "get_context_remaining", %{})
    first = structured!(child, "get_context_remaining")["tokens_left"]
    assert is_integer(first) and first > 0

    child =
      call!(child, "update_plan", %{
        "explanation" => String.duplicate("Current child context. ", 120),
        "plan" => [%{"step" => "Read", "status" => "pending"}]
      })

    child = call!(child, "get_context_remaining", %{})
    second = structured!(child, "get_context_remaining")["tokens_left"]
    assert is_integer(second) and second < first
    finish!(child)
    finish!(root)
  end

  test "siblings cannot consume another child's command handle or Plan state", c do
    root = prompt!(c.agent)
    {a, root} = spawn!(root, "a")
    {b, root} = spawn!(root, "b")
    a = call!(a, "update_plan", %{"plan" => [%{"step" => "Only A", "status" => "pending"}]})
    b = call!(b, "update_plan", %{"plan" => [%{"step" => "Only B", "status" => "completed"}]})

    a =
      call!(a, "exec_command", %{
        "cmd" => "read value; printf '%s' \"$value\"",
        "yield_time_ms" => 20
      })

    handle = structured!(a, "exec_command")["session_id"]
    assert is_integer(handle)
    send_call(b, "write_stdin", %{"session_id" => handle, "chars" => "wrong\n"})
    assert_uncertain_handle_refusal(c.host, b.params.session_id)

    a =
      call!(a, "write_stdin", %{
        "session_id" => handle,
        "chars" => "owner\n",
        "yield_time_ms" => 1_000
      })

    assert structured!(a, "write_stdin")["output"] == "owner"
    finish!(a)

    assert eventually(fn ->
             Enum.find(roster(c.host).agents, &(&1.agent_path == "/root/a")).status == :completed
           end)

    for {row, step} <- Enum.zip(roster(c.host).agents, ["Only A", "Only B"]) do
      assert {:ok, saved} = Log.snapshot(child_path(c, row))
      assert %{"plan" => [%{"step" => ^step}]} = PlanProjection.latest(saved.messages)
    end

    finish!(root)
  end

  @tag permission_config: %{default: :allow, rules: %{"exec_command" => :ask}}
  test "native child command permission denial uses the exact child route before effects", c do
    owner = self()

    opts =
      PublicRuntime.prompt_opts(
        %{
          permission_resolver: fn call ->
            send(owner, {:child_command_permission, call})
            {:deny, :test_denied}
          end
        },
        c.agent
      )

    root = prompt!(c.agent, opts)
    {child, root} = spawn!(root, "a")
    arguments = %{"cmd" => "printf denied > denied-child-command.txt", "yield_time_ms" => 1_000}
    child = call!(child, "exec_command", arguments)
    assert_receive {:child_command_permission, permission}, 5_000
    assert permission.source.agent_path == "/root/a"
    assert permission.name == "exec_command"
    assert permission.arguments == arguments
    assert result!(child, "exec_command").is_error
    refute File.exists?(Path.join(c.dir, "denied-child-command.txt"))
    assert Subagents.pending(c.host) == []
    finish!(child)
    finish!(root)
  end

  @tag permission_config: %{default: :allow, rules: %{"apply_patch" => :ask}}
  test "native child preparation applies exact child permission denial before effects", c do
    owner = self()

    opts =
      PublicRuntime.prompt_opts(
        %{
          permission_resolver: fn call ->
            send(owner, {:child_permission, call})
            {:deny, :test_denied}
          end
        },
        c.agent
      )

    root = prompt!(c.agent, opts)
    {child, root} = spawn!(root, "a")
    patch = "*** Begin Patch\n*** Add File: denied-child.txt\n+denied\n*** End Patch"
    child = call!(child, "apply_patch", patch)
    assert_receive {:child_permission, permission}, 5_000
    assert permission.source.agent_path == "/root/a"
    assert permission.name == "apply_patch"
    assert permission.arguments == patch
    assert result!(child, "apply_patch").is_error
    refute File.exists?(Path.join(c.dir, "denied-child.txt"))
    assert Subagents.pending(c.host) == []
    finish!(child)
    finish!(root)
  end

  test "interrupting an active child provider permits direct parent completion", c do
    root = prompt!(c.agent)
    turn_id = Sigma.Agent.status(c.agent).turn_id
    {child, root} = spawn!(root, "a")
    pid_file = Path.join(c.dir, "interrupted-child.pid")

    child =
      call!(child, "exec_command", %{
        "cmd" => "printf '%s' \"$$\" > interrupted-child.pid; read value",
        "yield_time_ms" => 20
      })

    assert structured!(child, "exec_command")["status"] == "running"
    assert eventually(fn -> File.exists?(pid_file) end)
    os_pid = File.read!(pid_file) |> String.trim() |> String.to_integer()
    assert File.exists?("/proc/#{os_pid}")
    provider_monitor = Process.monitor(child.pid)

    root = call!(root, "interrupt_agent", %{"target" => "/root/a"})
    refute result!(root, "interrupt_agent").is_error
    assert structured!(root, "interrupt_agent")["status"] == "interrupted"
    assert_receive {:DOWN, ^provider_monitor, :process, _, _}, 5_000
    assert eventually(fn -> not File.exists?("/proc/#{os_pid}") end)

    assert eventually(fn ->
             [row] = roster(c.host).agents
             row.status == :interrupted and row.closure == :closed
           end)

    finish!(root)
    assert_receive {:turn_completed, ^turn_id}, 5_000
    assert Sigma.Agent.status(c.agent).phase == :completed
    refute_receive {:turn_failed, ^turn_id}, 0
    refute_receive {:turn_error, _}, 0
  end

  test "interrupted child replaces closed native resources while retaining journal identity", c do
    root = prompt!(c.agent)
    {child, root} = spawn!(root, "a")
    child = call!(child, "exec_command", %{"cmd" => "read value", "yield_time_ms" => 20})
    handle = structured!(child, "exec_command")["session_id"]
    assert is_integer(handle)
    [before] = roster(c.host).agents
    root = call!(root, "interrupt_agent", %{"target" => "/root/a"})
    assert eventually(fn -> hd(roster(c.host).agents).status == :interrupted end)
    send_call(root, "followup_task", %{"target" => "/root/a", "message" => "new generation"})
    next = provider!(child.params.session_id)
    root = provider!("native-root")
    [after_row] = roster(c.host).agents
    assert after_row.agent_id == before.agent_id
    assert after_row.child_session_id == before.child_session_id
    assert after_row.run_id != before.run_id

    next =
      call!(next, "update_plan", %{
        "plan" => [%{"step" => "New resources", "status" => "completed"}]
      })

    refute result!(next, "update_plan").is_error
    next = call!(next, "exec_command", %{"cmd" => "printf fresh", "yield_time_ms" => 1_000})
    assert structured!(next, "exec_command")["output"] == "fresh"
    next = call!(next, "write_stdin", %{"session_id" => handle, "chars" => "stale\n"})
    assert result!(next, "write_stdin").is_error

    assert %{"error" => %{"class" => "not_found", "message" => "command session is unknown"}} =
             structured!(next, "write_stdin")

    next = call!(next, "exec_command", %{"cmd" => "printf continued", "yield_time_ms" => 1_000})
    assert structured!(next, "exec_command")["output"] == "continued"
    finish!(next)
    assert eventually(fn -> hd(roster(c.host).agents).status == :completed end)
    finish!(root)
    assert eventually(fn -> Sigma.Agent.status(c.agent).phase == :completed end)
    assert {:ok, %{status: :confirmed}} = Subagents.close(c.host)
  end

  @tag permission_config: %{default: :allow, rules: %{"apply_patch" => :ask}}
  test "child raw patch and real nested Plan persist without replay on followup", c do
    owner = self()

    opts =
      PublicRuntime.prompt_opts(
        %{
          permission_resolver: fn call ->
            send(owner, {:allowed_child_patch, call})
            :allow
          end
        },
        c.agent
      )

    root = prompt!(c.agent, opts)
    {child, root} = spawn!(root, "a")
    patch = "*** Begin Patch\n*** Add File: child-proof.txt\n+中文 \"raw\" {json}\n*** End Patch"
    child = call!(child, "apply_patch", patch)
    assert_receive {:allowed_child_patch, permission}, 5_000
    assert permission.source.agent_path == "/root/a"
    assert permission.arguments == patch
    refute result!(child, "apply_patch").is_error
    path = Path.join(c.dir, "child-proof.txt")
    assert File.read!(path) == "中文 \"raw\" {json}\n"

    assert is_binary(System.find_executable("deno"))

    child =
      call!(child, "exec", """
      return await tools.update_plan({plan: [{step: "Nested child plan", status: "completed"}]});
      """)

    assert %{"status" => "completed", "value" => %{"status" => "updated"}} =
             structured!(child, "exec")

    outer_result = result!(child, "exec")
    refute Map.has_key?(outer_result, :metadata)
    finish!(child)
    assert eventually(fn -> roster(c.host).counts.stopped == 1 end)
    [row] = roster(c.host).agents
    assert {:ok, saved} = Log.snapshot(child_path(c, row))
    publication = Enum.find(saved.messages, &(Map.get(&1, :tool_name) == "exec"))
    assert publication.metadata["structured_result"] == structured!(child, "exec")

    assert %{
             "source_tool" => "exec",
             "tool_call_id" => call_id,
             "plan" => [%{"step" => "Nested child plan", "status" => "completed"}]
           } =
             PlanProjection.latest(saved.messages)

    assert call_id == outer_result.tool_call_id

    assert Enum.any?(saved.messages, fn
             %{role: :assistant, content: content} when is_list(content) ->
               Enum.any?(content, &match?(%{name: "apply_patch", arguments: ^patch}, &1))

             _ ->
               false
           end)

    File.write!(path, "changed after the effect")
    before = File.stat!(path, time: :posix)
    send_call(root, "followup_task", %{"target" => "/root/a", "message" => "read history"})
    next = provider!(child.params.session_id)
    root = provider!("native-root")
    assert Enum.any?(next.params.context.messages, &(Map.get(&1, :tool_name) == "apply_patch"))
    assert File.read!(path) == "changed after the effect"
    assert File.stat!(path, time: :posix).mtime == before.mtime
    assert {:ok, restored} = Log.snapshot(child_path(c, row))
    assert PlanProjection.latest(restored.messages) == PlanProjection.latest(saved.messages)
    assert {:ok, root_saved} = Log.snapshot(c.path)
    assert PlanProjection.latest(root_saved.messages) == nil
    finish!(next)
    finish!(root)
  end

  test "child real nested Plan persists on followup without affecting the root Plan", c do
    assert is_binary(System.find_executable("deno"))
    root = prompt!(c.agent)
    {child, root} = spawn!(root, "a")

    child =
      call!(child, "exec", """
      return await tools.update_plan({plan: [{step: "Nested child plan", status: "completed"}]});
      """)

    assert %{"status" => "completed", "value" => %{"status" => "updated"}} =
             structured!(child, "exec")

    outer_result = result!(child, "exec")
    refute Map.has_key?(outer_result, :metadata)
    finish!(child)
    assert eventually(fn -> roster(c.host).counts.stopped == 1 end)
    [row] = roster(c.host).agents
    assert {:ok, saved} = Log.snapshot(child_path(c, row))
    publication = Enum.find(saved.messages, &(Map.get(&1, :tool_name) == "exec"))
    assert publication.metadata["structured_result"] == structured!(child, "exec")

    assert %{
             "source_tool" => "exec",
             "tool_call_id" => call_id,
             "plan" => [%{"step" => "Nested child plan", "status" => "completed"}]
           } = PlanProjection.latest(saved.messages)

    assert call_id == outer_result.tool_call_id
    send_call(root, "followup_task", %{"target" => "/root/a", "message" => "read plan history"})
    next = provider!(child.params.session_id)
    root = provider!("native-root")
    assert Enum.any?(next.params.context.messages, &(Map.get(&1, :tool_name) == "exec"))
    assert {:ok, restored} = Log.snapshot(child_path(c, row))
    assert PlanProjection.latest(restored.messages) == PlanProjection.latest(saved.messages)
    assert {:ok, root_saved} = Log.snapshot(c.path)
    assert PlanProjection.latest(root_saved.messages) == nil
    finish!(next)
    finish!(root)
  end

  @tag permission_config: %{default: :allow, rules: %{"exec_command" => :ask}}
  test "interrupt fences a pending child command permission and its late answer", c do
    opts = PublicRuntime.prompt_opts(%{interactive_approvals: true}, c.agent)
    root = prompt!(c.agent, opts)
    {child, root} = spawn!(root, "a")

    arguments = %{
      "cmd" => "printf approved > approved-child-command.txt",
      "yield_time_ms" => 1_000
    }

    path = Path.join(c.dir, "approved-child-command.txt")
    send_call(child, "exec_command", arguments)
    assert_receive {:ask_user_question, old_id, pending}, 5_000
    assert pending.kind == :permission
    assert pending.arguments == arguments
    assert pending.source.agent_path == "/root/a"
    refute File.exists?(path)

    root = call!(root, "interrupt_agent", %{"target" => "/root/a"})
    assert eventually(fn -> hd(roster(c.host).agents).status == :interrupted end)
    assert eventually(fn -> Subagents.pending(c.host) == [] end)

    assert {:error, :not_found} =
             Runtime.answer_question(c.dir, "native-root", c.agent, old_id, {:ok, "allow_once"})

    refute File.exists?(path)
    send_call(root, "followup_task", %{"target" => "/root/a", "message" => "try command again"})
    next = provider!(child.params.session_id)
    root = provider!("native-root")
    send_call(next, "exec_command", arguments)
    assert_receive {:ask_user_question, new_id, replacement}, 5_000
    assert new_id != old_id
    assert replacement.source.incarnation > pending.source.incarnation

    assert {:error, :not_found} =
             Runtime.answer_question(c.dir, "native-root", c.agent, old_id, {:ok, "allow_once"})

    refute File.exists?(path)
    assert [question] = Subagents.pending(c.host)
    assert question.id == new_id

    assert :ok =
             Runtime.answer_question(c.dir, "native-root", c.agent, new_id, {:ok, "allow_once"})

    next = provider!(child.params.session_id)
    refute result!(next, "exec_command").is_error
    assert File.read!(path) == "approved"
    finish!(next)
    finish!(root)
  end

  @tag permission_config: %{default: :allow, rules: %{"apply_patch" => :ask}}
  test "interrupt fences a pending native permission and its late answer from the next run", c do
    opts = PublicRuntime.prompt_opts(%{interactive_approvals: true}, c.agent)
    root = prompt!(c.agent, opts)
    {child, root} = spawn!(root, "a")
    patch = "*** Begin Patch\n*** Add File: cancelled-child.txt\n+approved\n*** End Patch"
    path = Path.join(c.dir, "cancelled-child.txt")
    send_call(child, "apply_patch", patch)
    assert_receive {:ask_user_question, old_id, pending}, 5_000
    assert pending.kind == :permission
    assert pending.arguments == patch
    assert pending.source.agent_path == "/root/a"
    refute File.exists?(path)

    root = call!(root, "interrupt_agent", %{"target" => "/root/a"})
    assert eventually(fn -> hd(roster(c.host).agents).status == :interrupted end)
    assert eventually(fn -> Subagents.pending(c.host) == [] end)

    assert {:error, :not_found} =
             Runtime.answer_question(c.dir, "native-root", c.agent, old_id, {:ok, "allow_once"})

    refute File.exists?(path)

    send_call(root, "followup_task", %{"target" => "/root/a", "message" => "try again"})
    next = provider!(child.params.session_id)
    root = provider!("native-root")
    send_call(next, "apply_patch", patch)
    assert_receive {:ask_user_question, new_id, replacement}, 5_000
    assert new_id != old_id
    assert replacement.source.incarnation > pending.source.incarnation

    assert {:error, :not_found} =
             Runtime.answer_question(c.dir, "native-root", c.agent, old_id, {:ok, "allow_once"})

    refute File.exists?(path)
    assert [question] = Subagents.pending(c.host)
    assert question.id == new_id

    assert :ok =
             Runtime.answer_question(c.dir, "native-root", c.agent, new_id, {:ok, "allow_once"})

    next = provider!(child.params.session_id)
    refute result!(next, "apply_patch").is_error
    assert File.read!(path) == "approved\n"
    finish!(next)
    finish!(root)
  end

  test "root close confirms cleanup of idle retained child command resources", c do
    root = prompt!(c.agent)
    {child, root} = spawn!(root, "a")
    pid_file = Path.join(c.dir, "idle-child.pid")

    child =
      call!(child, "exec_command", %{
        "cmd" => "printf '%s' \"$$\" > idle-child.pid; read value",
        "yield_time_ms" => 20
      })

    assert structured!(child, "exec_command")["status"] == "running"
    assert eventually(fn -> File.exists?(pid_file) end)
    os_pid = File.read!(pid_file) |> String.trim() |> String.to_integer()
    finish!(child)
    finish!(root)
    assert eventually(fn -> Sigma.Agent.status(c.agent).phase == :completed end)
    assert eventually(fn -> roster(c.host).counts.stopped == 1 end)
    assert File.exists?("/proc/#{os_pid}")
    {store, store_path} = child_store!(c, child.params.session_id)
    assert {:ok, %{hosts: hosts}} = Store.host_retirement(store, :all)
    [host] = Map.values(hosts)
    [binding] = Map.values(host.bindings)
    assert {:ok, root_saved} = Log.snapshot(c.path)

    assert {:ok, child_saved} =
             Log.snapshot(Path.dirname(store_path) |> Path.join("session.jsonl"))

    assert binding.root_header_id == root_saved.session_id
    assert binding.transcript_header_id == child_saved.session_id
    assert binding.child_session_id == child.params.session_id

    assert {:ok, %{status: :unconfirmed, native: nil, async_hooks: nil}} =
             Store.host_retirement(store, binding)

    assert {:ok, original_run} = Store.load(store, binding.run_id)
    assert {:ok, %{status: :confirmed}} = Subagents.close(c.host)
    assert eventually(fn -> not File.exists?("/proc/#{os_pid}") end)
    refute Process.alive?(store)
    reopened = start_supervised!({Store, path: store_path}, id: :retired_idle_store)
    assert {:ok, %{status: :confirmed}} = Store.host_retirement(reopened, binding)
    assert {:ok, ^original_run} = Store.load(reopened, binding.run_id)
    receipt_path = Path.join(store_path, "host-retirement.etf")
    bytes = File.read!(receipt_path)
    assert {:ok, %{status: :confirmed}} = Subagents.close(c.host)
    assert File.read!(receipt_path) == bytes
  end

  test "a transient child retirement write failure recovers production close and the next generation",
       c do
    root = prompt!(c.agent)
    {child, root} = spawn!(root, "retry_child")
    finish!(child)
    finish!(root)
    assert eventually(fn -> Sigma.Agent.status(c.agent).phase == :completed end)
    assert eventually(fn -> roster(c.host).counts.stopped == 1 end)
    {store, store_path} = child_store!(c, child.params.session_id)
    assert {:ok, %{hosts: hosts}} = Store.host_retirement(store, :all)
    [host] = Map.values(hosts)
    [binding] = Map.values(host.bindings)
    assert {:ok, original_run} = Store.load(store, binding.run_id)

    assert {:ok, %{status: :unconfirmed, native: nil, async_hooks: nil}} =
             Store.host_retirement(store, binding)

    receipt_path = Path.join(store_path, "host-retirement.etf")
    original_bytes = File.read!(receipt_path)
    backup = receipt_path <> ".retry-saved"
    recovery = Sigma.Agent.Backplane.LifetimeRecovery.locate(c.path)
    assert is_pid(recovery)
    File.rename!(receipt_path, backup)
    File.mkdir!(receipt_path)

    try do
      assert {:error,
              %Backplane.AgentRuntime.Error{
                class: :unknown_outcome,
                cause: %{generation: generation, child_retirements: failed}
              }} =
               Subagents.close(c.host)

      assert {:error,
              %Backplane.AgentRuntime.Error{
                class: :unknown_outcome,
                message: "child host retirement requires reconciliation",
                cause: ^failed
              }} = generation

      assert [
               {_child_id,
                {:error,
                 %Backplane.AgentRuntime.Error{
                   class: :execution_failure,
                   cause: :eisdir
                 }}}
             ] = Map.to_list(failed)

      assert {:ok, %{available: false}} = Subagents.snapshot(c.host)
      assert {:error, :subagent_resources_active} = Subagents.can_stop(c.host)
      assert Process.alive?(store)
      assert Process.alive?(recovery)

      assert {:error, %Backplane.AgentRuntime.Error{cause: :eisdir}} =
               Store.host_retirement(store, binding)

      assert File.read!(backup) === original_bytes
    after
      File.rmdir!(receipt_path)
      File.rename!(backup, receipt_path)
    end

    assert File.read!(receipt_path) === original_bytes

    assert {:ok, %{status: :unconfirmed, native: nil, async_hooks: nil}} =
             Store.host_retirement(store, binding)

    assert {:ok, %{status: :confirmed}} = Subagents.close(c.host)
    assert {:ok, %{available: true}} = Subagents.snapshot(c.host)
    assert :ok = Subagents.can_stop(c.host)
    refute Process.alive?(store)
    refute Process.alive?(recovery)
    reopened = start_supervised!({Store, path: store_path}, id: :retry_retired_child_store)
    assert {:ok, %{status: :confirmed}} = Store.host_retirement(reopened, binding)
    assert {:ok, ^original_run} = Store.load(reopened, binding.run_id)

    next_root = prompt!(c.agent)
    assert next_root.params.turn_id != root.params.turn_id
    assert {:ok, %{children: []}} = Subagents.archive_sources(c.host)
    {next_child, next_root} = spawn!(next_root, "fresh_child")
    refute next_child.params.session_id == child.params.session_id
    finish!(next_child)
    finish!(next_root)
    assert eventually(fn -> Sigma.Agent.status(c.agent).phase == :completed end)
    assert eventually(fn -> roster(c.host).counts.stopped == 2 end)
  end

  defp child_store!(c, session_id) do
    assert {:ok, %{children: children}} = Subagents.archive_sources(c.host)
    child = Enum.find(children, &(&1.identity.child_session_id == session_id))
    assert child
    assert {:ok, store} = ChildIO.store(child.io)
    {store, Path.join([c.path <> ".subagents", session_id, "runtime"])}
  end

  defp prompt!(agent, opts \\ []) do
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "delegate", opts)
    provider!("native-root")
  end

  defp spawn!(root, name) do
    send_call(root, "spawn_agent", %{
      "task_name" => name,
      "message" => "work",
      "fork_turns" => "none"
    })

    child = provider!(:child)
    root = provider!("native-root")
    refute result!(root, "spawn_agent").is_error
    {child, root}
  end

  defp provider!(session) do
    receive do
      {:native_provider, pid, %{session_id: "child_" <> _} = params} when session == :child ->
        %{pid: pid, params: params}

      {:native_provider, pid, %{session_id: id} = params}
      when id == session ->
        %{pid: pid, params: params}

      {:turn_error, error} ->
        flunk("root failed: #{inspect(error)}")
    after
      5_000 -> flunk("provider did not start for #{session}")
    end
  end

  defp call!(provider, name, arguments) do
    send_call(provider, name, arguments)
    provider!(provider.params.session_id)
  end

  defp send_call(provider, name, arguments) do
    send(
      provider.pid,
      {:native_response,
       [
         %{
           type: :tool_call,
           id: "child-#{System.unique_integer([:positive])}",
           name: name,
           arguments: arguments,
           input_kind: if(is_binary(arguments), do: :custom, else: :function)
         }
       ]}
    )
  end

  defp result!(provider, name) do
    Enum.find(Enum.reverse(provider.params.context.messages), &(Map.get(&1, :tool_name) == name)) ||
      flunk("missing #{name} result")
  end

  defp structured!(provider, name) do
    assert [%{type: :text, text: json}] = result!(provider, name).content
    Jason.decode!(json)
  end

  defp assert_uncertain_handle_refusal(host, session_id) do
    assert eventually(fn ->
             row = Enum.find(roster(host).agents, &(&1.child_session_id == session_id))
             row.status == :unknown_outcome and row.closure == :unknown
           end)

    row = Enum.find(roster(host).agents, &(&1.child_session_id == session_id))
    assert row.reason == "cleanup_unconfirmed"
    assert {:error, :subagent_resources_active} = Subagents.can_stop(host)
    refute_receive {:native_provider, _, %{session_id: ^session_id}}, 50
  end

  defp finish!(provider),
    do: send(provider.pid, {:native_response, [%{type: :text, text: "done"}]})

  defp child_path(c, row),
    do: Path.join([c.path <> ".subagents", row.child_session_id, "session.jsonl"])

  defp roster(host) do
    assert {:ok, %{available: true, subagents: roster}} = Subagents.snapshot(host)
    roster
  end

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
