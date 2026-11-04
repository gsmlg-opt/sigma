defmodule Sigma.Agent.BackplaneMcpResourcesTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.Runtime

  @moduletag :tmp_dir

  defmodule Provider do
    @behaviour Sigma.Ai.Provider
    def stream(params) do
      send(params.options[:test_pid], {:resource_provider, self(), params})

      receive do
        {:resource_response, content} ->
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
    python = System.find_executable("python3")
    assert python
    fixture = Path.join(dir, "resources.py")
    log = Path.join(dir, "requests.jsonl")
    File.write!(fixture, fixture())

    servers =
      Map.new(["beta", "alpha"], fn name ->
        {name, %{"type" => "stdio", "command" => python, "args" => ["-u", fixture, name, log]}}
      end)

    assert {:ok, handle} =
             Runtime.get_session(dir, "resources",
               cwd: dir,
               transcript_path: Path.join(dir, "resources.jsonl"),
               native_tools: true,
               provider: Provider,
               model: %{id: "test", provider: "test", api: "openai-responses"},
               mcp_servers: servers,
               tools: [],
               hook_specs: [],
               options: [test_pid: self()]
             )

    Sigma.Agent.subscribe(handle.agent)

    assert :sys.get_state(handle.agent).mcp_session.clients |> Map.keys() |> Enum.sort() ==
             ["alpha", "beta"]

    on_exit(fn ->
      case Runtime.lookup(dir, :supervisor) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
      end
    end)

    {:ok, agent: handle.agent, dir: dir, log: log, gate: log <> ".release"}
  end

  test "real configured MCP clients expose resources, templates, pagination and read results through Engine",
       ctx do
    prompt!(ctx.agent)
    {provider, params} = provider!()

    assert Enum.sort(Enum.map(params.context.tools, & &1.name)) ==
             Enum.sort(
               Sigma.Agent.Backplane.NativeTools.names() ++
                 Sigma.Agent.Backplane.NativeTools.environment_names() ++
                 Sigma.Agent.Backplane.NativeTools.async_names() ++
                 Sigma.Agent.Backplane.NativeTools.skill_names() ++
                 Sigma.Agent.Backplane.NativeTools.memory_names() ++
                 Sigma.Agent.Backplane.NativeTools.archive_names() ++
                 Sigma.Agent.Backplane.NativeTools.goal_names() ++
                 Sigma.Agent.Backplane.NativeTools.board_names() ++
                 Sigma.Agent.Backplane.NativeTools.resource_names() ++
                 Sigma.Agent.Subagents.collaboration_tools()
             )

    {provider, result} = call!(ctx.agent, provider, "list_mcp_resources", %{})

    assert Enum.map(result["resources"], &{&1["server"], &1["uri"]}) ==
             [
               {"alpha", "mem://alpha/one"},
               {"alpha", "mem://alpha/two"},
               {"beta", "mem://beta/one"},
               {"beta", "mem://beta/two"}
             ]

    refute Map.has_key?(result, "nextCursor")
    {provider, result} = call!(ctx.agent, provider, "list_mcp_resources", %{"server" => "alpha"})
    assert result["server"] == "alpha"
    assert result["nextCursor"] == "alpha:two"

    {provider, result} =
      call!(ctx.agent, provider, "list_mcp_resources", %{
        "server" => " alpha ",
        "cursor" => result["nextCursor"]
      })

    assert [%{"uri" => "mem://alpha/two", "server" => "alpha"}] = result["resources"]
    {provider, result} = call!(ctx.agent, provider, "list_mcp_resource_templates", %{})

    assert Enum.map(result["resourceTemplates"], & &1["server"]) == [
             "alpha",
             "alpha",
             "beta",
             "beta"
           ]

    {provider, result} =
      call!(ctx.agent, provider, "list_mcp_resource_templates", %{"server" => "beta"})

    assert result["server"] == "beta"
    assert result["nextCursor"] == "beta:two"

    {provider, result} =
      call!(ctx.agent, provider, "list_mcp_resource_templates", %{
        "server" => "beta",
        "cursor" => result["nextCursor"]
      })

    assert [%{"uriTemplate" => "mem://beta/second/{name}", "server" => "beta"}] =
             result["resourceTemplates"]

    {provider, result} =
      call!(ctx.agent, provider, "read_mcp_resource", %{
        "server" => "alpha",
        "uri" => "mem://alpha/one"
      })

    assert result["server"] == "alpha"
    assert result["uri"] == "mem://alpha/one"
    assert [%{"text" => "alpha content", "uri" => "mem://alpha/one"}] = result["contents"]

    {provider, result} =
      call!(ctx.agent, provider, "read_mcp_resource", %{
        "server" => " beta ",
        "uri" => " mem://beta/blob "
      })

    assert [%{"blob" => "AAEC/w==", "mimeType" => "application/octet-stream"}] =
             result["contents"]

    assert result["uri"] == "mem://beta/blob"
    finish!(provider)
  end

  test "cancellation confirms local DynamicRuntime exit and discards a late remote read", ctx do
    prompt!(ctx.agent)
    {provider, _} = provider!()
    host = Runtime.lookup(ctx.dir, "resources", :subagents)
    resources = :sys.get_state(host).codex_resources
    dynamic = :sys.get_state(resources).dynamic_runtime
    monitor = Process.monitor(dynamic)
    turn_id = Sigma.Agent.status(ctx.agent).turn_id

    send(
      provider,
      {:resource_response,
       [
         tool_call("read_mcp_resource", %{
           "server" => "alpha",
           "uri" => "mem://alpha/blocked"
         })
       ]}
    )

    await_request!(ctx.log, "mem://alpha/blocked")
    assert {:cancelling, _} = Sigma.Agent.cancel(ctx.agent)
    assert_receive {:agent_end, _}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^dynamic, _}, 5_000

    assert {:error, %Backplane.AgentRuntime.Error{class: :cancelled}} =
             GenServer.call(ctx.agent, {:native_mcp_clients, turn_id})

    File.write!(ctx.gate, "release")
    prompt!(ctx.agent)
    {provider, _} = provider!()
    next_resources = :sys.get_state(host).codex_resources
    refute :sys.get_state(next_resources).dynamic_runtime == dynamic

    {provider, result} =
      call!(ctx.agent, provider, "read_mcp_resource", %{
        "server" => "alpha",
        "uri" => "mem://alpha/one"
      })

    assert inspect(result) =~ "alpha content"

    refute Enum.any?(:sys.get_state(ctx.agent).messages, fn message ->
             message.role == :tool_result and inspect(message.content) =~ "late remote content"
           end)

    finish!(provider)
  end

  test "Code Mode nests real resource reads and fresh clients remain usable after reload across turns",
       ctx do
    prompt!(ctx.agent)
    {provider, _} = provider!()

    {provider, result} =
      call!(
        ctx.agent,
        provider,
        "exec",
        "text(await tools.read_mcp_resource({server: 'beta', uri: 'mem://beta/one'}));"
      )

    assert result["status"] == "completed"
    assert inspect(result["output"]) =~ "beta content"
    assert {:ok, 0} = Sigma.Agent.reload_mcp_tools(ctx.agent)

    {provider, result} =
      call!(ctx.agent, provider, "read_mcp_resource", %{
        "server" => "alpha",
        "uri" => "mem://alpha/one"
      })

    assert inspect(result) =~ "alpha content"
    finish!(provider)
    prompt!(ctx.agent)
    {provider, _} = provider!()

    {provider, result} =
      call!(ctx.agent, provider, "read_mcp_resource", %{
        "server" => "beta",
        "uri" => "mem://beta/one"
      })

    assert inspect(result) =~ "beta content"
    requests = File.read!(ctx.log) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.count(requests, &(&1["method"] == "initialize")) == 4
    finish!(provider)
  end

  test "cursor misuse, unknown servers and failed reads return tool errors without dispatching elsewhere",
       ctx do
    prompt!(ctx.agent)
    {provider, _} = provider!()

    {provider, result} =
      call!(ctx.agent, provider, "list_mcp_resources", %{"cursor" => "unbound"})

    assert result["error"]["message"] == "cursor can only be used when a server is specified"
    assert last_result(ctx.agent).is_error

    {provider, result} =
      call!(ctx.agent, provider, "read_mcp_resource", %{
        "server" => "unknown",
        "uri" => "mem://alpha/one"
      })

    assert result["error"]["class"] == "not_found"

    {provider, result} =
      call!(ctx.agent, provider, "read_mcp_resource", %{
        "server" => "alpha",
        "uri" => "mem://alpha/missing"
      })

    assert result["error"]["message"] =~ "missing resource"
    finish!(provider)
  end

  defp prompt!(agent), do: assert({:accepted, _} = Sigma.Agent.prompt(agent, "resources"))

  defp provider! do
    assert_receive {:resource_provider, pid, params}, 8_000
    {pid, params}
  end

  defp call!(agent, provider, name, input) do
    send(provider, {:resource_response, [tool_call(name, input)]})
    {provider, _} = provider!()
    {provider, last_result(agent).metadata.structured_result}
  end

  defp tool_call(name, input) do
    %{
      type: :tool_call,
      id: "resource-#{System.unique_integer([:positive])}",
      name: name,
      arguments: input,
      input_kind: if(is_binary(input), do: :custom, else: :function)
    }
  end

  defp await_request!(log, uri, attempts \\ 200)
  defp await_request!(_log, _uri, 0), do: flunk("MCP resource read did not reach server")

  defp await_request!(log, uri, attempts) do
    if File.read!(log) =~ uri do
      :ok
    else
      Process.sleep(10)
      await_request!(log, uri, attempts - 1)
    end
  end

  defp last_result(agent),
    do: :sys.get_state(agent).messages |> Enum.reverse() |> Enum.find(&(&1.role == :tool_result))

  defp finish!(provider) do
    send(provider, {:resource_response, [%{type: :text, text: "done"}]})
    assert_receive {:agent_end, _}, 5_000
  end

  defp fixture do
    ~S"""
    import json, sys, os, time
    server, log = sys.argv[1:]
    for line in sys.stdin:
        message = json.loads(line)
        method, ident = message.get("method"), message.get("id")
        with open(log, "a") as output:
            output.write(json.dumps({"server": server, "method": method, "params": message.get("params")}) + "\n")
        if ident is None:
            continue
        params = message.get("params", {})
        if method == "initialize":
            result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}, "resources": {}}, "serverInfo": {"name": server, "version": "1"}}
        elif method == "tools/list":
            result = {"tools": []}
        elif method in ["resources/list", "resources/templates/list"]:
            second = params.get("cursor") == server + ":two"
            if method == "resources/list":
                result = {"resources": [{"uri": "mem://" + server + ("/two" if second else "/one"), "name": "Second" if second else "First"}]}
            else:
                result = {"resourceTemplates": [{"uriTemplate": "mem://" + server + ("/second/{name}" if second else "/{name}"), "name": "Template"}]}
            if not second:
                result["nextCursor"] = server + ":two"
        elif method == "resources/read":
            uri = params["uri"]
            if uri.endswith("/blocked"):
                while not os.path.exists(log + ".release"):
                    time.sleep(0.01)
                result = {"contents": [{"uri": uri, "text": "late remote content"}]}
            elif uri.endswith("/blob"):
                result = {"contents": [{"blob": "AAEC/w==", "mimeType": "application/octet-stream"}]}
            else:
                result = {"contents": [{"uri": uri, "text": server + " content"}]}
            if uri.endswith("/missing"):
                print(json.dumps({"jsonrpc": "2.0", "id": ident, "error": {"code": -32002, "message": "missing resource"}}), flush=True)
                continue
        else:
            print(json.dumps({"jsonrpc": "2.0", "id": ident, "error": {"code": -32601, "message": "Method not found"}}), flush=True)
            continue
        print(json.dumps({"jsonrpc": "2.0", "id": ident, "result": result}), flush=True)
    """
  end
end
