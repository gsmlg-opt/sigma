defmodule Sigma.Agent.BackplaneChildMcpHookDeliveryTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Conversation
  alias Sigma.Agent.Backplane.{ChildIO, Store}
  alias Sigma.Coding.{Hooks.Discovery, MCP}
  alias Sigma.Session.{Journal, Log, Storage.JsonlFile}

  @moduletag :tmp_dir
  @tool "mcp__vault__fetch_item"
  @text "child MCP async feedback"
  @identity ~w(run_id incarnation turn_id step_id attempt_id invocation_id tool_call_id tool_name)a

  defmodule ControlledProvider do
    @behaviour Sigma.Ai.Provider

    def stream(request) do
      send(request.options[:test_pid], {:child_mcp_hook_request, self(), request})

      receive do
        {:respond, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            content: content,
            usage: %{input: 1, output: 1},
            stop_reason: reason,
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, reason, message}]
      end
    end
  end

  setup %{tmp_dir: dir} do
    python = System.find_executable("python3")
    assert is_binary(python), "child MCP hook integration requires Python"
    script = Path.join(dir, "vault.py")
    log = Path.join(dir, "mcp-requests.jsonl")
    File.write!(script, fixture())
    File.write!(log, "")

    assert {:ok, [tool], mcp} =
             MCP.start_session(
               "child-mcp-hooks-#{System.unique_integer([:positive])}",
               %{
                 "vault" => %{
                   "type" => "stdio",
                   "command" => python,
                   "args" => ["-u", script, log]
                 }
               },
               cwd: dir
             )

    assert tool.name == @tool
    on_exit(fn -> MCP.stop(mcp) end)
    {:ok, tool: tool, mcp_log: log}
  end

  # The fixture supplies an explicit static parent grant through public ChildIO
  # preparation. It does not bypass or claim to fix dynamic manager delegation
  # of root-discovered MCP grants, which still awaits backplane#100.
  test "active MCP feedback uses the exact settled operation and one canonical child message",
       c do
    child = child!(c)
    conversation = start_run!(child, child.identity, :active)
    provider = call_mcp!(conversation, "active")
    release!(child)
    await_status!(child, "admitted")
    refute feedback_fact?(child, "consumed")
    send(provider, {:respond, [%{type: :text, text: "before feedback"}]})

    {provider, request} = provider!()
    assert [message] = feedback(request.context.messages)
    assert message.content == "[Developer context from async hook]\n" <> @text
    await_status!(child, "consumed")
    assert_exact_origin!(child, "mcp-call-active")
    finish!(conversation, provider)

    assert submissions(child) == ["initial child prompt"]
    assert length(mcp_calls(c)) == 1
    assert hd(mcp_calls(c))["params"]["arguments"] == %{"key" => "active"}
    assert [post] = post_hooks(child)
    assert post["tool_name"] == @tool
    assert post["tool_input"] == %{"key" => "active"}
    assert {:ok, snapshot} = Log.snapshot(child.path)
    assert length(feedback(snapshot.messages)) == 1
    refute File.exists?(Path.join(c.tmp_dir, "root.jsonl"))
  end

  test "idle MCP feedback survives ChildIO recreation and enters one real followup", c do
    child = child!(c)
    conversation = start_run!(child, child.identity, :before_restore)
    provider = call_mcp!(conversation, "restore")
    finish!(conversation, provider)
    release!(child)
    await_status!(child, "received")
    [received] = items(child)
    refute_receive {:child_mcp_hook_request, _, _}, 100

    assert :ok = stop_supervised(:before_restore)
    assert :ok = stop_supervised(ChildIO)
    child = %{child | io: start_supervised!({ChildIO, child.options})}
    identity = %{child.identity | run_id: "child-mcp-restored"}
    restored = start_run!(child, identity, :restored)
    {provider, request} = provider!()
    assert [message] = feedback(request.context.messages)

    assert message.content ==
             "initial child prompt\n\n[Developer context from async hook]\n" <> @text

    await_status!(child, "consumed")
    finish!(restored, provider)
    assert [consumed] = items(child)
    assert consumed["item_id"] == received["item_id"]

    third = start_run!(child, %{identity | run_id: "child-mcp-third"}, :third)
    {provider, request} = provider!()
    assert length(feedback(request.context.messages)) == 1
    finish!(third, provider)
    assert length(mcp_calls(c)) == 1
    assert File.read!(child.hook_runs) == "run\n"
    assert length(submissions(child)) == 3
  end

  test "cancelled MCP origins cannot deliver late feedback into a fresh child run", c do
    child = child!(c)
    conversation = start_run!(child, child.identity, :cancelled)
    _provider = call_mcp!(conversation, "cancel")
    await_file!(child.started)
    assert :ok = Conversation.cancel(conversation)
    terminal!(conversation)
    release!(child)
    await_status!(child, "received")
    refute_receive {:child_mcp_hook_request, _, _}, 100

    followup = start_run!(child, %{child.identity | run_id: "after-cancel"}, :after_cancel)
    {provider, request} = provider!()
    assert feedback(request.context.messages) == []
    await_status!(child, "discarded")
    finish!(followup, provider)
    assert length(mcp_calls(c)) == 1
  end

  test "failed MCP results retain their error and never run success hooks", c do
    child = child!(c)
    conversation = start_run!(child, child.identity, :failed_result)
    provider = call_mcp!(conversation, "fail")
    refute File.exists?(child.post_path)
    refute File.exists?(child.started)
    assert items(child) == []
    finish!(conversation, provider)

    followup = start_run!(child, %{child.identity | run_id: "after-failure"}, :after_failure)
    {provider, request} = provider!()
    assert feedback(request.context.messages) == []
    refute inspect(request.context.messages) =~ @text
    result = Enum.find(request.context.messages, &(Map.get(&1, :tool_name) == @tool))
    assert result.is_error
    assert inspect(result.content) =~ "vault:fail"
    refute File.exists?(child.post_path)
    assert items(child) == []
    finish!(followup, provider)
    assert length(mcp_calls(c)) == 1
  end

  test "child shutdown joins detached MCP post hooks before stopping the Writer", c do
    child = child!(c)
    conversation = start_run!(child, child.identity, :shutdown)
    provider = call_mcp!(conversation, "shutdown")
    await_file!(child.started)
    finish!(conversation, provider)
    assert :ok = stop_supervised(ChildIO)
    File.write!(child.release, "ready")
    refute_receive {:child_mcp_hook_request, _, _}, 100
    refute File.exists?(child.completed)
    assert items(child) == []
    assert length(mcp_calls(c)) == 1
  end

  test "real Deno nested MCP calls retain their own public operation identity", c do
    assert is_binary(System.find_executable("deno")), "nested MCP hook integration requires Deno"
    child = child!(c, grants: [@tool, "exec", "wait"])
    conversation = start_run!(child, child.identity, :nested)
    {provider, _} = provider!()

    send(
      provider,
      {:respond,
       [
         %{
           type: :tool_call,
           id: "outer-deno-call",
           name: "exec",
           arguments: "return await tools.mcp__vault__fetch_item({key:'nested'});"
         }
       ]}
    )

    {provider, request} = provider!()
    assert inspect(request.context.messages) =~ "vault:nested"
    release!(child)
    await_status!(child, "admitted")
    [item] = items(child)
    assert item["origin"]["tool_name"] == @tool
    refute item["origin"]["tool_call_id"] == "outer-deno-call"
    assert_exact_origin!(child, item["origin"]["tool_call_id"])
    send(provider, {:respond, [%{type: :text, text: "before nested feedback"}]})

    {provider, request} = provider!()
    assert length(feedback(request.context.messages)) == 1
    await_status!(child, "consumed")
    finish!(conversation, provider)
    assert length(mcp_calls(c)) == 1
    assert submissions(child) == ["initial child prompt"]
  end

  test "native_tools false retains the independent legacy async callback", c do
    child = child!(c, native_tools: false)
    conversation = start_run!(child, child.identity, :legacy)
    provider = call_mcp!(conversation, "legacy")
    finish!(conversation, provider)
    release!(child)
    await_file!(child.completed)

    followup = start_run!(child, %{child.identity | run_id: "legacy-followup"}, :legacy_followup)
    {provider, request} = provider!()
    assert inspect(request.context.messages) =~ @text
    assert feedback(request.context.messages) == []
    assert items(child) == []
    finish!(followup, provider)
  end

  defp child!(c, opts \\ []) do
    dir = c.tmp_dir
    release = Path.join(dir, "release-hook")
    completed = Path.join(dir, "completed-hook")
    started = Path.join(dir, "started-hook")
    hook_runs = Path.join(dir, "hook-runs")
    submit_path = Path.join(dir, "submissions.jsonl")
    post_path = Path.join(dir, "post-hooks.jsonl")

    output =
      Jason.encode!(%{
        "hookSpecificOutput" => %{
          "hookEventName" => "PostToolUse",
          "additionalContext" => @text
        }
      })

    command =
      "cat >/dev/null; printf 'run\\n' >> '#{hook_runs}'; touch '#{started}'; while [ ! -f '#{release}' ]; do sleep 0.01; done; printf '%s' '#{output}'; touch '#{completed}'"

    submit = "cat >> '#{submit_path}'; printf '\\n' >> '#{submit_path}'"
    post = "cat >> '#{post_path}'; printf '\\n' >> '#{post_path}'"

    {:ok, specs} =
      Discovery.parse(
        Jason.encode!(%{
          "hooks" => %{
            "UserPromptSubmit" => [
              %{"hooks" => [%{"type" => "command", "command" => submit, "timeout" => 10}]}
            ],
            "PostToolUse" => [
              %{
                "matcher" => @tool,
                "hooks" => [
                  %{"type" => "command", "command" => post, "timeout" => 10},
                  %{
                    "type" => "command",
                    "command" => command,
                    "async" => true,
                    "timeout" => 10
                  }
                ]
              }
            ]
          }
        }),
        :codex
      )

    identity = %{
      agent_id: "child-mcp-#{System.unique_integer([:positive])}",
      child_session_id: "child-mcp-session",
      root_session_id: "root-mcp-session",
      run_id: "child-mcp-run",
      public_run_id: "public-child-mcp-run",
      incarnation: 1,
      observer_incarnation: 1,
      agent_path: "/root/mcp-child",
      parent_agent_id: "root"
    }

    config = %{
      model: %{id: "mock", provider: "mock", api: "mock"},
      provider: ControlledProvider,
      provider_options: [test_pid: self()],
      cwd: dir,
      tools: [c.tool],
      dispatcher_opts: [],
      hook_specs: Enum.map(specs, &%{&1 | origin: {:user, "test"}, trusted?: true}),
      native_tools: Keyword.get(opts, :native_tools, true),
      native_memory_root: Path.join(dir, "memories")
    }

    path = Path.join(dir, "child.jsonl")

    options = [
      config: config,
      identity: identity,
      transcript_path: path,
      backplane_store_path: Path.join(dir, "runtime")
    ]

    %{
      io: start_supervised!({ChildIO, options}),
      identity: identity,
      options: options,
      grants: Keyword.get(opts, :grants, [@tool]),
      path: path,
      release: release,
      completed: completed,
      started: started,
      hook_runs: hook_runs,
      submit_path: submit_path,
      post_path: post_path
    }
  end

  defp start_run!(child, identity, id) do
    assert {:ok, prepared} =
             ChildIO.prepare(
               child.io,
               identity,
               %{caller: "root", run_id: "root-run", grants: child.grants, tool_revision: 1},
               []
             )

    conversation =
      start_supervised!(Supervisor.child_spec({Conversation, prepared.options}, id: id))

    assert {:ok, _} = Conversation.prompt(conversation, "initial child prompt")
    conversation
  end

  defp call_mcp!(_conversation, key) do
    {provider, _} = provider!()

    send(
      provider,
      {:respond,
       [%{type: :tool_call, id: "mcp-call-#{key}", name: @tool, arguments: %{"key" => key}}]}
    )

    {provider, request} = provider!()

    result =
      Enum.find(Enum.reverse(request.context.messages), &(Map.get(&1, :tool_name) == @tool))

    assert result
    assert result.is_error == (key == "fail")
    provider
  end

  defp provider! do
    assert_receive {:child_mcp_hook_request, provider, request}, 5_000
    {provider, request}
  end

  defp finish!(conversation, provider) do
    send(provider, {:respond, [%{type: :text, text: "done"}]})
    terminal!(conversation)
  end

  defp terminal!(conversation),
    do: await!(fn -> Conversation.status(conversation).phase == :terminal end)

  defp release!(child), do: File.write!(child.release, "ready")
  defp await_file!(path), do: await!(fn -> File.exists?(path) end)

  defp await_status!(child, status),
    do: await!(fn -> match?([%{"status" => ^status}], items(child)) end)

  defp items(child) do
    assert {:ok, snapshot} = Log.snapshot(child.path)
    assert {:ok, entries} = JsonlFile.read(child.path)

    assert {:ok, state} =
             Journal.hook_feedback_projection(
               entries,
               snapshot.active_leaf_id,
               child.identity.child_session_id
             )

    Map.values(state.projection.items)
  end

  defp feedback_fact?(child, fact) do
    assert {:ok, entries} = JsonlFile.read(child.path)
    Enum.any?(entries, &(&1["type"] == "hook_feedback" and &1["event"]["fact"] == fact))
  end

  defp feedback(messages),
    do: Enum.filter(messages, &Map.has_key?(Map.get(&1, :metadata, %{}), "hook_feedback"))

  defp submissions(child) do
    child.submit_path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!(&1)["prompt"])
  end

  defp post_hooks(child) do
    child.post_path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp assert_exact_origin!(child, tool_call_id) do
    [item] = items(child)
    origin = item["origin"]
    assert origin["tool_call_id"] == tool_call_id
    assert {:ok, store} = ChildIO.store(child.io)
    assert {:ok, %{run: run}} = Store.load(store, origin["run_id"])
    intent = run.execution_intents["tool:" <> origin["invocation_id"]]
    assert intent.status == :consumed

    assert Map.new(@identity, &{Atom.to_string(&1), intent.operation[&1]}) ==
             Map.take(origin, Enum.map(@identity, &Atom.to_string/1))
  end

  defp mcp_calls(c) do
    c.mcp_log
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&(&1["method"] == "tools/call"))
  end

  defp await!(predicate, attempts \\ 500)
  defp await!(_predicate, 0), do: flunk("child MCP hook boundary did not settle")

  defp await!(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(10)
      await!(predicate, attempts - 1)
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
            result={'protocolVersion':'2025-06-18','capabilities':{'tools':{}},'serverInfo':{'name':'vault','version':'1'}}
        elif method=='tools/list':
            result={'tools':[{'name':'fetch_item','description':'Read a fixture vault item by key.','inputSchema':{'type':'object','properties':{'key':{'type':'string'}},'required':['key'],'additionalProperties':False}}]}
        elif method=='tools/call':
            key=params['arguments']['key']
            result={'content':[{'type':'text','text':'vault:'+key}],'isError':key=='fail'}
        else:
            print(json.dumps({'jsonrpc':'2.0','id':ident,'error':{'code':-32601,'message':'Method not found'}}),flush=True)
            continue
        print(json.dumps({'jsonrpc':'2.0','id':ident,'result':result}),flush=True)
    """
  end
end
