defmodule Sigma.Agent.BackplaneChildMcpDiscoveryTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex.Session
  alias Backplane.AgentRuntime.Error
  alias Sigma.Agent.Backplane.ChildIO
  alias Sigma.Agent.{Runtime, Subagents}

  @moduletag :tmp_dir
  @tool "mcp__vault__fetch_item"
  @resources ~w(list_mcp_resources list_mcp_resource_templates read_mcp_resource)

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    def output_token_limit(_model, _options), do: 2_000

    def stream(params) do
      send(params.options[:test_pid], {:child_mcp_provider, self(), params})

      receive do
        {:child_mcp_response, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            content: content,
            stop_reason: reason,
            usage: %{input: 1, output: 1, total_tokens: 2, cost: %{total: 0.0}},
            model: "child-mcp",
            provider: "child-mcp",
            api: "openai-responses",
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, reason, message}]
      end
    end
  end

  setup %{tmp_dir: dir} = tags do
    python = System.find_executable("python3")
    assert python, "managed child MCP integration requires Python"
    fixture = Path.join(dir, "vault.py")
    log = Path.join(dir, "mcp-requests.jsonl")
    File.write!(fixture, fixture())
    File.write!(log, "")

    assert {:ok, handle} =
             Runtime.get_session(dir, "child-mcp-root",
               cwd: dir,
               transcript_path: Path.join(dir, "root.jsonl"),
               native_tools: true,
               native_memory_root: Path.join(dir, "memories"),
               provider: Provider,
               model: %{
                 id: "child-mcp",
                 provider: "child-mcp",
                 api: "openai-responses",
                 context_window: 100_000
               },
               tools: [],
               hook_specs: [],
               permission_config:
                 Map.get(tags, :permission_config, %{default: :allow, rules: %{}}),
               options: [test_pid: self()],
               mcp_servers: %{
                 "vault" => %{
                   "type" => "stdio",
                   "command" => python,
                   "args" => ["-u", fixture, log]
                 }
               }
             )

    assert :ok = Sigma.Agent.subscribe(handle.agent)

    on_exit(fn ->
      case Runtime.lookup(dir, :supervisor) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
      end
    end)

    {:ok, agent: handle.agent, host: Runtime.lookup(dir, "child-mcp-root", :subagents), log: log}
  end

  @tag :child_deferred_mcp_functional
  test "published MCP functions execute in a managed child and its real Deno followup", c do
    root = prompt!(c.agent)
    root = call!(root, "tool_search", %{"query" => "encrypted credential"})
    {child, root} = spawn!(root)

    refute @tool in names(child)
    assert "tool_search" in names(child)
    child = call!(child, "tool_search", %{"query" => "encrypted credential"})
    assert [%{"name" => @tool}] = structured!(child, "tool_search")["tools"]
    assert @tool in names(child)
    child = call!(child, @tool, %{"key" => "published-child"})
    assert inspect(result!(child, @tool).content) =~ "vault:published-child"
    finish!(child, c)

    send_call(root, "followup_task", %{"target" => "/root/vault", "message" => "fetch again"})
    next = provider!(child.params.session_id)
    root = provider!(root.params.session_id)

    refute @tool in names(next)
    assert "tool_search" in names(next)
    next = call!(next, "tool_search", %{"query" => "encrypted credential"})
    assert [%{"name" => @tool}] = structured!(next, "tool_search")["tools"]

    next =
      call!(
        next,
        "exec",
        "return await tools.mcp__vault__fetch_item({key:'published-followup'});"
      )

    assert inspect(structured!(next, "exec")["value"]) =~ "vault:published-followup"
    assert Enum.count(requests(c.log), &(&1["method"] == "initialize")) == 1
    assert Enum.count(requests(c.log), &(&1["method"] == "tools/call")) == 2
    finish!(next, c)
    finish!(root, c)
  end

  @tag :child_deferred_mcp_functional
  test "a root's published MCP grant reaches a real managed child's executable catalog", c do
    root = prompt!(c.agent)
    assert "tool_search" in names(root)
    refute @tool in names(root)

    root = call!(root, "tool_search", %{"query" => "encrypted credential"})
    assert [%{"name" => @tool}] = structured!(root, "tool_search")["tools"]
    assert @tool in names(root)
    {child, root} = spawn!(root)

    refute @tool in names(child)
    assert "tool_search" in names(child)
    child = call!(child, "tool_search", %{"query" => "encrypted credential"})
    assert [%{"name" => @tool}] = structured!(child, "tool_search")["tools"]

    assert @tool in names(child),
           "root publication must survive manager admission and child grant attenuation"

    definition = Enum.find(child.params.context.tools, &(&1.name == @tool))

    assert definition.description ==
             "Read an encrypted credential value from the vault by key."

    assert definition.parameters == %{
             "type" => "object",
             "properties" => %{"key" => %{"type" => "string"}},
             "required" => ["key"],
             "additionalProperties" => false
           }

    child = call!(child, @tool, %{"key" => "inherited"})
    refute result!(child, @tool).is_error
    assert inspect(result!(child, @tool).content) =~ "vault:inherited"
    child = call!(child, "list_agents", %{})
    refute result!(child, "list_agents").is_error
    assert Enum.count(requests(c.log), &(&1["method"] == "initialize")) == 1
    assert Enum.count(requests(c.log), &(&1["method"] == "tools/call")) == 1
    finish!(child, c)
    finish!(root, c)
  end

  @tag :child_deferred_mcp_functional
  @tag :child_catalog_context_functional
  test "child context accounting includes the MCP catalog published to the actual provider", c do
    root = prompt!(c.agent)
    root = call!(root, "tool_search", %{"query" => "encrypted credential"})
    {child, root} = spawn!(root)
    initial_tools = child.params.context.tools
    child = call!(child, "tool_search", %{"query" => "encrypted credential"})
    assert @tool in names(child)

    item =
      c.host
      |> :sys.get_state()
      |> Map.fetch!(:children)
      |> Map.values()
      |> Enum.find(&(&1.identity.child_session_id == child.params.session_id))

    assert item
    key = {item.identity.run_id, item.identity.incarnation}
    context = child.params.context

    remaining = fn tools ->
      Sigma.Agent.ContextPolicy.snapshot(
        model: child.params.model,
        system: context.system,
        messages: context.messages,
        tools: tools
      )
      |> Sigma.Agent.Backplane.ContextControls.tokens_left(
        model: child.params.model,
        output_reserve: 2_000
      )
    end

    expected = remaining.(context.tools)
    assert is_integer(expected)
    refute expected == remaining.(initial_tools)
    assert GenServer.call(item.io, {:context_remaining, key}) == expected
    finish!(child, c)
    finish!(root, c)
  end

  @tag :child_deferred_mcp_functional
  @tag :child_mcp_unsearched_functional
  test "managed child resource calls reuse the root's actual connected MCP client", c do
    root = prompt!(c.agent)
    assert Enum.all?(@resources, &(&1 in names(root)))
    root = call!(root, "list_mcp_resources", %{"server" => "vault"})

    assert [%{"server" => "vault", "uri" => "vault://credential"}] =
             structured!(root, "list_mcp_resources")["resources"]

    {child, root} = spawn!(root)

    refute "tool_search" in names(child)
    refute @tool in names(child)

    assert Enum.all?(@resources, &(&1 in names(child))),
           "authorized child MCP resource profiles require a trusted inherited client getter"

    child = call!(child, "list_mcp_resource_templates", %{"server" => "vault"})

    assert [%{"server" => "vault", "uriTemplate" => "vault://{key}"}] =
             structured!(child, "list_mcp_resource_templates")["resourceTemplates"]

    child =
      call!(child, "read_mcp_resource", %{"server" => "vault", "uri" => "vault://credential"})

    assert [%{"uri" => "vault://credential", "text" => "resource:credential"}] =
             structured!(child, "read_mcp_resource")["contents"]

    assert Enum.count(requests(c.log), &(&1["method"] == "initialize")) == 1
    assert Enum.count(requests(c.log), &(&1["method"] == "resources/read")) == 1
    finish!(child, c)
    finish!(root, c)
  end

  @tag :child_deferred_mcp_functional
  @tag :child_mcp_unsearched_functional
  test "a real child Deno cell reads resources through its inherited connected client", c do
    root = prompt!(c.agent)
    {child, root} = spawn!(root)

    child =
      call!(
        child,
        "exec",
        "return await tools.read_mcp_resource({server:'vault',uri:'vault://credential'});"
      )

    refute result!(child, "exec").is_error

    assert %{"status" => "completed", "value" => %{"contents" => [content]}} =
             structured!(child, "exec")

    assert content["text"] == "resource:credential"
    assert Enum.count(requests(c.log), &(&1["method"] == "initialize")) == 1
    assert Enum.count(requests(c.log), &(&1["method"] == "resources/read")) == 1
    finish!(child, c)
    finish!(root, c)
  end

  @tag permission_config: %{default: :allow, rules: %{"read_mcp_resource" => :deny}}
  test "child resource reads retain the current permission denial without remote effects", c do
    root = prompt!(c.agent)
    {child, root} = spawn!(root)
    assert "read_mcp_resource" in names(child)

    child =
      call!(child, "read_mcp_resource", %{"server" => "vault", "uri" => "vault://credential"})

    assert result!(child, "read_mcp_resource").is_error
    refute Enum.any?(requests(c.log), &(&1["method"] == "resources/read"))
    child = call!(child, "list_mcp_resources", %{"server" => "vault"})
    refute result!(child, "list_mcp_resources").is_error
    finish!(child, c)
    finish!(root, c)
  end

  @tag :child_deferred_mcp_functional
  @tag :child_mcp_unsearched_functional
  test "successful child followup rebinds resource access without opening another MCP connection",
       c do
    root = prompt!(c.agent)
    {child, root} = spawn!(root)

    child =
      call!(child, "read_mcp_resource", %{"server" => "vault", "uri" => "vault://credential"})

    refute result!(child, "read_mcp_resource").is_error
    finish!(child, c)

    send_call(root, "followup_task", %{"target" => "/root/vault", "message" => "read once more"})
    next = provider!(child.params.session_id)
    root = provider!(root.params.session_id)
    refute result!(root, "followup_task").is_error
    assert Enum.all?(@resources, &(&1 in names(next)))
    next = call!(next, "read_mcp_resource", %{"server" => "vault", "uri" => "vault://credential"})
    refute result!(next, "read_mcp_resource").is_error
    assert Enum.count(requests(c.log), &(&1["method"] == "initialize")) == 1
    assert Enum.count(requests(c.log), &(&1["method"] == "resources/read")) == 2
    finish!(next, c)
    finish!(root, c)
  end

  test "a running child follows root MCP replacement across nested calls and parent turns", c do
    root = prompt!(c.agent)
    {child, root} = spawn!(root)

    item =
      c.host
      |> :sys.get_state()
      |> Map.fetch!(:children)
      |> Map.values()
      |> Enum.find(&(&1.identity.child_session_id == child.params.session_id))

    assert item
    child_state = :sys.get_state(item.io)
    old_key = child_state.key
    old_binding = child_state.native_context.session_binding
    assert :ok = ChildIO.validate(item.io, old_key)

    assert {:ok, _} =
             Session.validate(old_binding, %{
               run_id: old_binding.run_id,
               incarnation: old_binding.run_incarnation
             })

    reload_mcp!(c)
    root = call!(root, "list_mcp_resources", %{"server" => "vault"})
    refute result!(root, "list_mcp_resources").is_error

    child =
      call!(child, "read_mcp_resource", %{"server" => "vault", "uri" => "vault://credential"})

    refute result!(child, "read_mcp_resource").is_error

    assert [%{"text" => "resource:credential"}] =
             structured!(child, "read_mcp_resource")["contents"]

    child =
      call!(
        child,
        "exec",
        "return await tools.read_mcp_resource({server:'vault',uri:'vault://credential'});"
      )

    refute result!(child, "exec").is_error

    assert %{"status" => "completed", "value" => %{"contents" => [content]}} =
             structured!(child, "exec")

    assert content["text"] == "resource:credential"
    finish!(root, c)

    # The child is still running, but there is no active root Provider turn.
    child =
      call!(child, "read_mcp_resource", %{"server" => "vault", "uri" => "vault://credential"})

    refute result!(child, "read_mcp_resource").is_error
    finish!(child, c)

    root = prompt!(c.agent)
    send_call(root, "followup_task", %{"target" => "/root/vault", "message" => "read once more"})
    next = provider!(child.params.session_id)
    root = provider!(root.params.session_id)
    refute result!(root, "followup_task").is_error
    assert next.params.turn_id != child.params.turn_id
    assert Enum.all?(@resources, &(&1 in names(next)))

    assert {:error, %Error{class: :resource_conflict}} = ChildIO.validate(item.io, old_key)

    assert {:error, %Error{class: :forbidden}} =
             Session.validate(old_binding, %{
               run_id: old_binding.run_id,
               incarnation: old_binding.run_incarnation
             })

    assert Enum.count(requests(c.log), &(&1["method"] == "resources/read")) == 3
    next = call!(next, "read_mcp_resource", %{"server" => "vault", "uri" => "vault://credential"})
    refute result!(next, "read_mcp_resource").is_error

    next =
      call!(next, "read_mcp_resource", %{"server" => "ungranted", "uri" => "vault://credential"})

    assert result!(next, "read_mcp_resource").is_error
    assert Enum.count(requests(c.log), &(&1["method"] == "resources/read")) == 4
    assert Enum.count(requests(c.log), &(&1["method"] == "initialize")) == 2
    finish!(next, c)
    finish!(root, c)
  end

  @tag permission_config: %{default: :allow, rules: %{"read_mcp_resource" => :deny}}
  test "a reloaded child client retains permission denial before remote resource effects", c do
    root = prompt!(c.agent)
    {child, root} = spawn!(root)
    reload_mcp!(c)

    child =
      call!(child, "read_mcp_resource", %{"server" => "vault", "uri" => "vault://credential"})

    assert result!(child, "read_mcp_resource").is_error
    refute Enum.any?(requests(c.log), &(&1["method"] == "resources/read"))
    child = call!(child, "list_mcp_resources", %{"server" => "vault"})
    refute result!(child, "list_mcp_resources").is_error

    assert [%{"server" => "vault", "uri" => "vault://credential"}] =
             structured!(child, "list_mcp_resources")["resources"]

    assert Enum.count(requests(c.log), &(&1["method"] == "initialize")) == 2
    finish!(child, c)
    finish!(root, c)
  end

  defp reload_mcp!(c) do
    assert %{"vault" => old_client} = :sys.get_state(c.agent).mcp_session.clients
    old_pid = GenServer.whereis(old_client)
    assert is_pid(old_pid)
    monitor = Process.monitor(old_pid)
    assert {:ok, 1} = Sigma.Agent.reload_mcp_tools(c.agent)
    assert_receive {:DOWN, ^monitor, :process, ^old_pid, _}, 8_000
    assert GenServer.whereis(old_client) == nil
    assert %{"vault" => replacement} = :sys.get_state(c.agent).mcp_session.clients
    refute replacement == old_client
    assert is_pid(GenServer.whereis(replacement))
    assert Enum.count(requests(c.log), &(&1["method"] == "initialize")) == 2
  end

  defp prompt!(agent) do
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "delegate MCP work")
    provider!("child-mcp-root")
  end

  defp spawn!(root) do
    send_call(root, "spawn_agent", %{
      "task_name" => "vault",
      "message" => "read the vault",
      "fork_turns" => "none"
    })

    child = provider!(:child)
    root = provider!("child-mcp-root")
    refute result!(root, "spawn_agent").is_error
    {child, root}
  end

  defp provider!(session) do
    receive do
      {:child_mcp_provider, pid, %{session_id: "child_" <> _} = params} when session == :child ->
        %{pid: pid, params: params}

      {:child_mcp_provider, pid, %{session_id: id} = params} when id == session ->
        %{pid: pid, params: params}

      {:turn_error, error} ->
        flunk("root failed: #{inspect(error)}")
    after
      8_000 -> flunk("provider did not start for #{session}")
    end
  end

  defp call!(provider, name, input) do
    send_call(provider, name, input)
    provider!(provider.params.session_id)
  end

  defp send_call(provider, name, input) do
    send(
      provider.pid,
      {:child_mcp_response,
       [
         %{
           type: :tool_call,
           id: "child-mcp-#{System.unique_integer([:positive])}",
           name: name,
           arguments: input,
           input_kind: if(is_binary(input), do: :custom, else: :function)
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

  defp names(provider), do: Enum.map(provider.params.context.tools, & &1.name)

  defp requests(log),
    do: log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  defp finish!(provider, c) do
    send(provider.pid, {:child_mcp_response, [%{type: :text, text: "done"}]})

    case provider.params.session_id do
      "child_" <> _ = id ->
        assert eventually(fn ->
                 assert {:ok, %{subagents: roster}} = Subagents.snapshot(c.host)

                 Enum.any?(
                   roster.agents,
                   &(&1.child_session_id == id and &1.run_id == provider.params.turn_id and
                       &1.status == :completed)
                 )
               end)

      "child-mcp-root" ->
        assert_receive {:agent_end, _}, 8_000
        assert Sigma.Agent.status(c.agent).phase == :completed
    end
  end

  defp eventually(fun, attempts \\ 400)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp fixture do
    ~S"""
    import json,sys
    log=sys.argv[1]
    for line in sys.stdin:
        request=json.loads(line)
        method=request.get('method')
        ident=request.get('id')
        params=request.get('params',{})
        with open(log,'a') as output:
            output.write(json.dumps({'method':method,'params':params})+'\n')
        if ident is None: continue
        if method=='initialize':
            result={'protocolVersion':'2025-06-18','capabilities':{'tools':{},'resources':{}},'serverInfo':{'name':'vault','version':'1'}}
        elif method=='tools/list':
            result={'tools':[{'name':'fetch_item','description':'Read an encrypted credential value from the vault by key.','inputSchema':{'type':'object','properties':{'key':{'type':'string'}},'required':['key'],'additionalProperties':False}}]}
        elif method=='tools/call':
            result={'content':[{'type':'text','text':'vault:'+params['arguments']['key']}],'isError':False}
        elif method=='resources/list':
            result={'resources':[{'uri':'vault://credential','name':'credential'}]}
        elif method=='resources/templates/list':
            result={'resourceTemplates':[{'uriTemplate':'vault://{key}','name':'credential template'}]}
        elif method=='resources/read':
            result={'contents':[{'uri':params['uri'],'mimeType':'text/plain','text':'resource:credential'}]}
        else:
            print(json.dumps({'jsonrpc':'2.0','id':ident,'error':{'code':-32601,'message':'Method not found'}}),flush=True)
            continue
        print(json.dumps({'jsonrpc':'2.0','id':ident,'result':result}),flush=True)
    """
  end
end
