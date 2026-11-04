defmodule Sigma.Agent.BackplaneDiscoveryDiscardFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.{Conversation, Codex.Session}
  alias Sigma.Agent.Backplane.ChildIO
  alias Sigma.Coding.MCP
  alias Sigma.Session.Log

  @moduletag :tmp_dir
  @moduletag :codex_alignment_functional
  @tool "mcp__vault__fetch_item"
  @description "Read an encrypted credential value from the vault by key."

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    def output_token_limit(_model, _options), do: 2_000

    def stream(params) do
      send(params.options[:test_pid], {:discard_provider, self(), params})

      receive do
        {:discard_response, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            content: content,
            stop_reason: reason,
            usage: %{input: 1, output: 1, total_tokens: 2, cost: %{total: 0.0}},
            model: "discovery-discard",
            provider: "discovery-discard",
            api: "openai-responses",
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, reason, message}]
      end
    end
  end

  defmodule DiscardingOuter do
    def execute(operation) do
      nested =
        operation.backend_context.nested_dispatch.(%{
          tool_name: "tool_search",
          arguments: %{"query" => "encrypted credential"}
        })

      send(operation.backend_context.test_pid, {:discard_nested_search, operation.run_id, nested})
      {:ok, %{is_error: true, text: "outer discarded"}}
    end
  end

  test "ChildIO/public Session discards nested discovery then republishes and executes MCP in the same run",
       %{tmp_dir: dir} do
    # This fixture exercises the public ChildIO contracts entrypoint and Session
    # settlement boundary. It does not trigger this path through root Engine or
    # a real managed tree, and it intentionally uses an ordinary settled result.
    python = System.find_executable("python3")
    assert python, "discovery discard functional acceptance requires Python"
    fixture = Path.join(dir, "vault.py")
    log = Path.join(dir, "mcp-requests.jsonl")
    transcript = Path.join(dir, "child.jsonl")
    File.write!(fixture, fixture())
    File.write!(log, "")

    servers = %{
      "vault" => %{"type" => "stdio", "command" => python, "args" => ["-u", fixture, log]}
    }

    assert {:ok, [mcp_tool], mcp_session} =
             MCP.start_session("discard-#{System.unique_integer([:positive])}", servers, cwd: dir)

    on_exit(fn -> MCP.stop(mcp_session) end)
    assert mcp_tool.name == @tool
    policy = start_supervised!({Sigma.Coding.PermissionPolicy, default: :allow, rules: %{}})

    identity = %{
      agent_id: "generation:discovery-child",
      child_session_id: "discovery-discard-child",
      root_session_id: "discovery-discard-root",
      run_id: "discovery-discard-run",
      public_run_id: "generation:discovery-discard-run",
      incarnation: 1,
      observer_incarnation: 1,
      agent_path: "/root/discovery",
      parent_agent_id: "generation:root"
    }

    config = %{
      model: %{id: "discovery-discard", provider: "discovery-discard", api: "openai-responses"},
      provider: Provider,
      provider_options: [test_pid: self()],
      cwd: dir,
      tools: [mcp_tool],
      mcp_servers: servers,
      mcp_clients: mcp_session.clients,
      hook_specs: [],
      policy: policy,
      native_tools: true,
      native_memory_root: Path.join(dir, "memories")
    }

    io =
      start_supervised!(
        {ChildIO,
         config: config,
         identity: identity,
         transcript_path: transcript,
         backplane_store_path: Path.join(dir, "child.runtime")}
      )

    outer = %{
      name: "discarding_outer",
      description: "Search, then settle the outer tool as an ordinary error",
      schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      backend: DiscardingOuter,
      backend_context: %{test_pid: self()},
      safety: %{read_only: true, retry_safe: false, parallel_safe: false}
    }

    authority = %{
      caller: identity.root_session_id,
      run_id: "root-run",
      grants: [@tool, "tool_search", "discarding_outer"],
      tool_revision: 1
    }

    assert {:ok, prepared} = ChildIO.prepare(io, identity, authority, [outer])
    binding = prepared.options[:session_binding]
    assert is_map(binding)
    conversation = start_supervised!({Conversation, prepared.options ++ [subscriber: self()]})
    assert {:ok, _} = Conversation.prompt(conversation, "discover and fetch the credential")
    initial = provider!()
    assert initial.params.session_id == identity.child_session_id
    assert initial.params.turn_id == identity.public_run_id
    assert "tool_search" in names(initial)
    refute @tool in names(initial)
    assert Session.status(binding.session).phase == :active
    assert_same_run(conversation, identity)

    after_discard = call!(initial, "discarding_outer", %{}, "outer-call")
    run_id = identity.run_id

    assert_receive {:discard_nested_search, ^run_id,
                    {:ok, %{tools: [%{name: @tool}], publication: %{status: :staged}}}},
                   2_000

    outer_result = result!(after_discard, "discarding_outer")
    assert outer_result.is_error
    assert inspect(outer_result.content) =~ "outer discarded"
    refute @tool in names(after_discard)

    assert after_discard.params.context.catalog_revision ==
             initial.params.context.catalog_revision

    assert Conversation.status(conversation).pending_catalog_publication == nil
    assert_same_run(conversation, identity)
    refute Enum.any?(requests(log), &(&1["method"] == "tools/call"))

    published =
      call!(after_discard, "tool_search", %{"query" => "encrypted credential"}, "search-call")

    search_result = result!(published, "tool_search")
    refute search_result.is_error
    assert [%{type: :text, text: json}] = search_result.content
    assert [%{"name" => @tool}] = Jason.decode!(json)["tools"]

    assert published.params.context.catalog_revision >
             after_discard.params.context.catalog_revision

    definition = Enum.find(published.params.context.tools, &(&1.name == @tool))
    assert definition
    assert definition.description == @description
    assert definition.parameters == schema()
    assert_same_run(conversation, identity)

    after_call = call!(published, @tool, %{"key" => "after-discard"}, "mcp-call")
    mcp_result = result!(after_call, @tool)
    refute mcp_result.is_error
    assert [%{type: :text, text: "vault:after-discard"}] = mcp_result.content
    assert after_call.params.session_id == initial.params.session_id
    assert after_call.params.turn_id == initial.params.turn_id
    assert_same_run(conversation, identity)

    remote = requests(log)
    assert Enum.count(remote, &(&1["method"] == "initialize")) == 1

    assert [%{"params" => %{"name" => "fetch_item", "arguments" => %{"key" => "after-discard"}}}] =
             Enum.filter(remote, &(&1["method"] == "tools/call"))

    send(after_call.pid, {:discard_response, [%{type: :text, text: "done"}]})
    assert_receive {:agent_runtime, ^run_id, %{type: :run_completed}}, 5_000

    assert %{phase: :terminal, run: %{state: :completed}, error: nil} =
             Conversation.status(conversation)

    assert {:ok, snapshot} = Log.snapshot(transcript)
    results = Enum.filter(snapshot.messages, &(&1.role == :tool_result))
    assert Enum.map(results, & &1.tool_name) == ["discarding_outer", "tool_search", @tool]
    assert Enum.map(results, & &1.tool_call_id) == ["outer-call", "search-call", "mcp-call"]
    assert [saved_outer, saved_search, saved_mcp] = results
    assert saved_outer.is_error
    assert inspect(saved_outer.content) =~ "outer discarded"
    refute saved_search.is_error
    assert [%{type: :text, text: saved_json}] = saved_search.content
    assert [%{"name" => @tool}] = Jason.decode!(saved_json)["tools"]
    refute saved_mcp.is_error
    assert saved_mcp.content == mcp_result.content
  end

  defp provider! do
    assert_receive {:discard_provider, pid, params}, 5_000
    %{pid: pid, params: params}
  end

  defp call!(provider, name, arguments, id) do
    send(
      provider.pid,
      {:discard_response, [%{type: :tool_call, id: id, name: name, arguments: arguments}]}
    )

    provider!()
  end

  defp result!(provider, name) do
    Enum.find(Enum.reverse(provider.params.context.messages), &(Map.get(&1, :tool_name) == name)) ||
      flunk("missing #{name} result in the next Provider request")
  end

  defp names(provider), do: Enum.map(provider.params.context.tools, & &1.name)

  defp assert_same_run(conversation, identity) do
    status = Conversation.status(conversation)
    assert status.run.run_id == identity.run_id
    assert status.run.incarnation == identity.incarnation
    assert status.error == nil
  end

  defp requests(log),
    do: log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  defp schema do
    %{
      "type" => "object",
      "properties" => %{"key" => %{"type" => "string"}},
      "required" => ["key"],
      "additionalProperties" => false
    }
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
            result={'protocolVersion':'2025-06-18','capabilities':{'tools':{}},'serverInfo':{'name':'vault','version':'1'}}
        elif method=='tools/list':
            result={'tools':[{'name':'fetch_item','description':'Read an encrypted credential value from the vault by key.','inputSchema':{'type':'object','properties':{'key':{'type':'string'}},'required':['key'],'additionalProperties':False}}]}
        elif method=='tools/call':
            result={'content':[{'type':'text','text':'vault:'+params['arguments']['key']}],'isError':False}
        else:
            print(json.dumps({'jsonrpc':'2.0','id':ident,'error':{'code':-32601,'message':'Method not found'}}),flush=True)
            continue
        print(json.dumps({'jsonrpc':'2.0','id':ident,'result':result}),flush=True)
    """
  end
end
