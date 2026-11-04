defmodule Sigma.Agent.BackplaneNativeProductionTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Plan
  alias Sigma.Agent.{Runtime, Subagents}
  alias Sigma.Agent.Backplane.CodexResources
  alias Sigma.Agent.Backplane.Store
  alias Sigma.Coding.Hooks.Discovery

  @moduletag :tmp_dir
  @native ~w(
    exec_command write_stdin apply_patch update_plan view_image clock::curr_time clock::sleep
    exec wait request_user_input request_user_input_async send_message_to_user_async
    get_context_remaining new_context wait_for_environment skills::list skills::read
    memories::add_ad_hoc_note memories::list memories::read memories::search
    history::list_windows history::list_items history::read_item history::search_contents
    notes::list_files_by_prefix notes::read_file notes::search_contents notes::append_to_file
    notes::write_file get_goal create_goal update_goal collaboration::create_channel
    collaboration::get_channels collaboration::list_threads collaboration::search_posts
    collaboration::read_thread collaboration::read_post collaboration::subscribe
    collaboration::unsubscribe collaboration::post
  )

  defmodule UnreadablePlanStorage do
    defdelegate append(path, entry), to: Sigma.Session.Storage.JsonlFile
    def read(_path), do: {:error, :eacces}
    def read_with_diagnostics(_path), do: {:error, :eacces}
  end

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

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

  setup %{tmp_dir: dir} do
    on_exit(fn ->
      case Runtime.lookup(dir, :supervisor) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
      end
    end)

    {:ok, dir: dir}
  end

  test "root catalog includes the published apply_patch contract",
       ctx do
    agent = session!(ctx.dir)
    prompt!(agent, "catalog with published patch")
    {provider, params} = provider!()
    assert Enum.any?(params.context.tools, &(&1.name == "apply_patch"))
    finish!(agent, provider)
  end

  test "an admitted root raw patch creates its file", ctx do
    agent = session!(ctx.dir)
    prompt!(agent, "create a file with a raw patch")
    {provider, _} = provider!()
    patch = "*** Begin Patch\n*** Add File: root-patch.txt\n+created once\n*** End Patch"
    provider = call!(provider, "apply_patch", patch)
    result = last_result!(agent)
    refute result.is_error
    assert result.metadata.structured_result["status"] == "applied"
    assert File.read!(Path.join(ctx.dir, "root-patch.txt")) == "created once\n"
    finish!(agent, provider)
  end

  test "real Deno root dispatch applies a raw patch", ctx do
    assert is_binary(System.find_executable("deno"))
    agent = session!(ctx.dir)
    prompt!(agent, "nested raw patch")
    {provider, _} = provider!()
    patch = "*** Begin Patch\n*** Add File: root-deno-patch.txt\n+created once\n*** End Patch"

    provider =
      call!(provider, "exec", """
      const names = ALL_TOOLS.map(tool => tool.tool_name);
      const result = await tools.apply_patch(#{Jason.encode!(patch)});
      return {result, names};
      """)

    assert %{
             "status" => "completed",
             "value" => %{"result" => %{"status" => "applied"}, "names" => names}
           } =
             last_result!(agent).metadata.structured_result

    assert "apply_patch" in names
    assert File.read!(Path.join(ctx.dir, "root-deno-patch.txt")) == "created once\n"
    finish!(agent, provider)
  end

  test "explicit native apply_patch selection builds its public profile", ctx do
    authority = %{
      caller: "native",
      run_id: "blocked-patch",
      grants: ["apply_patch"],
      tool_revision: 1
    }

    resources =
      start_supervised!(
        {CodexResources,
         workspace: ctx.dir, owner_pid: self(), memory_root: Path.join(ctx.dir, "memories")}
      )

    assert {:ok, binding} = CodexResources.bind(resources, authority)
    assert {:ok, context} = CodexResources.context(resources, binding)

    assert {:ok, profile} =
             Sigma.Agent.Backplane.NativeTools.profile(context, authority, %{hook_specs: []},
               tools: ["apply_patch"]
             )

    assert Map.has_key?(profile.registry.tools, "apply_patch")
  end

  test "Runtime admits the complete native profile alongside MCP and collaboration", ctx do
    mcp = %Sigma.Coding.MCP.Tool{
      name: "mcp__fixture__echo",
      description: "A configured MCP declaration",
      schema: %{"type" => "object", "properties" => %{}},
      server_id: "fixture",
      server_tool_name: "echo"
    }

    agent = session!(ctx.dir, tools: [mcp])
    prompt!(agent, "catalog")
    {provider, params} = provider!()

    assert Enum.sort(Enum.map(params.context.tools, & &1.name)) ==
             Enum.sort(@native ++ Subagents.collaboration_tools() ++ [mcp.name])

    assert Enum.any?(params.context.tools, &(&1.name == "apply_patch"))
    finish!(agent, provider)
  end

  test "a native session without connected MCP clients omits resource tools", ctx do
    agent = session!(ctx.dir)
    assert :sys.get_state(agent).mcp_session.clients == %{}
    prompt!(agent, "core catalog")
    {provider, params} = provider!()
    names = Enum.map(params.context.tools, & &1.name)

    for name <- ~w(list_mcp_resources list_mcp_resource_templates read_mcp_resource) do
      refute name in names
    end

    assert Enum.sort(names -- Subagents.collaboration_tools()) == Enum.sort(@native)

    finish!(agent, provider)
  end

  test "a guessed resource call without connected MCP clients cannot execute", ctx do
    agent = session!(ctx.dir)
    prompt!(agent, "guessed resource")
    {provider, _} = provider!()
    provider = call!(provider, "list_mcp_resources", %{})
    result = last_result!(agent)

    assert result.is_error
    assert result.metadata.structured_result["error"]["class"] == "not_found"
    finish!(agent, provider)
  end

  test "explicit resource selection fails when its trusted client context is missing" do
    name = "list_mcp_resources"
    authority = %{caller: "native", run_id: "missing-mcp", grants: [name], tool_revision: 1}

    assert {:error, %Backplane.AgentRuntime.Error{class: :validation}} =
             Sigma.Agent.Backplane.NativeTools.profile(%{}, authority, %{hook_specs: []},
               tools: [name]
             )
  end

  test "native Plan and retained command handles survive successful root turns", ctx do
    agent = session!(ctx.dir)
    prompt!(agent, "plan and command effects")
    {provider, _} = provider!()

    provider =
      call!(provider, "update_plan", %{"plan" => [%{"step" => "Native", "status" => "completed"}]})

    host = Runtime.lookup(ctx.dir, "native", :subagents)
    resources = :sys.get_state(host).codex_resources
    session = CodexResources.session(resources)
    binding = :sys.get_state(resources).binding
    assert {:ok, context} = CodexResources.context(resources, binding)
    assert {:ok, %{revision: 2}} = Plan.read(context.plan)

    provider =
      call!(provider, "exec_command", %{
        "cmd" => "read value; printf '%s' \"$value\"",
        "yield_time_ms" => 20
      })

    command = last_result!(agent).metadata.structured_result
    assert command["status"] == "running"
    handle = command["session_id"]
    assert is_integer(handle)
    finish!(agent, provider)

    prompt!(agent, "resume retained command")
    {provider, params} = provider!()
    assert :sys.get_state(host).codex_resources == resources
    assert CodexResources.session(resources) == session
    assert Enum.any?(params.context.messages, &(Map.get(&1, :tool_name) == "update_plan"))

    assert {:ok, %{content: %{"plan" => [%{"step" => "Native", "status" => "completed"}]}}} =
             Plan.read(context.plan)

    provider =
      call!(provider, "write_stdin", %{
        "session_id" => handle,
        "chars" => "hello\n",
        "yield_time_ms" => 1_000
      })

    result = last_result!(agent).metadata.structured_result
    assert result["exit_code"] == 0
    assert result["output"] =~ "hello"
    finish!(agent, provider)
  end

  test "real native Plan, raw patch and command handles survive successful root turns", ctx do
    agent = session!(ctx.dir)
    prompt!(agent, "effects")
    {provider, _} = provider!()

    provider =
      call!(provider, "update_plan", %{"plan" => [%{"step" => "Native", "status" => "completed"}]})

    host = Runtime.lookup(ctx.dir, "native", :subagents)
    resources = :sys.get_state(host).codex_resources
    session = CodexResources.session(resources)
    binding = :sys.get_state(resources).binding
    assert {:ok, context} = CodexResources.context(resources, binding)
    assert {:ok, %{revision: 2}} = Plan.read(context.plan)

    patch = "*** Begin Patch\n*** Add File: native.txt\n+native\n*** End Patch"
    provider = call!(provider, "apply_patch", patch)
    assert File.read!(Path.join(ctx.dir, "native.txt")) == "native\n"

    provider =
      call!(provider, "exec_command", %{
        "cmd" => "read value; printf '%s' \"$value\"",
        "yield_time_ms" => 20
      })

    command = last_result!(agent).metadata.structured_result
    assert command["status"] == "running"
    handle = command["session_id"]
    assert is_integer(handle)
    finish!(agent, provider)

    prompt!(agent, "resume")
    {provider, params} = provider!()
    assert :sys.get_state(host).codex_resources == resources
    assert CodexResources.session(resources) == session

    assert Enum.any?(params.context.messages, fn message ->
             Enum.any?(
               List.wrap(message.content),
               &match?(%{type: :tool_call, arguments: ^patch}, &1)
             )
           end)

    provider =
      call!(provider, "write_stdin", %{
        "session_id" => handle,
        "chars" => "hello\n",
        "yield_time_ms" => 1_000
      })

    result = last_result!(agent).metadata.structured_result
    assert result["exit_code"] == 0
    assert result["output"] =~ "hello"
    finish!(agent, provider)
  end

  # TODO(upstream): gsmlg-opt/backplane#95
  @tag skip: "sandbox production activation awaits trusted LocalCommand bootstrap (#95)"
  test "default commands and Code Mode enforce workspace, home and network isolation", ctx do
    outside =
      Path.join(Path.dirname(ctx.dir), "sandbox-secret-#{System.unique_integer([:positive])}")

    File.write!(outside, "host-only")
    on_exit(fn -> File.rm(outside) end)

    script = """
    import errno, json, os, socket, sys
    try:
        socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        network = "allowed"
    except OSError as error:
        network = error.errno
    try:
        fd = os.open(sys.executable, os.O_WRONLY)
        os.close(fd)
        runtime_readonly = False
    except OSError:
        runtime_readonly = True
    with open("sandbox-effect", "w") as output:
        output.write("workspace")
    print(json.dumps({"home": os.environ.get("HOME"), "outside": os.path.exists(#{Jason.encode!(outside)}), "network": network, "runtime_readonly": runtime_readonly}))
    """

    command = "python3 -c '" <> String.replace(script, "'", "'\"'\"'") <> "'"
    arguments = %{"cmd" => command, "login" => false, "yield_time_ms" => 1_000}
    agent = session!(ctx.dir)
    prompt!(agent, "Verify the default command policy")
    {provider, _} = provider!()
    provider = call!(provider, "exec_command", arguments)
    direct = last_result!(agent).metadata.structured_result
    assert direct["exit_code"] == 0

    expected = %{
      "home" => "/home/sigma",
      "outside" => false,
      "network" => 1,
      "runtime_readonly" => true
    }

    assert Jason.decode!(direct["output"]) == expected
    assert File.read!(Path.join(ctx.dir, "sandbox-effect")) == "workspace"

    provider =
      call!(provider, "exec", "return await tools.exec_command(#{Jason.encode!(arguments)});")

    nested = last_result!(agent).metadata.structured_result
    assert nested["status"] == "completed"
    assert nested["value"]["exit_code"] == 0
    assert Jason.decode!(nested["value"]["output"]) == expected
    finish!(agent, provider)
  end

  test "root user input resolves through the existing question API and cancellation retires resources",
       ctx do
    agent = session!(ctx.dir)
    prompt!(agent, "ask")
    {provider, _} = provider!()

    question = %{
      "id" => "choice",
      "header" => "Choice",
      "question" => "Choose?",
      "options" => [
        %{"label" => "A", "description" => "First"},
        %{"label" => "B", "description" => "Second"}
      ]
    }

    send_call(provider, "request_user_input", %{"questions" => [question]})
    assert_receive {:ask_user_question, question_id, pending}, 5_000
    assert pending.question == "[Choice] Choose?"
    assert :ok = Sigma.Agent.answer_user_question(agent, question_id, {:ok, "B"})
    {provider, _} = provider!()
    assert last_result!(agent).metadata.structured_result["answers"]["choice"]["answers"] == ["B"]
    finish!(agent, provider)

    prompt!(agent, "cancel")
    {provider, _} = provider!()
    host = Runtime.lookup(ctx.dir, "native", :subagents)
    resources = :sys.get_state(host).codex_resources
    session = CodexResources.session(resources)
    monitor = Process.monitor(session)
    send_call(provider, "clock::sleep", %{"duration_ms" => 60_000})
    assert_receive {:tool_execution_start, _, "clock::sleep", _}, 5_000
    assert {:cancelling, _turn_id} = Sigma.Agent.cancel(agent)
    assert_receive {:turn_cancelled}, 5_000
    assert %{phase: :closed} = Backplane.AgentRuntime.Codex.Session.status(session)

    prompt!(agent, "fresh")
    {provider, _} = provider!()
    assert_receive {:DOWN, ^monitor, :process, ^session, _}, 5_000
    refute :sys.get_state(host).codex_resources == resources
    finish!(agent, provider)
  end

  test "native hooks prepare committed input once and preserve feedback across turns and JSONL",
       ctx do
    pre_input = Path.join(ctx.dir, "pre-input.json")
    post_input = Path.join(ctx.dir, "post-input.json")
    post_release = Path.join(ctx.dir, "post-release")
    replacement = %{"plan" => [%{"step" => "Prepared", "status" => "completed"}]}
    final = Map.put(replacement, "explanation", "approved")

    specs =
      hook_specs(%{
        "PreToolUse" =>
          {"update_plan", pre_input,
           %{
             "permissionDecision" => "allow",
             "updatedInput" => replacement,
             "additionalContext" => "before native"
           }, ""},
        "PostToolUse" =>
          {"update_plan", post_input, %{"additionalContext" => "after native"},
           "while ! test -f " <> shell_quote(post_release) <> "; do sleep 0.01; done; "}
      })

    test = self()

    agent =
      session!(ctx.dir,
        hook_specs: specs,
        permission_config: %{default: :ask, rules: %{}},
        dispatcher_opts: [
          permission_request_fn: fn call ->
            send(test, {:native_permission, call})
            {:allow, %{"explanation" => "approved"}}
          end,
          runtime_permission_request_fn: fn _, _ ->
            flunk("Sigma policy is separate from Runtime approval")
          end
        ]
      )

    assert {:accepted, %{turn_id: turn_id}} = Sigma.Agent.prompt(agent, "prepare")
    {provider, _} = provider!()

    send_call(provider, "update_plan", %{
      "plan" => [%{"step" => "Original", "status" => "pending"}],
      "explanation" => "replace me"
    })

    assert_receive {:native_permission, %{arguments: ^replacement}}, 5_000

    assert eventually(fn ->
             case File.read(post_input) do
               {:ok, json} -> match?({:ok, %{}}, Jason.decode(json))
               _ -> false
             end
           end)

    store = :sys.get_state(agent).backplane_store
    assert {:ok, %{run: run}} = Store.load(store, turn_id)
    assert [invocation] = Map.values(run.active_tools)
    assert invocation.arguments == final
    assert File.read!(post_input) |> Jason.decode!() |> get_in(["tool_input"]) == final
    File.write!(post_release, "continue")
    {provider, params} = provider!()
    assert provider_feedback_texts(params.context.messages) == ["before native", "after native"]
    finish!(agent, provider)
    assert length(File.read!(pre_input) |> String.split("\n", trim: true)) == 1
    assert length(File.read!(post_input) |> String.split("\n", trim: true)) == 1
    prompt!(agent, "another turn")
    {provider, params} = provider!()
    assert provider_feedback_texts(params.context.messages) == ["before native", "after native"]
    finish!(agent, provider)
    assert {:ok, snapshot} = Sigma.Session.Log.snapshot(Path.join(ctx.dir, "native.jsonl"))

    assert %{
             "plan" => [%{"step" => "Prepared", "status" => "completed"}],
             "explanation" => "approved"
           } =
             Sigma.Agent.Backplane.PlanProjection.latest(snapshot.messages)

    assert feedback_texts(snapshot.messages) == ["before native", "after native"]
    assert Enum.map(feedback_messages(snapshot.messages), & &1.id) |> Enum.uniq() |> length() == 2
    refute_receive {:native_permission, _}, 0
  end

  test "stopped post hook feedback is journaled once and retained in the next Engine turn", ctx do
    input = Path.join(ctx.dir, "stopped-hook-input.jsonl")
    reason = "review the completed plan"

    specs =
      hook_specs(
        %{"PostToolUse" => {"update_plan", input, %{"additionalContext" => "after native"}, ""}},
        %{"continue" => false, "stopReason" => reason}
      )

    agent = session!(ctx.dir, hook_specs: specs)
    prompt!(agent, "plan with stopped hook")
    {provider, _} = provider!()

    send_call(provider, "update_plan", %{"plan" => [%{"step" => "Once", "status" => "completed"}]})

    {provider, params} = provider!()
    expected = ["after native"]
    assert provider_feedback_texts(params.context.messages) == expected

    presented =
      Enum.find(Enum.reverse(params.context.messages), &(Map.get(&1, :role) == :tool_result))

    assert presented.content == [%{type: :text, text: reason}]
    refute presented.is_error
    assert last_result!(agent).metadata.structured_result["stopped"] == true
    refute last_result!(agent).is_error
    finish!(agent, provider)

    assert {:ok, snapshot} = Sigma.Session.Log.snapshot(Path.join(ctx.dir, "native.jsonl"))
    assert feedback_texts(snapshot.messages) == expected
    assert [%{id: feedback_id}] = feedback_messages(snapshot.messages)

    assert %{"plan" => [%{"step" => "Once", "status" => "completed"}]} =
             Sigma.Agent.Backplane.PlanProjection.latest(snapshot.messages)

    prompt!(agent, "next actual turn")
    {provider, params} = provider!()
    assert provider_feedback_texts(params.context.messages) == expected

    assert Enum.find(
             params.context.messages,
             &(Map.get(&1, :tool_call_id) == presented.tool_call_id)
           ).content == presented.content

    finish!(agent, provider)
    assert {:ok, reloaded} = Sigma.Session.Log.snapshot(Path.join(ctx.dir, "native.jsonl"))
    assert [%{id: ^feedback_id}] = feedback_messages(reloaded.messages)
    assert length(File.read!(input) |> String.split("\n", trim: true)) == 1
    refute_receive {:turn_cancelled}, 0
    refute_receive {:turn_failed, _}, 0
  end

  test "actual nested Plan state is published, restored on retry, and retained across turns",
       ctx do
    alias Sigma.Agent.Backplane.PlanProjection
    alias Sigma.Session.Writer

    agent = session!(ctx.dir)
    prompt!(agent, "direct plan")
    {provider, _} = provider!()

    provider =
      call!(provider, "update_plan", %{"plan" => [%{"step" => "Selected", "status" => "pending"}]})

    first = PlanProjection.latest(Sigma.Agent.messages(agent))
    assert first["source_tool"] == "update_plan"
    finish!(agent, provider)
    writer = Runtime.lookup(ctx.dir, "native", :writer)
    assert {:ok, %{active_leaf_id: selected_leaf}} = Writer.flush(writer)

    prompt!(agent, "nested sibling plan")
    {provider, _} = provider!()

    provider =
      call!(
        provider,
        "exec",
        "return await tools.update_plan({plan: [{step: 'Nested sibling', status: 'completed'}]});"
      )

    sibling = PlanProjection.latest(Sigma.Agent.messages(agent))
    assert sibling["plan"] == [%{"step" => "Nested sibling", "status" => "completed"}]
    assert sibling["source_tool"] == "exec"
    assert sibling["tool_call_id"] == last_result!(agent).tool_call_id
    finish!(agent, provider)
    assert {:ok, %{active_leaf_id: sibling_leaf}} = Writer.flush(writer)
    assert :ok = Writer.checkout(writer, selected_leaf, sibling_leaf)

    prompt!(agent, "selected retry")
    {provider, _} = provider!()
    host = Runtime.lookup(ctx.dir, "native", :subagents)
    resources = :sys.get_state(host).codex_resources
    binding = :sys.get_state(resources).binding
    assert {:ok, context} = CodexResources.context(resources, binding)

    assert {:ok, %{content: %{"plan" => [%{"step" => "Selected", "status" => "pending"}]}}} =
             Plan.read(context.plan)

    provider = call!(provider, "clock::curr_time", %{})
    refute Map.has_key?(last_result!(agent).metadata, :native_plan)
    finish!(agent, provider)
    assert {:ok, selected} = Writer.selected_journal(writer)

    assert {:ok, restored} =
             PlanProjection.latest_entries(selected.entries, leaf_id: selected.leaf_id)

    assert restored["plan"] == first["plan"]
  end

  test "unreadable selected journal refuses plan hydration before provider execution", ctx do
    agent = session!(ctx.dir)
    writer = Runtime.lookup(ctx.dir, "native", :writer)
    original = :sys.get_state(writer).storage_mod
    :sys.replace_state(writer, &%{&1 | storage_mod: UnreadablePlanStorage})

    try do
      prompt!(agent, "unreadable plan state")
      assert eventually(fn -> Sigma.Agent.status(agent).phase == :failed end)
      refute_receive {:native_provider, _, _}, 0
    after
      :sys.replace_state(writer, &%{&1 | storage_mod: original})
    end
  end

  test "accepted feedback survives cancellation without another provider request", ctx do
    specs =
      hook_specs(%{
        "PreToolUse" =>
          {"clock::sleep", Path.join(ctx.dir, "cancel-input.json"),
           %{"additionalContext" => "cancel feedback"}, ""}
      })

    agent = session!(ctx.dir, hook_specs: specs)
    prompt!(agent, "cancel feedback")
    {provider, _} = provider!()
    send_call(provider, "clock::sleep", %{"duration_ms" => 60_000})
    assert_receive {:tool_execution_start, _, "clock::sleep", _}, 5_000
    assert {:cancelling, _} = Sigma.Agent.cancel(agent)
    assert_receive {:agent_end, messages}, 5_000
    assert feedback_texts(messages) == ["cancel feedback"]
    assert {:ok, snapshot} = Sigma.Session.Log.snapshot(Path.join(ctx.dir, "native.jsonl"))
    assert feedback_texts(snapshot.messages) == ["cancel feedback"]
    refute_receive {:native_provider, _, _}, 0
  end

  test "session stop releases command, plan and Session infrastructure", ctx do
    agent = session!(ctx.dir)
    prompt!(agent, "retain command")
    {provider, _} = provider!()

    provider =
      call!(provider, "exec_command", %{
        "cmd" => "read value",
        "shell" => "/bin/sh",
        "login" => false,
        "yield_time_ms" => 0
      })

    finish!(agent, provider)
    host = Runtime.lookup(ctx.dir, "native", :subagents)
    resources = :sys.get_state(host).codex_resources
    owned = :sys.get_state(resources)

    pids = [
      resources,
      owned.session,
      owned.command.server,
      owned.plan,
      owned.dynamic_runtime,
      owned.binding.resource_registry
    ]

    monitors = Enum.map(pids, &{&1, Process.monitor(&1)})
    supervisor = Runtime.lookup(ctx.dir, "native", :supervisor)
    assert :ok = DynamicSupervisor.terminate_child(Runtime.lookup(ctx.dir, :sessions), supervisor)

    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
    end
  end

  for lost <- [:resource_owner, :plan] do
    test "#{lost} loss fences native admission and cleans a retained actual command", ctx do
      agent = session!(ctx.dir)
      prompt!(agent, "retain command before failure")
      {provider, _} = provider!()
      pid_path = Path.join(ctx.dir, "retained-command.pid")

      provider =
        call!(provider, "exec_command", %{
          "cmd" => "printf '%s' \"$$\" > " <> shell_quote(pid_path) <> "; IFS= read -r value",
          "shell" => "/bin/sh",
          "login" => false,
          "yield_time_ms" => 0
        })

      assert last_result!(agent).metadata.structured_result["status"] == "running"
      retained_result = last_result!(agent)
      assert eventually(fn -> File.exists?(pid_path) end)
      os_pid = pid_path |> File.read!() |> String.trim()
      assert File.exists?("/proc/#{os_pid}")
      finish!(agent, provider)
      host = Runtime.lookup(ctx.dir, "native", :subagents)
      resources = :sys.get_state(host).codex_resources
      owned = :sys.get_state(resources)

      # Keep teardown safe while the RED implementation lacks owner-loss cleanup.
      on_exit(fn ->
        if Process.alive?(owned.session),
          do: Backplane.AgentRuntime.Codex.Session.close(owned.session)

        for pid <- [owned.command.server, owned.plan, owned.dynamic_runtime] do
          if Process.alive?(pid), do: GenServer.stop(pid, :normal)
        end
      end)

      resource_monitor = Process.monitor(resources)
      target = resource_failure_target(unquote(lost), resources, owned)
      Process.exit(target, :kill)
      assert_receive {:DOWN, ^resource_monitor, :process, ^resources, _}, 5_000
      assert eventually(fn -> match?({:ok, %{available: false}}, Subagents.snapshot(host)) end)
      assert {:error, :subagent_resources_active} = Subagents.can_stop(host)
      assert eventually(fn -> not File.exists?("/proc/#{os_pid}") end)
      assert eventually(fn -> not Process.alive?(owned.command.server) end)
      assert eventually(fn -> not Process.alive?(owned.session) end)

      {:accepted, %{turn_id: failed_turn}} =
        prompt!(agent, "must not execute after resource loss")

      assert_receive {:turn_error, _}, 5_000
      assert_receive {:turn_failed, ^failed_turn}, 5_000
      refute_receive {:native_provider, _, _}, 0
      assert Sigma.Agent.status(agent).phase == :failed
      assert last_result!(agent) == retained_result
      assert {:error, _} = Subagents.close(host)
    end
  end

  test "an incompatible real Provider refuses native tools before HTTP", ctx do
    agent =
      session!(ctx.dir,
        provider: Sigma.Ai.Providers.OpenAI,
        options: [base_url: "http://127.0.0.1:1", api_key: "test"]
      )

    prompt!(agent, "unsupported")
    assert_receive {:turn_error, error}, 5_000
    assert error.message =~ "does not support native custom tools"
    assert_receive {:agent_end, _}, 5_000
    assert Sigma.Agent.status(agent).phase == :failed
  end

  defp session!(dir, opts \\ []) do
    defaults = [
      cwd: dir,
      transcript_path: Path.join(dir, "native.jsonl"),
      provider: Provider,
      model: %{id: "test", provider: "test", api: "openai-responses"},
      native_tools: true,
      tools: [],
      hook_specs: [],
      options: [test_pid: self()]
    ]

    assert {:ok, handle} = Runtime.get_session(dir, "native", Keyword.merge(defaults, opts))
    :ok = Sigma.Agent.subscribe(handle.agent)
    handle.agent
  end

  defp prompt!(agent, text), do: assert({:accepted, _} = Sigma.Agent.prompt(agent, text))

  defp provider! do
    assert_receive {:native_provider, pid, params}, 8_000
    {pid, params}
  end

  defp send_call(provider, name, arguments) do
    kind = if is_binary(arguments), do: :custom, else: :function

    send(
      provider,
      {:native_response,
       [
         %{
           type: :tool_call,
           id: "native-#{System.unique_integer([:positive])}",
           name: name,
           arguments: arguments,
           input_kind: kind
         }
       ]}
    )
  end

  defp call!(provider, name, arguments) do
    send_call(provider, name, arguments)
    {provider, _} = provider!()
    provider
  end

  defp last_result!(agent) do
    :sys.get_state(agent).messages |> Enum.reverse() |> Enum.find(&(&1.role == :tool_result))
  end

  defp finish!(_agent, provider) do
    send(provider, {:native_response, [%{type: :text, text: "done"}]})
    assert_receive {:agent_end, _}, 5_000
  end

  defp feedback_messages(messages) do
    Enum.filter(messages, fn message ->
      metadata = Map.get(message, :metadata, %{})
      Map.has_key?(metadata, :host_feedback) or Map.has_key?(metadata, "host_feedback")
    end)
  end

  defp provider_feedback_texts(messages) do
    for %{role: :user, content: content} <- messages,
        block <- List.wrap(content),
        text = if(is_map(block), do: Map.get(block, :text), else: block),
        is_binary(text),
        String.starts_with?(text, "[Host feedback] ") do
      [_header, feedback] = String.split(text, "\n", parts: 2)
      feedback
    end
  end

  defp feedback_texts(messages) do
    Enum.map(feedback_messages(messages), fn message ->
      feedback = message.metadata[:host_feedback] || message.metadata["host_feedback"]
      feedback["text"] || feedback[:text]
    end)
  end

  defp hook_specs(events, controls \\ %{}) do
    hooks =
      Map.new(events, fn {event, {matcher, path, output, gate}} ->
        response =
          controls
          |> Map.put("hookSpecificOutput", Map.put(output, "hookEventName", event))
          |> Jason.encode!()

        command =
          "cat >> " <>
            shell_quote(path) <>
            "; printf '\\n' >> " <>
            shell_quote(path) <> "; " <> gate <> "printf '%s' " <> shell_quote(response)

        {event,
         [
           %{
             "matcher" => matcher,
             "hooks" => [%{"type" => "command", "command" => command, "timeout" => 5}]
           }
         ]}
      end)

    {:ok, specs} = Discovery.parse(Jason.encode!(%{"hooks" => hooks}), :codex)
    Enum.map(specs, &%{&1 | origin: {:user, "test"}, trusted?: true, dialect: :codex})
  end

  defp shell_quote(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"

  defp resource_failure_target(:resource_owner, resources, _owned), do: resources
  defp resource_failure_target(:plan, _resources, owned), do: owned.plan

  defp eventually(fun, attempts \\ 300)
  defp eventually(_fun, 0), do: false

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
