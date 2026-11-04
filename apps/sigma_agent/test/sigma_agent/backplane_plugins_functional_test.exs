defmodule Sigma.Agent.BackplanePluginsFunctionalTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.Backplane.{
    ChildIO,
    CodexResources,
    LifetimeRecovery,
    NativeTools,
    PluginResources,
    Store
  }

  alias Backplane.AgentRuntime.Codex.Session
  alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence
  alias Backplane.AgentRuntime.Plugins.Session, as: PluginSession
  alias Backplane.PluginProtocol.Archive
  alias Sigma.Agent.{PluginInstallations, Runtime, Subagents}
  alias Sigma.Coding.Hooks.Spec
  alias Sigma.Coding.Hooks.Spec.Command
  alias Sigma.Session.{Log, Writer}

  @moduletag :tmp_dir
  @root "plugins-functional"
  @list "list_available_plugins_to_install"
  @request "request_plugin_install"

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    def stream(params) do
      send(params.options[:test_pid], {:plugins_provider, self(), params})

      receive do
        {:plugins_response, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            content: content,
            stop_reason: reason,
            usage: %{input: 1, output: 1, total_tokens: 2},
            model: "plugins-test",
            provider: "plugins-test",
            api: "openai-responses",
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, reason, message}]
      end
    end
  end

  setup %{tmp_dir: dir} do
    catalog = %{
      "data" => [
        %{"plugin_id" => "plugin-example", "name" => "完整插件", "description" => "原文\r\n  e\u0301"}
      ],
      "next_cursor" => nil
    }

    response = Path.join(dir, "catalog.json")
    log = Path.join(dir, "registry.jsonl")
    File.write!(response, Jason.encode!(catalog))
    File.write!(log, "")
    python = System.find_executable("python3")
    assert is_binary(python)

    port =
      Port.open({:spawn_executable, python}, [
        :binary,
        :exit_status,
        args: ["-u", "-c", registry(), response, log]
      ])

    assert_receive {^port, {:data, address}}, 5_000
    {number, ""} = Integer.parse(String.trim(address))
    root = Path.join(dir, "plugins")
    config = %{"registryUrl" => "http://127.0.0.1:#{number}", "requestsRoot" => root}
    assert {:ok, host} = PluginResources.open(config)

    on_exit(fn ->
      stop_repository(dir)

      case Registry.lookup(Sigma.Agent.RepositoryRegistry, {:plugin_requests, root}) do
        [{pid, _}] -> GenServer.stop(pid, :normal)
        [] -> :ok
      end

      if Port.info(port), do: Port.close(port)
    end)

    %{
      dir: dir,
      path: Path.join(dir, @root <> ".jsonl"),
      config: config,
      host: host,
      requests: Path.join(root, "requests.json"),
      catalog: catalog,
      response: response,
      log: log
    }
  end

  test "configured root catalogs and requests retain complete direct and real Deno results across turns and reopening",
       c do
    package!(c)
    agent = session!(c)
    root = prompt!(agent)
    assert Enum.all?(NativeTools.plugin_names(), &(&1 in names(root)))
    root = call!(root, @list, %{})
    assert data!(root, @list) == expected_catalog(c)
    refute File.exists?(c.requests)

    reason = "  请安装此插件\r\n完整原文 e\u0301 👩‍💻\n"
    args = arguments(reason)
    root = install_call!(root, @request, args, c)
    request = data!(root, @request)
    assert request["status"] == "completed"
    assert request["completed"]
    assert request["user_confirmed"]
    previous = result!(root, @request)
    assert [saved] = saved!(c)
    assert saved["arguments"] == args
    assert saved["plugin_request_id"] == request["request_id"]

    code = """
    const catalog = await tools.list_available_plugins_to_install({});
    const requested = await tools.request_plugin_install(#{Jason.encode!(arguments("Deno 完整请求\r\n"))});
    return {catalog, requested};
    """

    root = install_call!(root, "exec", code, c)
    nested = data!(root, "exec")
    assert nested["status"] == "completed"
    assert nested["value"]["catalog"] == c.catalog
    assert nested["value"]["requested"]["status"] == "completed"
    assert nested["value"]["requested"]["user_confirmed"]
    assert length(saved!(c)) == 2
    finish!(root, agent, c)

    state = file_state(c.requests)
    root = prompt!(agent)
    assert_previous!(root, previous)
    root = call!(root, @list, %{})
    assert data!(root, @list) == expected_catalog(c)
    assert file_state(c.requests) == state
    finish!(root, agent, c)
    assert {:ok, _} = Writer.flush(Runtime.lookup(c.dir, @root, :writer))
    assert {:ok, journal} = Log.snapshot(c.path)
    assert Enum.any?(journal.messages, &(field(&1, :tool_call_id) == previous.tool_call_id))
    stop_repository(c.dir)
    assert Process.alive?(c.host.writer)
    GenServer.stop(c.host.writer, :normal)

    agent = session!(c)
    root = prompt!(agent)
    assert_previous!(root, previous)
    root = call!(root, @list, %{})
    assert data!(root, @list) == expected_catalog(c)
    assert file_state(c.requests) == state
    finish!(root, agent, c)
    assert length(http_requests(c)) == 8
    assert Enum.count(http_requests(c), &(&1["path"] == "/plugin-protocol/v1/catalog")) == 4
  end

  test "actual managed children retain the configured plugin host on followup and use real Deno",
       c do
    package!(c)
    agent = session!(c)
    root = prompt!(agent)

    send_call(root, "spawn_agent", %{
      "task_name" => "plugin_reader",
      "message" => "List the plugin catalog",
      "fork_turns" => "none"
    })

    child = provider!(:child)
    root = provider!(@root)
    refute result!(root, "spawn_agent").is_error
    assert Enum.all?(NativeTools.plugin_names(), &(&1 in names(child)))
    child = call!(child, @list, %{})
    assert data!(child, @list) == expected_catalog(c)
    child = install_call!(child, @request, arguments("child direct\r\n完整"), c)
    previous = result!(child, @request)
    child_id = child.params.session_id
    first_run = child_runtime_run!(child, c)
    assert data!(child, @request)["status"] == "completed"
    assert List.last(saved!(c))["arguments"]["suggest_reason"] == "child direct\r\n完整"
    finish!(child, agent, c)

    send_call(root, "followup_task", %{
      "target" => "/root/plugin_reader",
      "message" => "Request the plugin through Deno"
    })

    child = provider!(child_id)
    root = provider!(@root)
    refute result!(root, "followup_task").is_error
    assert_previous!(child, previous)

    child =
      install_call!(
        child,
        "exec",
        "return await tools.request_plugin_install(#{Jason.encode!(arguments("child Deno\r\n完整"))});",
        c
      )

    assert data!(child, "exec")["value"]["status"] == "completed"
    assert data!(child, "exec")["value"]["user_confirmed"]
    assert length(saved!(c)) == 2
    second_run = child_runtime_run!(child, c)
    refute second_run == first_run
    assert Enum.map(saved!(c), & &1["invocation"]["run_id"]) == [first_run, second_run]
    finish!(child, agent, c)
    finish!(root, agent, c)
  end

  test "catalog failures return an ordinary tool error and a later read succeeds without creating requests",
       c do
    File.write!(c.response, Jason.encode!(%{"_status" => 503}))
    agent = session!(c)
    root = prompt!(agent)
    root = call!(root, @list, %{})
    assert result!(root, @list).is_error
    File.write!(c.response, Jason.encode!(c.catalog))
    root = call!(root, @list, %{})
    refute result!(root, @list).is_error
    assert data!(root, @list) == expected_catalog(c)
    refute File.exists?(c.requests)
    finish!(root, agent, c)
  end

  test "an exact request retry survives writer replacement and preserves its original receipt",
       c do
    resources =
      start_supervised!(
        {CodexResources,
         workspace: c.dir,
         owner_pid: self(),
         plugins: c.config,
         memory_root: Path.join(c.dir, "memories")}
      )

    authority = %{
      caller: "plugins-functional-retry",
      run_id: "request-retry",
      grants: NativeTools.plugin_names(),
      tool_revision: 1
    }

    assert {:ok, binding} = CodexResources.bind(resources, authority)
    assert {:ok, context} = CodexResources.context(resources, binding)

    assert {:ok, profile} =
             NativeTools.profile(context, authority, %{}, tools: NativeTools.plugin_names())

    assert :ok = Session.attach(binding, profile)

    operation = %{
      run_id: binding.run_id,
      incarnation: binding.run_incarnation,
      caller: authority.caller,
      invocation_id: "request-once",
      tool_call_id: "request-once",
      tool_name: @request,
      arguments: arguments("exact retry\r\n原文"),
      backend_context: %{plugin_resources: context.plugin_resources}
    }

    assert {:ok, first} = PluginResources.request_install(operation.arguments, operation)
    before = file_state(c.requests)
    assert {:ok, ^first} = PluginResources.request_install(operation.arguments, operation)
    assert file_state(c.requests) == before
    GenServer.stop(c.host.writer, :normal)
    assert {:ok, replacement} = PluginResources.open(c.config)

    operation =
      put_in(operation.backend_context.plugin_resources, Map.put(replacement, :binding, binding))

    assert {:ok, ^first} = PluginResources.request_install(operation.arguments, operation)
    assert file_state(c.requests) == before
    assert :ok = Session.prepare_detach(binding)
    assert {:ok, %{status: :retained}} = Session.detach(binding)
    assert {:ok, %{status: :confirmed}} = CodexResources.close(resources)
  end

  test "unconfigured native sessions omit both plugin tools", c do
    agent = session!(c, native_plugins: nil)
    root = prompt!(agent)
    refute Enum.any?(NativeTools.plugin_names(), &(&1 in names(root)))
    finish!(root, agent, c)
    refute File.exists?(c.requests)
    assert http_requests(c) == []
  end

  test "native installation waits for the exact explicitly confirmed host receipt", c do
    package!(c)
    {resources, binding, operation} = completion_operation!(c)

    pending =
      Task.async(fn -> PluginResources.request_install(operation.arguments, operation) end)

    assert eventually(fn -> File.exists?(c.requests) end)
    [request] = saved!(c)
    assert request["plugin_request_id"] == operation.plugin_request_id
    assert request["invocation"]["invocation_id"] == operation.invocation_id
    assert Task.yield(pending, 50) == nil
    before = file_state(c.requests)

    assert {:ok, _installed} = PluginResources.install(c.host, request["id"])
    assert Task.yield(pending, 50) == nil
    assert {:ok, receipt} = PluginInstallations.install(c.host, request["id"], :settings)
    assert receipt["status"] == "installed"

    assert {:ok, {:completed, completed}} = Task.await(pending)

    assert completed == %{
             completed: true,
             user_confirmed: true,
             tool_type: "plugin",
             action_type: "install",
             tool_id: "plugin-example"
           }

    assert file_state(c.requests) == before
    assert length(http_requests(c)) == 2

    assert {:ok, {:completed, ^completed}} =
             PluginResources.request_install(operation.arguments, operation)

    assert length(http_requests(c)) == 2

    changed = Map.put(operation, :plugin_request_id, "another-public-request")

    assert {:error, %{class: :resource_conflict}} =
             PluginResources.request_install(changed.arguments, changed)

    assert :ok = Session.prepare_detach(binding)
    assert {:ok, %{status: :retained}} = Session.detach(binding)
    assert {:ok, %{status: :confirmed}} = CodexResources.close(resources)
  end

  test "native host failure retains its exact cause and does not retry installation", c do
    package!(c)
    {resources, binding, operation} = completion_operation!(c)

    pending =
      Task.async(fn -> PluginResources.request_install(operation.arguments, operation) end)

    assert eventually(fn -> File.exists?(c.requests) end)
    [request] = saved!(c)
    assert Task.yield(pending, 50) == nil
    File.write!(Path.join(c.dir, "release.json"), Jason.encode!(%{"_status" => 503}))
    assert {:error, error} = PluginInstallations.install(c.host, request["id"], :protocol)
    assert {:error, ^error} = Task.await(pending)
    assert {:error, ^error} = PluginResources.request_install(operation.arguments, operation)
    GenServer.stop(c.host.writer, :normal)
    assert {:ok, replacement} = PluginResources.open(c.config)

    operation =
      put_in(
        operation.backend_context.plugin_resources,
        Map.put(replacement, :binding, binding)
      )

    assert {:error, ^error} = PluginResources.request_install(operation.arguments, operation)
    assert length(http_requests(c)) == 1
    assert :ok = Session.prepare_detach(binding)
    assert {:ok, %{status: :retained}} = Session.detach(binding)
    assert {:ok, %{status: :confirmed}} = CodexResources.close(resources)
  end

  test "closing the original binding rejects late installation as native completion", c do
    package!(c)
    {resources, binding, operation} = completion_operation!(c)

    pending =
      Task.async(fn -> PluginResources.request_install(operation.arguments, operation) end)

    assert eventually(fn -> File.exists?(c.requests) end)
    [request] = saved!(c)
    assert Task.yield(pending, 50) == nil
    before = file_state(c.requests)
    assert :ok = Session.prepare_detach(binding)
    assert {:ok, %{status: :retained}} = Session.detach(binding)
    assert {:error, %Backplane.AgentRuntime.Error{} = closed} = Task.await(pending)

    assert {:ok, %{"status" => "installed"}} =
             PluginInstallations.install(c.host, request["id"], :settings)

    assert {:error, ^closed} = PluginResources.request_install(operation.arguments, operation)
    assert file_state(c.requests) == before
    assert length(http_requests(c)) == 2
    assert {:ok, %{status: :confirmed}} = CodexResources.close(resources)
  end

  # Exact retirement of the observer preserves the unknown installation outcome;
  # late installation and the next binding remain independent effects.
  for mode <- [:direct, :deno], post_hooks <- [false, true] do
    @tag :plugin_cancellation
    @tag plugin_post_hook_cancellation: post_hooks
    test "real Engine cancellation rejects late #{mode} plugin completion and admits a fresh binding#{if post_hooks, do: " with PostToolUse", else: ""}",
         c do
      package = package!(c)

      specs =
        if unquote(post_hooks) do
          [
            %Spec{
              event: :post_tool_use,
              matcher: :any,
              handler: %Command{cmd: "printf '{}'", timeout_ms: 5_000},
              origin: {:user, "functional fixture"},
              dialect: :codex,
              trusted?: true
            }
          ]
        else
          []
        end

      agent = session!(c, hook_specs: specs)
      root = prompt!(agent)
      args = arguments("Cancelled installation waiting for host confirmation\r\n原文")

      {tool, input} =
        case unquote(mode) do
          :direct -> {@request, args}
          :deno -> {"exec", "return await tools.request_plugin_install(#{Jason.encode!(args)});"}
        end

      send_call(root, tool, input)
      assert eventually(fn -> File.exists?(c.requests) end)
      assert [request] = saved!(c)
      assert is_binary(request["plugin_request_id"])
      assert http_requests(c) == []
      refute File.exists?(package.mcp_log)
      refute_receive {:plugins_provider, _, _}, 50

      assert {:cancelling, _} = Sigma.Agent.cancel(agent)
      assert eventually(fn -> Sigma.Agent.status(agent).phase == :cancelled end)
      assert eventually(fn -> is_nil(:sys.get_state(agent).current_turn_task) end)
      assert eventually(fn -> is_nil(:sys.get_state(agent).goal_idle_task) end)
      writer = Runtime.lookup(c.dir, @root, :writer)
      assert {:ok, _} = Writer.flush(writer)
      assert {:ok, cancelled} = Log.snapshot(c.path)
      request_before = file_state(c.requests)
      journal_before = file_state(c.path)

      runtime_before =
        c.path
        |> Kernel.<>(".runtime/*.runtime")
        |> Path.wildcard()
        |> Map.new(&{&1, file_state(&1)})

      refute runtime_before == %{}
      proofs = plugin_retirement_proofs!(c, request, unquote(mode))

      assert {:ok, %{"status" => "installed"}} =
               PluginInstallations.install(c.host, request["id"], :settings)

      assert file_state(c.requests) == request_before
      assert file_state(c.path) == journal_before
      assert {:ok, ^cancelled} = Log.snapshot(c.path)

      assert Map.new(runtime_before, fn {path, _} -> {path, file_state(path)} end) ==
               runtime_before

      assert length(http_requests(c)) == 2
      refute File.exists?(package.mcp_log)
      refute_receive {:plugins_provider, _, _}, 50

      root = prompt!(agent)
      assert plugin_retirement_proofs!(c, request, unquote(mode)) == proofs

      assert Map.new(runtime_before, fn {path, _} -> {path, file_state(path)} end) ==
               runtime_before

      assert [started] = plugin_starts(package)
      assert started["event"] == "started"
      {root, _function} = plugin_function!(root)
      finish!(root, agent, c)
      assert length(http_requests(c)) == 2
      assert file_state(c.requests) == request_before
      assert {:ok, %{status: :confirmed}} = Sigma.Agent.retire_host(agent)
      assert eventually(fn -> not os_process?(started) end)
    end
  end

  for mode <- [:direct, :deno] do
    @tag :plugin_child_cancellation
    test "managed child #{mode} plugin wait retires its exact proof before a fresh archived followup",
         c do
      package = package!(c)
      agent = session!(c)
      root = prompt!(agent)

      send_call(root, "spawn_agent", %{
        "task_name" => "plugin_observer",
        "message" => "Request the plugin and wait for the host",
        "fork_turns" => "none"
      })

      child = provider!(:child)
      root = provider!(@root)
      refute result!(root, "spawn_agent").is_error
      child_id = child.params.session_id
      first_run = child_runtime_run!(child, c)
      args = arguments("Cancelled child installation\r\n完整原文")

      {tool, input} =
        case unquote(mode) do
          :direct -> {@request, args}
          :deno -> {"exec", "return await tools.request_plugin_install(#{Jason.encode!(args)});"}
        end

      send_call(child, tool, input)
      assert eventually(fn -> File.exists?(c.requests) end)
      assert [request] = saved!(c)
      assert request["invocation"]["run_id"] == first_run
      assert http_requests(c) == []
      refute File.exists?(package.mcp_log)
      refute_receive {:plugins_provider, _, _}, 50

      root = call!(root, "interrupt_agent", %{"target" => "/root/plugin_observer"})
      refute result!(root, "interrupt_agent").is_error
      host = Runtime.lookup(c.dir, @root, :subagents)
      assert {:ok, sources} = Subagents.archive_sources(host)
      source = Enum.find(sources.children, &(&1.identity.child_session_id == child_id))
      assert is_map(source)
      assert {:ok, metadata} = ChildIO.metadata(source.io)
      assert {:ok, archive_source} = ChildIO.archive_source(source.io)
      assert {:ok, _} = Writer.flush(archive_source.writer)
      assert {:ok, cancelled} = Log.snapshot(metadata.transcript_path)
      proofs = plugin_retirement_proofs!(c, request, unquote(mode), metadata.backplane_store_path)
      request_before = file_state(c.requests)
      child_before = file_state(metadata.transcript_path)
      child_bytes = File.read!(metadata.transcript_path)

      runtime_before =
        metadata.backplane_store_path
        |> Path.join("*.runtime")
        |> Path.wildcard()
        |> Map.new(&{&1, file_state(&1)})

      refute runtime_before == %{}

      assert {:ok, %{"status" => "installed"}} =
               PluginInstallations.install(c.host, request["id"], :settings)

      assert file_state(c.requests) == request_before
      assert file_state(metadata.transcript_path) == child_before
      assert {:ok, ^cancelled} = Log.snapshot(metadata.transcript_path)

      assert Map.new(runtime_before, fn {path, _} -> {path, file_state(path)} end) ==
               runtime_before

      refute File.exists?(package.mcp_log)
      refute_receive {:plugins_provider, _, _}, 50
      assert length(http_requests(c)) == 2

      root = call!(root, @list, %{})
      assert data!(root, @list) == expected_catalog(c)
      finish!(root, agent, c)
      assert {:ok, %{status: :confirmed}} = Sigma.Agent.retire_host(agent)
      assert :ok = Sigma.Agent.end_session_operation(agent)

      root = prompt!(agent)
      recovery = LifetimeRecovery.locate(c.path)
      assert is_pid(recovery)

      for proof <- proofs do
        reference = "effect-retirement:" <> Evidence.digest(proof)
        assert {:ok, ^proof} = LifetimeRecovery.load_evidence(recovery, reference)
      end

      {root, function} = plugin_function!(root)

      send_call(root, "followup_task", %{
        "target" => "/root/plugin_observer",
        "message" => "Use the independently installed plugin on a new run"
      })

      root = provider!(@root)
      followup = result!(root, "followup_task")
      refute followup.is_error, inspect(followup)
      child = provider!(child_id)
      refute child_runtime_run!(child, c) == first_run
      {child, ^function} = plugin_function!(child)
      value = "  fresh child after cancelled #{unquote(mode)} wait\r\n中文"
      child = call!(child, function, %{"value" => value})
      assert data!(child, function) == %{"plugin" => "example", "value" => value}
      finish!(child, agent, c)
      finish!(root, agent, c)
      assert String.starts_with?(File.read!(metadata.transcript_path), child_bytes)
      assert file_state(c.requests) == request_before
      assert length(saved!(c)) == 1
      assert length(http_requests(c)) == 3
      assert {:ok, %{status: :confirmed}} = Sigma.Agent.retire_host(agent)
      assert eventually(fn -> Enum.all?(plugin_starts(package), &(not os_process?(&1))) end)
    end
  end

  test "a durable host installation survives native completion persistence failure", c do
    package!(c)
    {resources, binding, operation} = completion_operation!(c)

    pending =
      Task.async(fn -> PluginResources.request_install(operation.arguments, operation) end)

    assert eventually(fn -> File.exists?(c.requests) end)
    [request] = saved!(c)
    assert Task.yield(pending, 50) == nil
    # The registry fixture makes an ordinary directory during artifact download,
    # after the host's initial read and before completion persistence.
    File.write!(Path.join(c.dir, "break-native-completion"), "yes")

    assert {:ok, %{"status" => "installed"}} =
             PluginInstallations.install(c.host, request["id"], :protocol)

    assert {:error, %{class: :unknown_outcome, message: message}} = Task.await(pending)
    assert message == "native plugin completion persistence is unconfirmed"
    assert {:ok, [%{"status" => "installed"}]} = PluginResources.installed(c.host)
    assert length(http_requests(c)) == 2
    assert :ok = Session.prepare_detach(binding)
    assert {:ok, %{status: :retained}} = Session.detach(binding)
    assert {:ok, %{status: :confirmed}} = CodexResources.close(resources)
  end

  test "explicit host installation completes the original native call before real MCP activation",
       c do
    package = package!(c)
    agent = session!(c)
    root = prompt!(agent)
    root = install_call!(root, @request, arguments("Install the exact package\r\n保留原文"), c)
    [request] = saved!(c)
    request_state = file_state(c.requests)

    assert {:ok, installed} = PluginResources.install(c.host, request["id"])
    assert installed["status"] == "installed"
    assert installed["artifact_digest"] == package.digest
    assert installed["release_id"] == "release-example"

    assert Enum.all?(package.files, fn {path, bytes} ->
             File.read!(Path.join(installed["root"], path)) == bytes
           end)

    assert file_state(c.requests) == request_state
    assert data!(root, @request)["status"] == "completed"
    assert [request] == saved!(c)
    assert not File.exists?(package.mcp_log)

    assert {:ok, plugin} = PluginResources.activate(c.host, request["id"], "installed-run")
    on_exit(fn -> if Process.alive?(plugin), do: PluginSession.stop(plugin) end)

    assert %{diagnostics: [], components: %{"example" => %{status: :ready}}} =
             PluginSession.snapshot(plugin)

    assert {:ok, skill} =
             PluginSession.load_skill(plugin, "installed-run", "skills/example/SKILL.md")

    assert skill.content == package.files["skills/example/SKILL.md"]

    assert {:ok, bytes} =
             PluginSession.resource(plugin, "installed-run", "skills/example/data.txt")

    assert bytes == package.files["skills/example/data.txt"]

    assert {:ok, catalog} = PluginSession.catalog(plugin, "installed-run")
    assert [name] = Map.keys(catalog.registry.tools)

    assert {:ok, result} =
             PluginSession.call_tool(plugin, "installed-run", name, %{"value" => "  中文\r\n"})

    assert result["structuredContent"] == %{"value" => "  中文\r\n", "plugin" => "example"}
    assert :ok = PluginSession.stop(plugin)
    assert [started, %{"method" => "tools/call"}] = json_lines(package.mcp_log)
    assert eventually(fn -> not File.exists?("/proc/#{started["pid"]}") end)

    root = call!(root, @list, %{})
    assert data!(root, @list) == expected_catalog(c)
    finish!(root, agent, c)
    assert {:ok, _} = Writer.flush(Runtime.lookup(c.dir, @root, :writer))
    assert {:ok, journal} = Log.snapshot(c.path)

    assert Enum.any?(
             journal.messages,
             &(field(&1, :tool_call_id) == result!(root, @request).tool_call_id)
           )

    assert file_state(c.requests) == request_state
    assert length(http_requests(c)) == 3
  end

  test "installed receipts survive writer replacement and concurrent exact installs without HTTP or file rewrites",
       c do
    package = package!(c)
    request = request!(c)
    assert {:ok, installed} = PluginResources.install(c.host, request["id"])
    before = package_state(c, installed)
    GenServer.stop(c.host.writer, :normal)
    assert {:ok, host} = PluginResources.open(c.config)

    results =
      1..6
      |> Task.async_stream(fn _ -> PluginResources.install(host, request["id"]) end)
      |> Enum.to_list()

    assert results == List.duplicate({:ok, {:ok, installed}}, 6)
    assert package_state(c, installed) == before
    assert length(http_requests(c)) == 2
    refute File.exists?(package.mcp_log)

    assert {:ok, plugin} = PluginResources.activate(host, request["id"], "replacement-run")
    assert {:ok, catalog} = PluginSession.catalog(plugin, "replacement-run")
    assert [_] = catalog.accepted
    assert :ok = PluginSession.stop(plugin)
    assert package_state(c, installed) == before
  end

  test "real root plugin catalogs refresh across turns and cold history never replays MCP calls",
       c do
    package = package!(c)
    request = request!(c)
    assert {:ok, installed} = PluginResources.install(c.host, request["id"])
    before = package_state(c, installed)
    refute File.exists?(package.mcp_log)
    agent = Runtime.lookup(c.dir, @root, :agent)

    root = prompt!(agent)
    assert [first_process] = plugin_starts(package)
    {root, function} = plugin_function!(root)
    value = "  原生插件 e\u0301 👩‍💻\r\n完整内容\n"
    root = call!(root, function, %{"value" => value})
    assert data!(root, function) == %{"plugin" => "example", "value" => value}
    direct = result!(root, function)
    finish!(root, agent, c)

    root = prompt!(agent)
    assert [^first_process, second_process] = plugin_starts(package)
    assert eventually(fn -> not os_process?(first_process) end)
    refute function in names(root)
    {root, ^function} = plugin_function!(root)
    code = "return await tools[#{Jason.encode!(function)}](#{Jason.encode!(%{value: value})});"
    root = call!(root, "exec", code)
    refute result!(root, "exec").is_error

    assert data!(root, "exec")["value"]["details"]["structuredContent"] ==
             %{"plugin" => "example", "value" => value}

    nested = result!(root, "exec")
    finish!(root, agent, c)
    assert {:ok, _} = Writer.flush(Runtime.lookup(c.dir, @root, :writer))
    assert {:ok, %{status: :confirmed}} = Sigma.Agent.retire_host(agent)
    assert eventually(fn -> not os_process?(second_process) end)
    calls = Enum.filter(plugin_events(package), &(&1["method"] == "tools/call"))
    assert length(calls) == 2
    stop_repository(c.dir)

    agent = session!(c)
    refute_receive {:plugins_provider, _, _}, 0
    assert Enum.filter(plugin_events(package), &(&1["method"] == "tools/call")) == calls
    root = prompt!(agent)
    assert_previous!(root, direct)
    assert_previous!(root, nested)
    finish!(root, agent, c)
    assert {:ok, %{status: :confirmed}} = Sigma.Agent.retire_host(agent)
    assert eventually(fn -> Enum.all?(plugin_starts(package), &(not os_process?(&1))) end)
    assert length(plugin_starts(package)) == 3
    assert Enum.filter(plugin_events(package), &(&1["method"] == "tools/call")) == calls
    assert length(http_requests(c)) == 2
    assert package_state(c, installed) == before
  end

  test "installed plugins join the next real root and child runs with owned MCP catalogs and immutable skills",
       c do
    previous_skills = Application.fetch_env(:sigma_session, :global_skills_dir)
    Application.put_env(:sigma_session, :global_skills_dir, Path.join(c.dir, "global-skills"))

    on_exit(fn ->
      case previous_skills do
        {:ok, value} -> Application.put_env(:sigma_session, :global_skills_dir, value)
        :error -> Application.delete_env(:sigma_session, :global_skills_dir)
      end
    end)

    package = package!(c)
    agent = session!(c)
    root = prompt!(agent)
    {root, []} = plugin_skills!(root)
    root = install_call!(root, @request, arguments("Install skills for the next run"), c)
    [request] = saved!(c)

    assert {:ok, %{"status" => "installed"}} =
             PluginInstallations.install(c.host, request["id"])

    assert {:ok, [installed]} = PluginResources.installed(c.host)

    {root, []} = plugin_skills!(root)
    refute "tool_search" in names(root)
    refute File.exists?(package.mcp_log)
    finish!(root, agent, c)
    before = package_state(c, installed)
    GenServer.stop(c.host.writer, :normal)
    assert {:ok, _replacement} = PluginResources.open(c.config)

    root = prompt!(agent)
    assert [root_process] = plugin_starts(package)
    {root, skill} = plugin_skill!(root)
    root = call!(root, "skills::read", %{"package" => skill["package"]})
    read = data!(root, "skills::read")
    assert read["contents"] == package.files["skills/example/SKILL.md"]
    assert File.dir?(read["skill_root"])
    previous = result!(root, "skills::read")
    assert plugin_events(package) == [root_process]
    {root, function} = plugin_function!(root)
    root_value = "  根插件 e\u0301 👩‍💻\r\n完整结果\n"
    root = call!(root, function, %{"value" => root_value})
    assert data!(root, function) == %{"plugin" => "example", "value" => root_value}
    plugin_result = result!(root, function)

    send_call(root, "spawn_agent", %{
      "task_name" => "installed_skills",
      "message" => "Read the installed plugin skill",
      "fork_turns" => "none"
    })

    child = provider!(:child)
    root = provider!(@root)
    assert [^root_process, child_process] = plugin_starts(package)
    refute child_process["pid"] == root_process["pid"]
    refute function in names(child)
    {child, ^function} = plugin_function!(child)
    child_value = "  子插件\r\n独立连接"
    child = call!(child, function, %{"value" => child_value})
    assert data!(child, function) == %{"plugin" => "example", "value" => child_value}
    {child, child_skill} = plugin_skill!(child)
    assert child_skill["reference"] == skill["reference"]
    refute child_skill["package"] == skill["package"]
    child = call!(child, "skills::read", %{"package" => child_skill["package"]})
    child_read = data!(child, "skills::read")
    assert child_read["contents"] == read["contents"]
    child_id = child.params.session_id
    finish!(child, agent, c)

    send_call(root, "followup_task", %{
      "target" => "/root/installed_skills",
      "message" => "Read the installed plugin resource on a new run"
    })

    child = provider!(child_id)
    root = provider!(@root)
    assert [^root_process, ^child_process, followup_process] = plugin_starts(package)
    assert eventually(fn -> not os_process?(child_process) end)
    assert os_process?(root_process)
    refute function in names(child)
    {child, ^function} = plugin_function!(child)
    followed_value = "  Deno 后续 e\u0301\r\n"

    code =
      "return await tools[#{Jason.encode!(function)}](#{Jason.encode!(%{value: followed_value})});"

    child = call!(child, "exec", code)
    refute result!(child, "exec").is_error

    assert data!(child, "exec")["value"]["details"]["structuredContent"] ==
             %{"plugin" => "example", "value" => followed_value}

    {child, followed_skill} = plugin_skill!(child)
    assert followed_skill["reference"] == skill["reference"]
    refute File.exists?(child_read["skill_root"])

    child =
      call!(child, "skills::read", %{
        "package" => followed_skill["package"],
        "resource" =>
          String.replace_suffix(followed_skill["main_resource"], "SKILL.md", "data.txt")
      })

    assert data!(child, "skills::read")["contents"] == package.files["skills/example/data.txt"]
    child_root = data!(child, "skills::read")["skill_root"]
    finish!(child, agent, c)
    finish!(root, agent, c)

    root = prompt!(agent)
    assert_previous!(root, previous)
    assert_previous!(root, plugin_result)
    assert [^root_process, ^child_process, ^followup_process, _] = plugin_starts(package)
    assert eventually(fn -> not os_process?(root_process) end)
    refute File.exists?(read["skill_root"])
    {root, next_skill} = plugin_skill!(root)
    assert next_skill["reference"] == skill["reference"]
    finish!(root, agent, c)
    assert {:ok, _} = Writer.flush(Runtime.lookup(c.dir, @root, :writer))
    assert {:ok, journal} = Log.snapshot(c.path)

    refute Enum.any?(
             journal.messages,
             &(field(&1, :role) in [:skill_activation, "skill_activation"])
           )

    assert Enum.any?(journal.messages, &(field(&1, :tool_call_id) == previous.tool_call_id))

    stop_repository(c.dir)
    assert eventually(fn -> not File.exists?(child_root) end)
    assert eventually(fn -> Enum.all?(plugin_starts(package), &(not os_process?(&1))) end)
    calls = plugin_events(package) |> Enum.filter(&(&1["method"] == "tools/call"))

    assert Enum.map(calls, & &1["arguments"]["value"]) == [
             root_value,
             child_value,
             followed_value
           ]

    assert Enum.map(calls, & &1["pid"]) ==
             Enum.map([root_process, child_process, followup_process], & &1["pid"])

    agent = session!(c)
    root = prompt!(agent)
    assert_previous!(root, previous)
    assert_previous!(root, plugin_result)
    {root, restored_skill} = plugin_skill!(root)
    assert restored_skill["reference"] == skill["reference"]
    root = call!(root, "skills::read", %{"package" => restored_skill["package"]})
    assert data!(root, "skills::read")["contents"] == read["contents"]
    finish!(root, agent, c)

    assert package_state(c, installed) == before
    assert length(http_requests(c)) == 2
    assert length(plugin_starts(package)) == 5
    assert Enum.filter(plugin_events(package), &(&1["method"] == "tools/call")) == calls
  end

  test "installed inventory selects the newest completed release without writes or registry requests",
       c do
    first = package!(c)
    request = request!(c)
    assert {:ok, old} = PluginResources.install(c.host, request["id"])
    second = package!(c, release_id: "release-next", body: "  新版本 e\u0301\r\n")
    request = request!(c)
    agent = Runtime.lookup(c.dir, @root, :agent)
    root = prompt!(agent)
    finish!(root, agent, c)
    # This real prompt starts the installed first release. The inventory
    # reads below must neither start another process nor call that server.
    assert [started] = plugin_events(first)
    assert started["event"] == "started"
    mcp_before = file_state(first.mcp_log)
    assert {:ok, latest} = PluginResources.install(c.host, request["id"])
    assert latest["release_id"] == "release-next"
    refute old["artifact_digest"] == latest["artifact_digest"]
    before = package_state(c, latest)

    assert {:ok, [^latest]} = PluginResources.installed(c.host)
    assert {:ok, []} = PluginResources.installed(nil)

    assert {:ok, []} =
             PluginResources.installed(%{c.host | registry_url: c.host.registry_url <> "/other"})

    assert {:ok, %{writer: writer}} = PluginResources.open(c.config)
    GenServer.stop(writer, :normal)
    assert {:ok, host} = PluginResources.open(c.config)
    assert {:ok, [^latest]} = PluginResources.installed(host)
    assert package_state(c, latest) == before
    assert length(http_requests(c)) == 4
    assert first.mcp_log == second.mcp_log
    assert file_state(first.mcp_log) == mcp_before
  end

  test "pending installation reconciliation only confirms an existing complete package and never downloads or launches",
       c do
    package = package!(c)
    request = request!(c)
    assert {:ok, installed} = PluginResources.install(c.host, request["id"])
    ledger = Path.join(c.config["requestsRoot"], "installations.json")
    pending = installed |> Map.put("status", "installing") |> Map.delete("installed_at")
    File.write!(ledger, Jason.encode!(%{version: 1, installations: [pending]}))
    assert :ok = File.rename(installed["root"], installed["root"] <> ".unpublished")
    before = file_state(ledger)

    assert {:error, %{class: :unknown_outcome, cause: :enoent}} =
             PluginResources.install(c.host, request["id"])

    assert file_state(ledger) == before
    assert length(http_requests(c)) == 2
    assert :ok = File.rename(installed["root"] <> ".unpublished", installed["root"])
    assert {:ok, confirmed} = PluginResources.install(c.host, request["id"])
    assert Map.drop(confirmed, ["installed_at"]) == Map.drop(installed, ["installed_at"])
    assert length(http_requests(c)) == 2
    refute File.exists?(package.mcp_log)
  end

  test "a preparation HTTP failure leaves the native request intact and no installation intent",
       c do
    package!(c)
    request = request!(c)
    release = Path.join(c.dir, "release.json")
    descriptor = File.read!(release)
    File.write!(release, Jason.encode!(%{"_status" => 503}))
    before = file_state(c.requests)

    assert {:error, %{class: :execution_failure, cause: {:http_status, 503}}} =
             PluginResources.install(c.host, request["id"])

    assert file_state(c.requests) == before
    refute File.exists?(Path.join(c.config["requestsRoot"], "installations.json"))
    File.write!(release, descriptor)
    assert {:ok, %{"status" => "installed"}} = PluginResources.install(c.host, request["id"])
    assert file_state(c.requests) == before
    assert length(http_requests(c)) == 3
  end

  test "a package write failure retains a failed receipt and an explicit retry does not repeat preparation",
       c do
    package!(c)
    request = request!(c)
    assert :ok = File.write(Path.join(c.config["requestsRoot"], "packages"), "ordinary file")
    before = file_state(c.requests)

    assert {:error, %{class: :execution_failure}} =
             PluginResources.install(c.host, request["id"])

    ledger = Path.join(c.config["requestsRoot"], "installations.json")

    assert [%{"status" => "failed", "failure" => failure}] =
             Jason.decode!(File.read!(ledger))["installations"]

    assert failure =~ "enotdir"
    receipt = file_state(ledger)

    assert {:error, %{class: :execution_failure}} =
             PluginResources.install(c.host, request["id"])

    assert file_state(ledger) == receipt
    assert file_state(c.requests) == before
    assert length(http_requests(c)) == 2
  end

  test "product requests page immutable native receipts and explicit installs survive writer replacement",
       c do
    assert {:ok, %{"configured" => false, "items" => [], "total" => 0}} =
             PluginInstallations.list(nil)

    assert {:ok, %{"configured" => true, "items" => []}} = PluginInstallations.list(c.host)
    refute File.exists?(c.requests)
    refute File.exists?(Path.join(c.config["requestsRoot"], "installations.json"))
    package = package!(c)
    first = request!(c)
    second = request!(c)
    before = file_state(c.requests)

    assert {:ok, page} = PluginInstallations.list(c.host, %{"limit" => 1})
    assert page["total"] == 2
    assert page["nextOffset"] == 1
    assert [%{"requestId" => second_id, "status" => "requested"}] = page["items"]
    assert second_id == second["id"]

    assert {:ok, tail} =
             PluginInstallations.list(c.host, %{
               "offset" => 1,
               "limit" => 1,
               "expectedRevision" => page["revision"]
             })

    assert [%{"requestId" => first_id, "requestStatus" => "requested"}] = tail["items"]
    assert first_id == first["id"]
    assert is_nil(tail["nextOffset"])
    assert file_state(c.requests) == before
    assert http_requests(c) == []

    assert {:ok, receipt} = PluginInstallations.install(c.host, first_id)
    assert receipt["status"] == "installed"
    assert receipt["requestId"] == first_id
    assert receipt["pluginId"] == "plugin-example"
    assert receipt["artifactDigest"] == package.digest

    assert Map.keys(receipt) |> Enum.sort() ==
             Enum.sort(
               ~w(requestId registryUrl pluginId releaseId artifactDigest contentDigest status startedAt installedAt)
             )

    assert {:error, :plugin_requests_stale} =
             PluginInstallations.list(c.host, %{"expectedRevision" => page["revision"]})

    assert {:ok, updated} = PluginInstallations.list(c.host)
    assert [%{"status" => "requested"}, installed] = updated["items"]
    assert Map.take(installed, Map.keys(receipt)) == receipt
    assert installed["requestStatus"] == "requested"
    assert file_state(c.requests) == before
    assert [%{"status" => "requested"}, %{"status" => "requested"}] = saved!(c)
    assert {:ok, raw} = PluginResources.installed(c.host)
    assert [raw_receipt] = raw
    storage = package_state(c, raw_receipt)

    agent = Runtime.lookup(c.dir, @root, :agent)
    GenServer.stop(c.host.writer, :normal)
    assert {:ok, replacement} = Sigma.Agent.plugin_installation_host(agent)
    refute replacement.writer == c.host.writer
    assert {:ok, ^updated} = PluginInstallations.list(replacement)
    assert {:ok, ^receipt} = PluginInstallations.install(replacement, first_id)
    assert package_state(c, raw_receipt) == storage
    assert length(http_requests(c)) == 2
    refute File.exists?(package.mcp_log)
  end

  test "product failure state retains requests and does not repeat a failed package effect", c do
    package!(c)
    request = request!(c)
    assert :ok = File.write(Path.join(c.config["requestsRoot"], "packages"), "ordinary file")
    before = file_state(c.requests)

    assert {:error, %{class: :execution_failure, message: message}} =
             PluginInstallations.install(c.host, request["id"])

    assert message == "plugin package installation failed"
    assert {:ok, failed} = PluginInstallations.list(c.host)
    assert [%{"status" => "failed", "requestStatus" => "requested"}] = failed["items"]

    assert {:error, %{class: :execution_failure}} =
             PluginInstallations.install(c.host, request["id"])

    assert {:ok, ^failed} = PluginInstallations.list(c.host)
    assert file_state(c.requests) == before
    assert length(http_requests(c)) == 2
  end

  defp request!(c) do
    # Exercise the retained request-only host API independently of the new
    # native call, which must stay pending until explicit host installation.
    session!(c)
    {resources, binding, operation} = completion_operation!(c)
    operation = Map.delete(operation, :plugin_request_id)
    assert {:ok, request} = PluginResources.request_install(operation.arguments, operation)
    assert :ok = Session.prepare_detach(binding)
    assert {:ok, %{status: :retained}} = Session.detach(binding)
    assert {:ok, %{status: :confirmed}} = CodexResources.close(resources)
    request
  end

  test "explicit host checks can reconcile installation without replacing a settled native failure",
       c do
    package = package!(c)
    {resources, binding, operation} = completion_operation!(c)

    pending =
      Task.async(fn -> PluginResources.request_install(operation.arguments, operation) end)

    assert eventually(fn -> File.exists?(c.requests) end)
    [request] = saved!(c)
    assert {:ok, installed} = PluginResources.install(c.host, request["id"])
    ledger = Path.join(c.config["requestsRoot"], "installations.json")
    native_ledger = Path.join(c.config["requestsRoot"], "native-installations.etf")
    installing = installed |> Map.put("status", "installing") |> Map.delete("installed_at")
    File.write!(ledger, Jason.encode!(%{version: 1, installations: [installing]}))
    assert :ok = File.rename(installed["root"], installed["root"] <> ".unpublished")

    assert {:error, %{class: :unknown_outcome, cause: :enoent}} =
             failure =
             PluginInstallations.install(c.host, request["id"], :settings)

    assert Task.await(pending) == failure
    original_native = file_state(native_ledger)
    original_request = file_state(c.requests)
    assert :ok = File.rename(installed["root"] <> ".unpublished", installed["root"])

    assert {:ok, %{"status" => "installed"}} =
             PluginInstallations.install(c.host, request["id"], :protocol)

    assert {:ok, [confirmed]} = PluginResources.installed(c.host)
    assert Map.drop(confirmed, ["installed_at"]) == Map.drop(installed, ["installed_at"])
    assert PluginResources.request_install(operation.arguments, operation) == failure
    assert file_state(native_ledger) == original_native
    assert file_state(c.requests) == original_request
    assert length(http_requests(c)) == 2
    refute File.exists?(package.mcp_log)
    assert :ok = Session.prepare_detach(binding)
    assert {:ok, %{status: :retained}} = Session.detach(binding)
    assert {:ok, %{status: :confirmed}} = CodexResources.close(resources)
  end

  test "actual child stdio cleanup retains an unconfirmed guardian crash without retrying or closing the root",
       c do
    package = package!(c)
    agent = session!(c)
    root = prompt!(agent)
    root = install_call!(root, @request, arguments("Install for independent cleanup"), c)
    finish!(root, agent, c)
    root = prompt!(agent)
    {root, function} = plugin_function!(root)
    root = call!(root, function, %{"value" => "root before child retirement"})

    assert data!(root, function) == %{
             "plugin" => "example",
             "value" => "root before child retirement"
           }

    send_call(root, "spawn_agent", %{
      "task_name" => "stdio_cleanup_failure",
      "message" => "Use the independent installed plugin connection",
      "fork_turns" => "none"
    })

    child = provider!(:child)
    root = provider!(@root)
    {child, ^function} = plugin_function!(child)
    child = call!(child, function, %{"value" => "child before retirement"})

    assert data!(child, function) == %{
             "plugin" => "example",
             "value" => "child before retirement"
           }

    child_id = child.params.session_id
    child_run = child_runtime_run!(child, c)
    finish!(child, agent, c)
    host = Runtime.lookup(c.dir, @root, :subagents)
    assert {:ok, sources} = Subagents.archive_sources(host)
    source = Enum.find(sources.children, &(&1.identity.child_session_id == child_id))
    assert is_pid(source.io)
    assert [root_process, child_process] = plugin_starts(package)
    refute root_process["pid"] == child_process["pid"]

    # Bind only the fixture's logged target and its direct packaged guardian.
    # pidfds and start times prevent a recycled PID from becoming a signal target.
    process_script = """
    import json,os,signal,sys
    def facts(pid):
        with open('/proc/%d/stat' % pid) as f:
            fields=f.read().rsplit(') ',1)[1].split()
        return {'pid':pid,'ppid':int(fields[1]),'start':fields[19],'state':fields[0]}
    def same_process(actual,expected):
        return all(actual[k]==expected[k] for k in ('pid','start'))
    mode=sys.argv[1]
    if mode=='bind':
        target=facts(int(sys.argv[2]))
        guardian=facts(target['ppid'])
        executable=os.path.realpath('/proc/%d/exe' % guardian['pid'])
        assert os.path.samefile(executable,sys.argv[3]), 'unexpected target parent executable'
        print(json.dumps({'target':target,'guardian':guardian,'executable':executable}))
    elif mode=='crash':
        bound=json.loads(sys.argv[2])
        target,guardian=bound['target'],bound['guardian']
        def verify():
            actual=facts(target['pid'])
            assert same_process(actual,target) and actual['ppid']==guardian['pid'], 'target changed'
            assert same_process(facts(guardian['pid']),guardian), 'guardian changed'
            assert os.path.samefile('/proc/%d/exe' % guardian['pid'],bound['executable']), 'guardian executable changed'
        verify()
        fd=os.pidfd_open(guardian['pid'])
        try:
            verify()
            signal.pidfd_send_signal(fd,signal.SIGKILL)
        finally:
            os.close(fd)
        print('guardian crashed')
    elif mode=='cleanup':
        target=json.loads(sys.argv[2])['target']
        try:
            actual=facts(target['pid'])
            if same_process(actual,target) and actual['state'] not in ('Z','X'):
                fd=os.pidfd_open(target['pid'])
                try:
                    actual=facts(target['pid'])
                    if same_process(actual,target) and actual['state'] not in ('Z','X'):
                        signal.pidfd_send_signal(fd,signal.SIGKILL)
                finally:
                    os.close(fd)
        except (FileNotFoundError,ProcessLookupError):
            pass
    """

    python = System.find_executable("python3")

    guardian_path =
      :backplane_mcp_protocol
      |> :code.priv_dir()
      |> to_string()
      |> Path.join("bin/backplane-mcp-stdio-guardian")

    assert {binding_json, 0} =
             System.cmd(python, [
               "-c",
               process_script,
               "bind",
               Integer.to_string(child_process["pid"]),
               guardian_path
             ])

    binding = Jason.decode!(binding_json)
    guardian_pid = binding["guardian"]["pid"]
    assert binding["target"]["pid"] == child_process["pid"]
    assert binding["target"]["ppid"] == guardian_pid
    assert binding["target"]["start"] != ""
    assert binding["guardian"]["start"] != ""

    on_exit(fn ->
      assert {"", 0} = System.cmd(python, ["-c", process_script, "cleanup", binding_json])
    end)

    assert {"guardian crashed\n", 0} =
             System.cmd(python, ["-c", process_script, "crash", binding_json])

    assert {:error,
            %Backplane.AgentRuntime.Error{
              class: :unknown_outcome,
              message: "plugin cleanup is unconfirmed",
              details: %{close_id: close_id, report: report}
            } = original} = Sigma.Agent.Backplane.ChildIO.retire(source.io)

    assert report.close_id == close_id
    assert report.run_id == child_run
    assert report.phase == :closed
    assert report.outcome == :unconfirmed

    assert %{
             "example" => %{
               activation_id: activation_id,
               outcome: :uncertain,
               cleanup: {:ok, connection_report}
             }
           } = report.components

    assert connection_report.activation_id == activation_id
    assert connection_report.outcome == :unconfirmed
    assert {:ok, stdio_report} = connection_report.transport
    assert stdio_report.activation_id == activation_id
    assert stdio_report.phase == :closed
    assert stdio_report.outcome == :unconfirmed
    assert stdio_report.transport == :stdio

    assert Enum.map(stdio_report.resources, &{&1.scope, &1.outcome, &1.error.reason}) == [
             {:direct_child, :uncertain, :missing_waitpid_receipt},
             {:local_pipes, :uncertain, :missing_pipe_receipt},
             {:guardian, :uncertain, :missing_successful_helper_exit}
           ]

    guardian_report = Enum.find(stdio_report.resources, &(&1.scope == :guardian))
    assert guardian_report.evidence.os_pid == guardian_pid
    assert is_integer(guardian_report.evidence.exit_status)
    refute guardian_report.evidence.exit_status == 0
    events = plugin_events(package)
    requests = http_requests(c)
    assert Sigma.Agent.Backplane.ChildIO.retire(source.io) == {:error, original}
    assert plugin_events(package) == events
    assert http_requests(c) == requests

    root = call!(root, function, %{"value" => "root after unconfirmed child retirement"})

    assert data!(root, function) == %{
             "plugin" => "example",
             "value" => "root after unconfirmed child retirement"
           }

    assert plugin_starts(package) == [root_process, child_process]
    assert List.last(plugin_events(package))["pid"] == root_process["pid"]
    assert http_requests(c) == requests
    finish!(root, agent, c)

    # EOF can leave an orphan zombie under the environment's PID 1. Observe
    # non-running separately; neither exit nor fixture cleanup proves reaping.
    assert eventually(fn ->
             case File.read("/proc/#{child_process["pid"]}/stat") do
               {:error, :enoent} ->
                 true

               {:ok, stat} ->
                 [_, fields] = String.split(stat, ") ", parts: 2)
                 fields = String.split(fields)

                 Enum.at(fields, 19) != binding["target"]["start"] or
                   hd(fields) in ["Z", "X"]
             end
           end)
  end

  defp plugin_retirement_proofs!(c, request, mode, path \\ nil) do
    assert {:ok, store} = Store.open(path: path || c.path <> ".runtime")
    assert {:ok, snapshot} = Store.load(store, request["invocation"]["run_id"])

    assert %{
             state: :cancelled,
             outcome: %{"cleanup" => %{"certainty" => "confirmed", "evidence" => evidence}}
           } = snapshot.run

    {plugin, enclosing} =
      case mode do
        :direct ->
          assert [%{"report" => plugin, "effect_down" => true}] = evidence
          {plugin, []}

        :deno ->
          assert [
                   %{
                     "nested" => [%{"report" => plugin, "effect_down" => true}],
                     "retirement_evidence" => [outer],
                     "effect_down" => true,
                     "resources" => "confirmed"
                   }
                 ] = evidence

          assert outer["record_type"] == "code_mode_retirement"
          assert outer["outcome"] == "unknown"
          assert [nested] = outer["nested"]
          assert nested["evidence_digest"] == plugin["retirement_digest"]
          {plugin, [outer]}
      end

    assert plugin["record_type"] == "native_plugin_wait_retirement"
    assert plugin["identity"]["invocation_id"] == request["invocation"]["invocation_id"]
    assert plugin["plugin_request_id"] == request["plugin_request_id"]
    assert plugin["host_request_ref"] == request["id"]
    assert plugin["completion_gate"] == "closed"
    assert plugin["waiter_down"] == true
    assert plugin["local_cleanup"] == "confirmed"
    assert plugin["outcome"] == "unknown"
    [plugin | enclosing]
  end

  defp completion_operation!(c) do
    resources =
      start_supervised!(
        Supervisor.child_spec(
          {CodexResources,
           workspace: c.dir,
           owner_pid: self(),
           plugins: c.config,
           memory_root: Path.join(c.dir, "memories")},
          id: make_ref()
        )
      )

    authority = %{
      caller: "native-plugin-completion",
      run_id: "native-plugin-completion",
      grants: NativeTools.plugin_names(),
      tool_revision: 1
    }

    assert {:ok, binding} = CodexResources.bind(resources, authority)
    assert {:ok, context} = CodexResources.context(resources, binding)

    assert {:ok, profile} =
             NativeTools.profile(context, authority, %{}, tools: NativeTools.plugin_names())

    assert :ok = Session.attach(binding, profile)

    operation = %{
      run_id: binding.run_id,
      incarnation: binding.run_incarnation,
      caller: authority.caller,
      invocation_id: "native-plugin-invocation-#{System.unique_integer([:positive])}",
      tool_call_id: "native-plugin-tool-call",
      plugin_request_id: "public-plugin-request",
      tool_name: @request,
      arguments: arguments("Exact host completion\r\n原文"),
      backend_context: %{plugin_resources: context.plugin_resources}
    }

    {resources, binding, operation}
  end

  defp package!(c, opts \\ []) do
    mcp_log =
      Path.join([
        c.config["requestsRoot"],
        "data",
        Archive.digest(Jason.encode!([c.config["registryUrl"], "plugin-example"])),
        "calls.jsonl"
      ])

    script = "#!#{System.find_executable("python3")}\n" <> plugin_mcp()

    files = %{
      "plugin.json" =>
        Jason.encode!(%{
          "$schema" => "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
          "name" => "example",
          "version" => "1.0.0"
        }),
      "mcp.json" =>
        Jason.encode!(%{
          "$schema" => "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json",
          "mcpServers" => %{
            "example" => %{
              "type" => "stdio",
              "command" => "./mcp-server",
              "args" => ["${PLUGIN_DATA}/calls.jsonl"]
            }
          }
        }),
      "mcp-server" => script,
      "skills/example/SKILL.md" =>
        "---\r\nname: example\r\ndescription: Exact plugin skill\r\n---\r\n" <>
          Keyword.get(opts, :body, "  中文 e\u0301 👩‍💻\r\n"),
      "skills/example/data.txt" => "  完整原文\r\n\n尾行"
    }

    assert {:ok, artifact} = Archive.pack(files, modes: %{"mcp-server" => 0o755})
    digest = Archive.digest(artifact)
    File.write!(Path.join(c.dir, "artifact.tgz"), artifact)

    File.write!(
      Path.join(c.dir, "release.json"),
      Jason.encode!(%{
        "plugin_id" => "plugin-example",
        "release_id" => Keyword.get(opts, :release_id, "release-example"),
        "artifact_digest" => digest
      })
    )

    %{files: files, digest: digest, mcp_log: mcp_log}
  end

  defp package_state(c, installed) do
    paths = Path.wildcard(Path.join(installed["root"], "**/*")) |> Enum.filter(&File.regular?/1)

    Map.new(
      [c.requests, Path.join(c.config["requestsRoot"], "installations.json") | paths],
      &{&1, file_state(&1)}
    )
  end

  defp json_lines(path),
    do: path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  defp plugin_skill?(skill), do: String.starts_with?(skill["reference"], "plugin:")

  defp plugin_function!(provider) do
    assert "tool_search" in names(provider)
    provider = call!(provider, "tool_search", %{"query" => "Exact plugin output"})
    assert [%{"name" => name}] = data!(provider, "tool_search")["tools"]
    assert String.starts_with?(name, "plugin_")
    assert String.ends_with?(name, "::echo")
    assert name in names(provider)
    {provider, name}
  end

  defp plugin_events(package), do: json_lines(package.mcp_log)

  defp plugin_starts(package),
    do: Enum.filter(plugin_events(package), &(&1["event"] == "started"))

  defp os_process?(event), do: File.exists?("/proc/#{event["pid"]}")

  defp plugin_skill!(provider) do
    {provider, skills} = plugin_skills!(provider)
    assert [skill] = skills
    {provider, skill}
  end

  defp plugin_skills!(provider, cursor \\ nil) do
    args = %{"authority" => "executor"}
    args = if cursor, do: Map.put(args, "cursor", cursor), else: args
    provider = call!(provider, "skills::list", args)
    listed = data!(provider, "skills::list")
    skills = Enum.filter(listed["skills"], &plugin_skill?/1)

    case listed["next_cursor"] do
      nil ->
        {provider, skills}

      cursor ->
        {provider, following} = plugin_skills!(provider, cursor)
        {provider, skills ++ following}
    end
  end

  defp plugin_mcp do
    """
    import json,os,sys
    log=sys.argv[1]
    with open(log,'a') as f: f.write(json.dumps({'event':'started','pid':os.getpid()})+'\\n')
    for line in sys.stdin:
        message=json.loads(line)
        if 'id' not in message: continue
        method=message['method']
        if method=='server/discover':
            print(json.dumps({'jsonrpc':'2.0','id':message['id'],'error':{'code':-32601,'message':'Method not found'}}),flush=True)
            continue
        if method=='initialize':
            result={'protocolVersion':'2025-03-26','capabilities':{'tools':{}},'serverInfo':{'name':'example','version':'1.0.0'}}
        elif method=='tools/list':
            result={'tools':[{'name':'echo','description':'Exact plugin output','inputSchema':{'type':'object','properties':{'value':{'type':'string'}},'required':['value']}}]}
        elif method=='tools/call':
            with open(log,'a') as f: f.write(json.dumps({'method':method,'pid':os.getpid(),'arguments':message['params']['arguments']})+'\\n')
            result={'content':[{'type':'text','text':'plugin output'}],'structuredContent':{'plugin':'example',**message['params']['arguments']}}
        else: result={}
        print(json.dumps({'jsonrpc':'2.0','id':message['id'],'result':result}),flush=True)
    """
  end

  defp session!(c, extra \\ []) do
    # Match the Web/Protocol resume hosts: the transcript path connects the
    # Writer, while callers supply the saved history and selected context.
    assert {:ok, snapshot} = Log.snapshot(c.path)

    opts = [
      cwd: c.dir,
      transcript_path: c.path,
      messages: snapshot.messages,
      context_messages: snapshot.context_messages,
      context_window: snapshot.context_window,
      active_leaf: snapshot.active_leaf_id,
      context_revision: length(snapshot.branch_entry_ids),
      context_source: :journal_replay,
      native_tools: true,
      native_memory_root: Path.join(c.dir, "memories"),
      native_plugins: c.config,
      provider: Provider,
      model: %{id: "plugins-test", provider: "plugins-test", api: "openai-responses"},
      tools: [],
      hook_specs: [],
      options: [test_pid: self()]
    ]

    assert {:ok, handle} = Runtime.get_session(c.dir, @root, Keyword.merge(opts, extra))
    assert :ok = Sigma.Agent.subscribe(handle.agent)
    handle.agent
  end

  defp prompt!(agent) do
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "Use the configured plugin host")
    provider!(@root)
  end

  defp provider!(session) do
    receive do
      {:plugins_provider, pid, %{session_id: "child_" <> _} = params} when session == :child ->
        %{pid: pid, params: params}

      {:plugins_provider, pid, %{session_id: ^session} = params} ->
        %{pid: pid, params: params}

      {:turn_error, error} ->
        flunk("plugin turn failed: #{inspect(error)}")
    after
      10_000 -> flunk("plugin Provider did not start for #{session}")
    end
  end

  defp call!(provider, name, arguments) do
    send_call(provider, name, arguments)
    provider!(provider.params.session_id)
  end

  defp install_call!(provider, name, arguments, c) do
    before = if File.exists?(c.requests), do: length(saved!(c)), else: 0
    send_call(provider, name, arguments)
    assert eventually(fn -> File.exists?(c.requests) and length(saved!(c)) == before + 1 end)
    request = List.last(saved!(c))
    assert is_binary(request["plugin_request_id"])
    refute_receive {:plugins_provider, _pid, _params}, 50

    assert {:ok, %{"status" => "installed"}} =
             PluginInstallations.install(c.host, request["id"], :settings)

    provider!(provider.params.session_id)
  end

  defp child_runtime_run!(provider, c) do
    writer = Runtime.lookup(c.dir, @root, :writer)
    assert {:ok, %{admissions: admissions}} = Writer.subagent_state(writer)

    assert [admission] =
             admissions
             |> Map.values()
             |> Enum.filter(fn admission ->
               admission.intent.child_session_id == provider.params.session_id and
                 admission.intent.run_id == provider.params.turn_id
             end)

    run_id = admission.intent.metadata["runtime_run_id"]
    assert is_binary(run_id) and run_id != ""
    run_id
  end

  defp send_call(provider, name, arguments) do
    content = [
      %{
        type: :tool_call,
        id: "plugin-#{System.unique_integer([:positive])}",
        name: name,
        arguments: arguments,
        input_kind: if(is_binary(arguments), do: :custom, else: :function)
      }
    ]

    send(provider.pid, {:plugins_response, content})
  end

  defp finish!(provider, agent, c) do
    send(provider.pid, {:plugins_response, [%{type: :text, text: "done"}]})

    case provider.params.session_id do
      "child_" <> _ = id ->
        host = Runtime.lookup(c.dir, @root, :subagents)

        assert eventually(fn ->
                 assert {:ok, %{subagents: roster}} = Subagents.snapshot(host)

                 Enum.any?(
                   roster.agents,
                   &(&1.child_session_id == id and &1.run_id == provider.params.turn_id and
                       &1.status == :completed)
                 )
               end)

      _ ->
        turn_id = provider.params.turn_id
        assert_receive {:turn_completed, ^turn_id}, 10_000
        assert_receive {:agent_end, _}, 10_000
        assert %{phase: :completed, turn_id: ^turn_id} = Sigma.Agent.status(agent)
    end
  end

  defp result!(provider, name),
    do:
      Enum.find(Enum.reverse(provider.params.context.messages), &(field(&1, :tool_name) == name)) ||
        flunk("missing #{name} result")

  defp data!(provider, name), do: structured!(result!(provider, name))

  defp structured!(message) do
    field(field(message, :metadata) || %{}, :structured_result) ||
      message
      |> field(:content)
      |> Enum.find(&(field(&1, :type) in [:text, "text"]))
      |> field(:text)
      |> Jason.decode!()
  end

  defp expected_catalog(c), do: Map.put(c.catalog, "is_error", false)
  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp names(provider), do: Enum.map(provider.params.context.tools, & &1.name)

  defp arguments(reason),
    do: %{
      "tool_type" => "plugin",
      "action_type" => "install",
      "tool_id" => "plugin-example",
      "suggest_reason" => reason
    }

  defp saved!(c), do: Jason.decode!(File.read!(c.requests))["requests"]

  defp http_requests(c),
    do: c.log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  defp file_state(path) do
    stat = File.stat!(path, time: :posix)
    {File.read!(path), stat.mtime, stat.inode}
  end

  defp assert_previous!(provider, message) do
    restored =
      Enum.find(
        provider.params.context.messages,
        &(field(&1, :tool_call_id) == message.tool_call_id)
      )

    assert restored
    assert field(restored, :content) == message.content

    assert structured!(restored) == structured!(message)
  end

  defp stop_repository(dir) do
    case Runtime.lookup(dir, :supervisor) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
    end
  end

  defp eventually(fun, attempts \\ 500)
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

  defp registry do
    """
    import http.server,json,sys,threading,pathlib,urllib.parse
    response_path,log_path=sys.argv[1:]
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self,*args): pass
        def do_GET(self):
            with open(log_path,'a') as log: log.write(json.dumps({'method':'GET','path':self.path})+'\\n')
            path=urllib.parse.urlsplit(self.path).path
            directory=pathlib.Path(response_path).parent
            if '/artifacts/' in path:
                body=(directory/'artifact.tgz').read_bytes()
                if (directory/'break-native-completion').exists():
                    (directory/'plugins'/'native-installations.etf').mkdir()
                status=200
            else:
                source_path=directory/'release.json' if path.endswith('/resolve') else pathlib.Path(response_path)
                with open(source_path) as source: response=json.load(source)
                body=json.dumps(response,ensure_ascii=False).encode()
                status=response.get('_status',200)
            self.send_response(status)
            self.send_header('content-type','application/octet-stream' if '/artifacts/' in path else 'application/json')
            self.send_header('content-length',str(len(body)))
            self.end_headers()
            self.wfile.write(body)
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
    print(server.server_address[1],flush=True)
    def close_on_eof():
        sys.stdin.buffer.read()
        server.shutdown()
    threading.Thread(target=close_on_eof,daemon=True).start()
    server.serve_forever()
    server.server_close()
    """
  end
end
