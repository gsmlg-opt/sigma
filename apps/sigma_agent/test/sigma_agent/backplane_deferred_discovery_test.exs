defmodule Sigma.Agent.BackplaneDeferredDiscoveryTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex.DynamicRuntime
  alias Sigma.Agent.Runtime
  alias Sigma.Agent.Backplane.{CodexResources, NativeTools, ToolCatalog}
  alias Sigma.Coding.Hooks.Discovery

  @moduletag :tmp_dir
  @tool "mcp__vault__fetch_item"

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def output_token_limit(_model, _options), do: 2_000

    @impl true
    def stream(params) do
      send(params.options[:test_pid], {:discovery_provider, self(), params})

      receive do
        {:discovery_response, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            content: content,
            stop_reason: reason,
            usage: %{input: 1, output: 1, total_tokens: 2, cost: %{total: 0.0}},
            model: "discovery",
            provider: "discovery",
            api: "openai-responses",
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, reason, message}]
      end
    end
  end

  setup %{tmp_dir: dir} do
    python = System.find_executable("python3")
    assert python, "real deferred MCP discovery requires Python"
    fixture = Path.join(dir, "vault.py")
    inventory = Path.join(dir, "inventory.json")
    log = Path.join(dir, "requests.jsonl")
    File.write!(fixture, fixture())
    File.write!(inventory, Jason.encode!([definition("fetch_item")]))
    File.write!(log, "")

    on_exit(fn ->
      File.write!(log <> ".release", "release")

      case Runtime.lookup(dir, :supervisor) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
      end
    end)

    {:ok,
     dir: dir,
     inventory: inventory,
     log: log,
     servers: %{
       "vault" => %{
         "type" => "stdio",
         "command" => python,
         "args" => ["-u", fixture, inventory, log]
       }
     }}
  end

  test "real MCP metadata discovery publishes only matches and executes through the current catalog",
       c do
    agent = session!(c)
    prompt!(agent)
    {provider, initial} = provider!()
    assert "tool_search" in names(initial)
    refute @tool in names(initial)
    refute Enum.any?(requests(c.log), &(&1["method"] == "tools/call"))

    {provider, found} =
      call!(agent, provider, "tool_search", %{"query" => "encrypted credential"})

    assert [%{"name" => @tool}] = result(agent)["tools"]
    assert found.context.catalog_revision > initial.context.catalog_revision
    assert @tool in names(found)

    assert Enum.find(found.context.tools, &(&1.name == @tool)).parameters ==
             definition("fetch_item")["inputSchema"]

    {provider, _} = call!(agent, provider, @tool, %{"key" => "secret-one"})
    refute last_result(agent).is_error
    assert inspect(last_result(agent).content) =~ "vault:secret-one"

    assert [%{"params" => %{"name" => "fetch_item", "arguments" => %{"key" => "secret-one"}}}] =
             Enum.filter(requests(c.log), &(&1["method"] == "tools/call"))

    {provider, _} = call!(agent, provider, "get_context_remaining", %{})
    assert is_integer(result(agent)["tokens_left"])
    assert result(agent)["tokens_left"] > 0
    finish!(provider)

    prompt!(agent)
    {provider, next_run} = provider!()
    refute @tool in names(next_run)
    {provider, _} = call!(agent, provider, "tool_search", %{"query" => "encrypted credential"})
    assert [%{"name" => @tool}] = result(agent)["tools"]
    {provider, _} = call!(agent, provider, @tool, %{"key" => "secret-two"})
    assert inspect(last_result(agent).content) =~ "vault:secret-two"
    finish!(provider)
  end

  test "Code Mode searches actual MCP metadata and the next cell executes the newly admitted tool",
       c do
    agent = session!(c)
    prompt!(agent)
    {provider, _} = provider!()

    {provider, after_search} =
      call!(
        agent,
        provider,
        "exec",
        "return await tools.tool_search({query:'encrypted credential'});"
      )

    assert result(agent)["status"] == "completed"
    assert [%{"name" => @tool}] = result(agent)["value"]["tools"]
    assert @tool in names(after_search)

    {provider, _} =
      call!(agent, provider, "exec", "text(await tools.mcp__vault__fetch_item({key:'nested'}));")

    assert result(agent)["status"] == "completed"
    assert inspect(result(agent)["output"]) =~ "vault:nested"
    assert length(Enum.filter(requests(c.log), &(&1["method"] == "tools/call"))) == 1
    finish!(provider)
  end

  test "collaboration remains callable after discovery extends the catalog authority", c do
    agent = session!(c)
    prompt!(agent)
    {provider, _} = provider!()
    {provider, _} = call!(agent, provider, "tool_search", %{"query" => "encrypted credential"})
    assert [%{"name" => @tool}] = result(agent)["tools"]
    {provider, _} = call!(agent, provider, "list_agents", %{})
    refute last_result(agent).is_error
    finish!(provider)
  end

  test "discovered MCP execution retains Dispatcher permissions and each pre and post hook", c do
    pre = Path.join(c.dir, "pre.jsonl")
    post = Path.join(c.dir, "post.jsonl")
    test = self()
    hooks = hook_specs(pre, post)

    agent =
      session!(c,
        hook_specs: hooks,
        permission_config: %{default: :allow, rules: %{@tool => :ask}},
        dispatcher_opts: [
          permission_request_fn: fn call ->
            send(test, {:discovered_permission, call})
            :allow
          end
        ]
      )

    prompt!(agent)
    {provider, _} = provider!()
    {provider, _} = call!(agent, provider, "tool_search", %{"query" => "encrypted credential"})
    refute_receive {:discovered_permission, _}, 0
    refute File.exists?(pre)
    refute File.exists?(post)

    {provider, _} = call!(agent, provider, @tool, %{"key" => "approved"})
    assert_receive {:discovered_permission, %{name: @tool, arguments: %{"key" => "approved"}}}
    refute_receive {:discovered_permission, _}, 0
    assert [%{"tool_name" => @tool, "tool_input" => %{"key" => "approved"}}] = json_lines(pre)
    assert [%{"tool_name" => @tool, "tool_input" => %{"key" => "approved"}}] = json_lines(post)
    assert length(Enum.filter(requests(c.log), &(&1["method"] == "tools/call"))) == 1
    finish!(provider)
  end

  test "a discovered MCP call still obeys current permission denial without a remote effect", c do
    agent = session!(c, permission_config: %{default: :allow, rules: %{@tool => :deny}})
    prompt!(agent)
    {provider, _} = provider!()
    {provider, _} = call!(agent, provider, "tool_search", %{"query" => "encrypted credential"})
    assert [%{"name" => @tool}] = result(agent)["tools"]
    {provider, _} = call!(agent, provider, @tool, %{"key" => "must-not-run"})
    assert last_result(agent).is_error
    refute Enum.any?(requests(c.log), &(&1["method"] == "tools/call"))
    finish!(provider)
  end

  test "the next generation snapshots refreshed actual MCP inventory", c do
    agent = session!(c)
    prompt!(agent)
    {provider, _} = provider!()
    {provider, _} = call!(agent, provider, "tool_search", %{"query" => "encrypted credential"})
    assert [%{"name" => @tool}] = result(agent)["tools"]
    finish!(provider)

    File.write!(c.inventory, Jason.encode!([definition("replacement")]))
    assert {:ok, 1} = Sigma.Agent.reload_mcp_tools(agent)
    prompt!(agent)
    {provider, initial} = provider!()
    refute @tool in names(initial)
    refute "mcp__vault__replacement" in names(initial)
    {provider, _} = call!(agent, provider, "tool_search", %{"query" => "encrypted credential"})
    assert [%{"name" => "mcp__vault__replacement"}] = result(agent)["tools"]
    {provider, _} = call!(agent, provider, "mcp__vault__replacement", %{"key" => "fresh"})
    assert inspect(last_result(agent).content) =~ "vault:fresh"
    finish!(provider)
  end

  test "inventories larger than fifty remain searchable without exposing the full catalog", c do
    definitions = [
      definition("fetch_item")
      | Enum.map(1..60, fn index ->
          %{
            definition("opaque_#{index}")
            | "description" => "Weather measurements for station #{index}"
          }
        end)
    ]

    File.write!(c.inventory, Jason.encode!(definitions))
    agent = session!(c)
    prompt!(agent)
    {provider, initial} = provider!()
    refute Enum.any?(names(initial), &String.starts_with?(&1, "mcp__"))

    {provider, found} =
      call!(agent, provider, "tool_search", %{"query" => "encrypted credential"})

    matches = Enum.map(result(agent)["tools"], & &1["name"])
    assert [@tool | _] = matches
    assert length(matches) <= 8

    assert Enum.sort(Enum.filter(names(found), &String.starts_with?(&1, "mcp__"))) ==
             Enum.sort(matches)

    finish!(provider)
  end

  test "a guessed MCP call in the search batch cannot execute before publication", c do
    agent = session!(c)
    prompt!(agent)
    {provider, _} = provider!()

    send(
      provider,
      {:discovery_response,
       [
         tool_call("tool_search", %{"query" => "encrypted credential"}),
         tool_call(@tool, %{"key" => "premature"})
       ]}
    )

    {provider, next} = provider!()
    assert last_result(agent).is_error
    assert @tool in names(next)
    refute Enum.any?(requests(c.log), &(&1["method"] == "tools/call"))
    finish!(provider)
  end

  test "legacy sessions keep configured MCP tools eager", c do
    agent = session!(c, native_tools: false)
    prompt!(agent)
    {provider, params} = provider!()
    assert @tool in names(params)
    refute "tool_search" in names(params)
    {provider, _} = call!(agent, provider, @tool, %{"key" => "legacy"})
    assert inspect(last_result(agent).content) =~ "vault:legacy"
    finish!(provider)
  end

  test "cancelling a discovered remote call discards its late result and the next run discovers afresh",
       c do
    agent = session!(c)
    prompt!(agent)
    {provider, _} = provider!()
    {provider, _} = call!(agent, provider, "tool_search", %{"query" => "encrypted credential"})
    send(provider, {:discovery_response, [tool_call(@tool, %{"key" => "blocked"})]})
    await_remote_call!(c.log, "blocked")
    assert {:cancelling, _} = Sigma.Agent.cancel(agent)
    assert_receive {:agent_end, _}, 8_000
    File.write!(c.log <> ".release", "release")

    prompt!(agent)
    {provider, initial} = provider!()
    refute @tool in names(initial)
    {provider, _} = call!(agent, provider, "tool_search", %{"query" => "encrypted credential"})
    assert [%{"name" => @tool}] = result(agent)["tools"]
    {provider, _} = call!(agent, provider, @tool, %{"key" => "after-cancel"})
    assert inspect(last_result(agent).content) =~ "vault:after-cancel"

    refute Enum.any?(Sigma.Agent.messages(agent), fn message ->
             message.role == :tool_result and inspect(message.content) =~ "vault:blocked"
           end)

    finish!(provider)
  end

  test "search can be selected independently of MCP resource clients and stale resource bindings are rejected",
       c do
    resources = start_supervised!({CodexResources, workspace: c.dir, owner_pid: self()})

    authority = %{
      caller: "discovery-owner",
      run_id: "discovery-run",
      grants: ["tool_search"],
      tool_revision: 1
    }

    assert {:ok, binding} = CodexResources.bind(resources, authority)

    tool = %Sigma.Coding.MCP.Tool{
      name: @tool,
      description: "Read an encrypted credential",
      schema: definition("fetch_item")["inputSchema"],
      server_id: "vault",
      server_tool_name: "fetch_item"
    }

    assert {:ok, candidates} =
             apply(ToolCatalog, :deferred_candidates, [
               [tool],
               fn _ -> flunk("preparation cannot dispatch") end
             ])

    assert {:ok, context} =
             apply(CodexResources, :context, [resources, binding, [candidates: candidates]])

    assert {:ok, profile} =
             NativeTools.profile(context, authority, %{hook_specs: []}, tools: ["tool_search"])

    assert Map.keys(profile.registry.tools) == ["tool_search"]

    assert {:ok, same} =
             apply(CodexResources, :context, [resources, binding, [candidates: candidates]])

    assert same.dynamic_runtime == context.dynamic_runtime

    assert {:error, %{class: :forbidden}} =
             apply(CodexResources, :context, [
               resources,
               %{binding | run_id: "foreign-run"},
               [candidates: candidates]
             ])

    monitor = Process.monitor(context.dynamic_runtime)
    assert {:ok, %{status: :confirmed}} = CodexResources.close(resources)
    assert_receive {:DOWN, ^monitor, :process, _, _}
    refute Process.alive?(context.dynamic_runtime)
    assert DynamicRuntime.contracts(%{}) == []
  end

  defp session!(c, opts \\ []) do
    assert {:ok, handle} =
             Runtime.get_session(
               c.dir,
               "discovery",
               Keyword.merge(
                 [
                   cwd: c.dir,
                   transcript_path: Path.join(c.dir, "discovery.jsonl"),
                   native_tools: true,
                   provider: Provider,
                   model: %{
                     id: "discovery",
                     provider: "discovery",
                     api: "openai-responses",
                     context_window: 100_000
                   },
                   mcp_servers: c.servers,
                   tools: [],
                   hook_specs: [],
                   options: [test_pid: self()]
                 ],
                 opts
               )
             )

    assert :ok = Sigma.Agent.subscribe(handle.agent)
    handle.agent
  end

  defp prompt!(agent),
    do: assert({:accepted, _} = Sigma.Agent.prompt(agent, "discover credentials"))

  defp provider! do
    assert_receive {:discovery_provider, provider, params}, 8_000
    {provider, params}
  end

  defp call!(_agent, provider, name, input) do
    send(provider, {:discovery_response, [tool_call(name, input)]})
    provider!()
  end

  defp tool_call(name, input),
    do: %{
      type: :tool_call,
      id: "discovery-#{System.unique_integer([:positive])}",
      name: name,
      arguments: input,
      input_kind: if(is_binary(input), do: :custom, else: :function)
    }

  defp names(params), do: Enum.map(params.context.tools, & &1.name)

  defp last_result(agent),
    do: Sigma.Agent.messages(agent) |> Enum.reverse() |> Enum.find(&(&1.role == :tool_result))

  defp result(agent), do: last_result(agent).metadata.structured_result
  defp requests(log), do: json_lines(log)

  defp json_lines(path),
    do: path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  defp finish!(provider) do
    send(provider, {:discovery_response, [%{type: :text, text: "done"}]})
    assert_receive {:agent_end, _}, 5_000
  end

  defp definition(name),
    do: %{
      "name" => name,
      "description" => "Read an encrypted credential value from the vault by key.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "key" => %{"type" => "string", "description" => "Credential identifier"}
        },
        "required" => ["key"],
        "additionalProperties" => false
      }
    }

  defp hook_specs(pre, post) do
    groups =
      Map.new([{"PreToolUse", pre}, {"PostToolUse", post}], fn {event, path} ->
        {event,
         [
           %{
             "matcher" => @tool,
             "hooks" => [
               %{
                 "type" => "command",
                 "command" =>
                   "cat >> " <> quote_path(path) <> "; printf '\\n' >> " <> quote_path(path)
               }
             ]
           }
         ]}
      end)

    assert {:ok, specs} = Discovery.parse(Jason.encode!(%{"hooks" => groups}), :claude)
    Enum.map(specs, &%{&1 | origin: {:user, "discovery-test"}, trusted?: true})
  end

  defp quote_path(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"

  defp await_remote_call!(log, key, attempts \\ 200)
  defp await_remote_call!(_log, _key, 0), do: flunk("MCP fixture did not receive discovered call")

  defp await_remote_call!(log, key, attempts) do
    if Enum.any?(
         requests(log),
         &(&1["method"] == "tools/call" and get_in(&1, ["params", "arguments", "key"]) == key)
       ) do
      :ok
    else
      Process.sleep(10)
      await_remote_call!(log, key, attempts - 1)
    end
  end

  defp fixture do
    ~S"""
    import json, sys, os, time
    inventory, log = sys.argv[1:]
    for line in sys.stdin:
        message = json.loads(line)
        method, ident = message.get("method"), message.get("id")
        params = message.get("params", {})
        with open(log, "a") as output:
            output.write(json.dumps({"method": method, "params": params}) + "\n")
        if ident is None:
            continue
        if method == "initialize":
            result = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "vault", "version": "1"}}
        elif method == "tools/list":
            with open(inventory) as source:
                result = {"tools": json.load(source)}
        elif method == "tools/call":
            if params["arguments"]["key"] == "blocked":
                while not os.path.exists(log + ".release"):
                    time.sleep(0.01)
            result = {"content": [{"type": "text", "text": "vault:" + params["arguments"]["key"]}], "isError": False}
        else:
            print(json.dumps({"jsonrpc": "2.0", "id": ident, "error": {"code": -32601, "message": "Method not found"}}), flush=True)
            continue
        print(json.dumps({"jsonrpc": "2.0", "id": ident, "result": result}), flush=True)
    """
  end
end
