defmodule Sigma.Agent.BackplaneMcpStructuredFunctionalTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.Backplane.ChildIO
  alias Sigma.Agent.{Runtime, Subagents}
  alias Sigma.Session.{Log, Writer}

  @moduletag :tmp_dir
  @moduletag :mcp_structured_functional
  @root "structured-mcp-root"
  @tool "mcp__catalog__read_catalog"

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    def output_token_limit(_model, _options), do: 2_000

    def stream(params) do
      send(params.options[:test_pid], {:structured_provider, self(), params})

      receive do
        {:structured_response, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            content: content,
            stop_reason: reason,
            usage: %{input: 1, output: 1, total_tokens: 2, cost: %{total: 0.0}},
            model: "structured-mcp",
            provider: "structured-mcp",
            api: "openai-responses",
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, reason, message}]
      end
    end
  end

  setup %{tmp_dir: dir} do
    python = System.find_executable("python3")
    assert python, "structured MCP functional acceptance requires Python"
    fixture = Path.join(dir, "catalog.py")
    payload_path = Path.join(dir, "payload.json")
    log = Path.join(dir, "mcp-requests.jsonl")
    path = Path.join(dir, "root.jsonl")
    payload = payload()
    File.write!(fixture, fixture())
    File.write!(payload_path, Jason.encode!(payload))
    File.write!(log, "")

    assert {:ok, handle} =
             Runtime.get_session(dir, @root,
               cwd: dir,
               transcript_path: path,
               native_tools: true,
               native_memory_root: Path.join(dir, "memories"),
               provider: Provider,
               model: %{
                 id: "structured-mcp",
                 provider: "structured-mcp",
                 api: "openai-responses",
                 context_window: 200_000
               },
               tools: [],
               hook_specs: [],
               permission_config: %{default: :allow, rules: %{}},
               options: [test_pid: self()],
               mcp_servers: %{
                 "catalog" => %{
                   "type" => "stdio",
                   "command" => python,
                   "args" => ["-u", fixture, payload_path, log]
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

    %{
      dir: dir,
      path: path,
      log: log,
      payload: payload,
      agent: handle.agent,
      host: Runtime.lookup(dir, @root, :subagents)
    }
  end

  test "root direct and real Deno results retain complete structured JSON through another turn and journal reopen",
       c do
    root = prompt!(c.agent)
    root = discover!(root)
    root = exercise_results!(root, c.payload)
    first_result = Enum.find(root.params.context.messages, &(&1[:tool_name] == @tool))
    finish!(root, c)

    next = prompt!(c.agent)
    assert_previous_result!(next, first_result)
    refute @tool in names(next)
    next = discover!(next)
    next = call!(next, @tool, %{"mode" => "empty"})
    assert_direct_result!(result!(next, @tool), c.payload, "empty")
    finish!(next, c)

    writer = Runtime.lookup(c.dir, @root, :writer)
    assert {:ok, _} = Writer.flush(writer)
    assert_read_only_reopen!(c.path, c.log, c.payload)
    assert_calls!(c.log)
    refute_receive {:structured_provider, _, _}, 0
  end

  test "actual managed-child direct and real Deno results retain complete structured JSON through followup and journal reopen",
       c do
    root = c.agent |> prompt!() |> discover!()

    send_call(root, "spawn_agent", %{
      "task_name" => "catalog",
      "message" => "Read the structured catalog",
      "fork_turns" => "none"
    })

    child = provider!(:child)
    child_id = child.params.session_id
    root = provider!(@root)
    refute result!(root, "spawn_agent").is_error
    child = child |> discover!() |> exercise_results!(c.payload)
    first_result = Enum.find(child.params.context.messages, &(&1[:tool_name] == @tool))
    finish!(child, c)

    send_call(root, "followup_task", %{
      "target" => "/root/catalog",
      "message" => "Read the same complete catalog again"
    })

    next = provider!(child_id)
    root = provider!(@root)
    refute result!(root, "followup_task").is_error
    assert_previous_result!(next, first_result)
    refute @tool in names(next)
    next = discover!(next)
    next = call!(next, @tool, %{"mode" => "empty"})
    assert_direct_result!(result!(next, @tool), c.payload, "empty")
    finish!(next, c)

    assert {:ok, sources} = Subagents.archive_sources(c.host)
    source = Enum.find(sources.children, &(&1.identity.child_session_id == child_id))
    assert source
    assert {:ok, archive} = ChildIO.archive_source(source.io)
    assert {:ok, _} = Writer.flush(archive.writer)
    assert_read_only_reopen!(archive.transcript_path, c.log, c.payload)
    assert_calls!(c.log)
    finish!(root, c)
    refute_receive {:structured_provider, _, _}, 0
  end

  @tag :mcp_unknown_functional
  @tag mcp_structured_functional: false
  test "root unknown MCP content retains complete ordered JSON through direct Deno another turn and journal reads",
       c do
    root = c.agent |> prompt!() |> discover!() |> exercise_unknown_results!(c.payload)
    previous = Enum.find(root.params.context.messages, &(&1[:tool_name] == @tool))
    finish!(root, c)

    next = prompt!(c.agent)
    assert_previous_result!(next, previous)
    next = discover!(next)
    next = call!(next, @tool, %{"mode" => "unknown"})
    assert_unknown_result!(result!(next, @tool), c.payload)
    finish!(next, c)

    writer = Runtime.lookup(c.dir, @root, :writer)
    assert {:ok, _} = Writer.flush(writer)
    assert_unknown_journal_reads!(c.path, c.log, c.payload)
    refute_receive {:structured_provider, _, _}, 0
  end

  @tag :mcp_unknown_functional
  @tag mcp_structured_functional: false
  test "actual managed-child unknown MCP content retains complete ordered JSON through direct Deno followup and journal reads",
       c do
    root = c.agent |> prompt!() |> discover!()

    send_call(root, "spawn_agent", %{
      "task_name" => "catalog",
      "message" => "Read the complete mixed catalog content",
      "fork_turns" => "none"
    })

    child = provider!(:child)
    child_id = child.params.session_id
    root = provider!(@root)
    refute result!(root, "spawn_agent").is_error
    child = child |> discover!() |> exercise_unknown_results!(c.payload)
    previous = Enum.find(child.params.context.messages, &(&1[:tool_name] == @tool))
    finish!(child, c)

    send_call(root, "followup_task", %{
      "target" => "/root/catalog",
      "message" => "Read the same mixed content again"
    })

    next = provider!(child_id)
    root = provider!(@root)
    refute result!(root, "followup_task").is_error
    assert_previous_result!(next, previous)
    next = discover!(next)
    next = call!(next, @tool, %{"mode" => "unknown"})
    assert_unknown_result!(result!(next, @tool), c.payload)
    finish!(next, c)

    assert {:ok, sources} = Subagents.archive_sources(c.host)
    source = Enum.find(sources.children, &(&1.identity.child_session_id == child_id))
    assert source
    assert {:ok, archive} = ChildIO.archive_source(source.io)
    assert {:ok, _} = Writer.flush(archive.writer)
    assert_unknown_journal_reads!(archive.transcript_path, c.log, c.payload)
    finish!(root, c)
    refute_receive {:structured_provider, _, _}, 0
  end

  @tag :mcp_nested_error_functional
  @tag mcp_structured_functional: false
  test "root real Deno MCP error fulfills its promise and preserves the following call through another turn and journal reads",
       c do
    root = c.agent |> prompt!() |> discover!() |> exercise_nested_error!(c.payload)
    previous = result!(root, "exec")
    finish!(root, c)

    next = prompt!(c.agent)
    assert_previous_result!(next, previous)
    assert_nested_error_result!(result!(next, "exec"), c.payload)
    next = discover!(next)
    next = call!(next, @tool, %{"mode" => "plain"})
    assert_plain_result!(result!(next, @tool))
    finish!(next, c)

    writer = Runtime.lookup(c.dir, @root, :writer)
    assert {:ok, _} = Writer.flush(writer)
    assert_nested_error_journal_reads!(c.path, c.log, c.payload)
    refute_receive {:structured_provider, _, _}, 0
  end

  @tag :mcp_nested_error_functional
  @tag mcp_structured_functional: false
  test "actual managed-child real Deno MCP error fulfills its promise and preserves the following call through followup and journal reads",
       c do
    root = c.agent |> prompt!() |> discover!()

    send_call(root, "spawn_agent", %{
      "task_name" => "catalog",
      "message" => "Read an MCP error and continue with the ordinary catalog",
      "fork_turns" => "none"
    })

    child = provider!(:child)
    child_id = child.params.session_id
    root = provider!(@root)
    refute result!(root, "spawn_agent").is_error
    child = child |> discover!() |> exercise_nested_error!(c.payload)
    previous = result!(child, "exec")
    finish!(child, c)

    send_call(root, "followup_task", %{
      "target" => "/root/catalog",
      "message" => "Read the ordinary catalog again"
    })

    next = provider!(child_id)
    root = provider!(@root)
    refute result!(root, "followup_task").is_error
    assert_previous_result!(next, previous)
    assert_nested_error_result!(result!(next, "exec"), c.payload)
    next = discover!(next)
    next = call!(next, @tool, %{"mode" => "plain"})
    assert_plain_result!(result!(next, @tool))
    finish!(next, c)

    assert {:ok, sources} = Subagents.archive_sources(c.host)
    source = Enum.find(sources.children, &(&1.identity.child_session_id == child_id))
    assert source
    assert {:ok, archive} = ChildIO.archive_source(source.io)
    assert {:ok, _} = Writer.flush(archive.writer)
    assert_nested_error_journal_reads!(archive.transcript_path, c.log, c.payload)
    finish!(root, c)
    refute_receive {:structured_provider, _, _}, 0
  end

  defp exercise_nested_error!(provider, payload) do
    provider =
      call!(provider, "exec", """
      const failed = await tools.mcp__catalog__read_catalog({mode:'error'});
      const recovered = await tools.mcp__catalog__read_catalog({mode:'plain'});
      return {failed,recovered};
      """)

    assert_nested_error_result!(result!(provider, "exec"), payload)
    provider = call!(provider, @tool, %{"mode" => "empty"})
    assert_direct_result!(result!(provider, @tool), payload, "empty")
    provider
  end

  defp assert_nested_error_result!(result, payload) do
    refute result.is_error
    nested = structured!(result)
    assert nested["status"] == "completed"
    assert %{"failed" => failed, "recovered" => recovered} = nested["value"]
    assert failed["is_error"] == true
    assert [%{"type" => "text", "text" => json}] = failed["content"]
    assert {:ok, ^payload} = Jason.decode(json)
    assert failed["details"] == envelope(payload, "error")
    assert recovered["is_error"] == false

    assert recovered["content"] == [
             %{"type" => "text", "text" => "ordinary text stays unchanged"}
           ]

    assert recovered["details"] == envelope(payload, "plain")
  end

  defp assert_plain_result!(result) do
    refute result.is_error
    assert result.content == [%{type: :text, text: "ordinary text stays unchanged"}]
  end

  defp assert_nested_error_journal_reads!(path, log, payload) do
    journal_before = File.read!(path)
    requests_before = File.read!(log)
    journal_stat = File.stat!(path, time: :posix)
    requests_stat = File.stat!(log, time: :posix)
    assert {:ok, first} = Log.snapshot(path)
    assert {:ok, reopened} = Log.snapshot(path)
    assert reopened.messages == first.messages

    for snapshot <- [first, reopened] do
      results = Enum.filter(snapshot.messages, &(&1.role == :tool_result))

      assert Enum.map(results, & &1.tool_name) == [
               "tool_search",
               "exec",
               @tool,
               "tool_search",
               @tool
             ]

      [_, nested, empty, _, plain] = results
      assert_nested_error_result!(nested, payload)
      assert_direct_result!(empty, payload, "empty")
      assert structured!(empty)["details"] == envelope(payload, "empty")
      assert_plain_result!(plain)
      assert structured!(plain)["details"] == envelope(payload, "plain")
    end

    assert File.read!(path) == journal_before
    assert File.read!(log) == requests_before
    assert File.stat!(path, time: :posix).mtime == journal_stat.mtime
    assert File.stat!(log, time: :posix).mtime == requests_stat.mtime

    requests = requests_before |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.count(requests, &(&1["method"] == "initialize")) == 1
    calls = Enum.filter(requests, &(&1["method"] == "tools/call"))

    assert Enum.map(calls, &get_in(&1, ["params", "arguments", "mode"])) ==
             ["error", "plain", "empty", "plain"]
  end

  defp exercise_unknown_results!(provider, payload) do
    provider = call!(provider, @tool, %{"mode" => "unknown"})
    assert_unknown_result!(result!(provider, @tool), payload)

    provider =
      call!(
        provider,
        "exec",
        "return await tools.mcp__catalog__read_catalog({mode:'unknown'});"
      )

    nested = structured!(result!(provider, "exec"))
    assert nested["status"] == "completed"
    assert nested["value"]["is_error"] == false
    assert_unknown_content!(nested["value"]["content"], payload)
    assert nested["value"]["details"] == unknown_envelope(payload)
    provider
  end

  defp assert_unknown_result!(result, payload) do
    refute result.is_error
    assert_unknown_content!(result.content, payload)
  end

  defp assert_unknown_content!(content, payload) do
    normalized = content |> Jason.encode!() |> Jason.decode!()
    assert [plain, resource, link, future] = normalized
    assert plain == %{"type" => "text", "text" => "ordinary sibling 中文\r\n  "}
    [_plain | expected] = unknown_blocks(payload)

    for {actual, original} <- Enum.zip([resource, link, future], expected) do
      assert %{"type" => "text", "text" => json} = actual
      assert {:ok, ^original} = Jason.decode(json)
    end
  end

  defp assert_unknown_journal_reads!(path, log, payload) do
    journal_before = File.read!(path)
    requests_before = File.read!(log)
    journal_stat = File.stat!(path, time: :posix)
    requests_stat = File.stat!(log, time: :posix)
    assert {:ok, first} = Log.snapshot(path)
    assert {:ok, reopened} = Log.snapshot(path)
    assert reopened.messages == first.messages

    direct =
      Enum.filter(reopened.messages, &(&1.role == :tool_result and &1.tool_name == @tool))

    assert length(direct) == 2

    for result <- direct do
      assert_unknown_result!(result, payload)
      assert structured!(result)["details"] == unknown_envelope(payload)
    end

    nested = Enum.find(reopened.messages, &(&1.role == :tool_result and &1.tool_name == "exec"))
    assert nested
    assert_unknown_content!(structured!(nested)["value"]["content"], payload)
    assert structured!(nested)["value"]["details"] == unknown_envelope(payload)
    assert File.read!(path) == journal_before
    assert File.read!(log) == requests_before
    assert File.stat!(path, time: :posix).mtime == journal_stat.mtime
    assert File.stat!(log, time: :posix).mtime == requests_stat.mtime

    requests = requests_before |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.count(requests, &(&1["method"] == "initialize")) == 1
    calls = Enum.filter(requests, &(&1["method"] == "tools/call"))

    assert Enum.map(calls, &get_in(&1, ["params", "arguments", "mode"])) ==
             ["unknown", "unknown", "unknown"]
  end

  defp unknown_envelope(payload) do
    %{
      "content" => unknown_blocks(payload),
      "isError" => false,
      "_meta" => %{"catalog/receipt" => %{"complete" => true, "optional" => nil}}
    }
  end

  defp unknown_blocks(payload) do
    [
      %{"type" => "text", "text" => "ordinary sibling 中文\r\n  "},
      %{
        "type" => "resource",
        "resource" => %{
          "uri" => "catalog://guide/中文",
          "mimeType" => "text/plain",
          "text" => "  embedded 中文\r\nsecond line\n"
        },
        "_meta" => %{"catalog/source" => %{"version" => 1, "cached" => false}}
      },
      %{
        "type" => "resource_link",
        "uri" => "https://example.test/catalog/guide",
        "name" => "目录指南",
        "description" => "  完整说明\r\nwith spaces\n",
        "mimeType" => "text/plain",
        "_meta" => %{"catalog/link" => %{"optional" => nil}}
      },
      %{
        "type" => "catalog_future",
        "payload" => payload,
        "_meta" => %{"catalog/future" => %{"enabled" => true, "disabled" => false}}
      }
    ]
  end

  defp exercise_results!(provider, payload) do
    provider = call!(provider, @tool, %{"mode" => "empty"})
    assert_direct_result!(result!(provider, @tool), payload, "empty")

    provider =
      call!(
        provider,
        "exec",
        "return await tools.mcp__catalog__read_catalog({mode:'missing'});"
      )

    nested = structured!(result!(provider, "exec"))
    assert nested["status"] == "completed"
    value = nested["value"]
    assert value["is_error"] == false
    assert [%{"type" => "text", "text" => json}] = value["content"]
    assert {:ok, ^payload} = Jason.decode(json)
    assert value["details"] == envelope(payload, "missing")

    provider = call!(provider, @tool, %{"mode" => "error"})
    assert_direct_result!(result!(provider, @tool), payload, "error")
    provider = call!(provider, @tool, %{"mode" => "mixed"})
    assert_direct_result!(result!(provider, @tool), payload, "mixed")
    provider = call!(provider, @tool, %{"mode" => "plain"})
    plain = result!(provider, @tool)
    refute plain.is_error
    assert plain.content == [%{type: :text, text: "ordinary text stays unchanged"}]
    provider
  end

  defp assert_direct_result!(result, payload, mode) do
    assert result.is_error == (mode == "error")
    assert [%{type: :text, text: json}] = result.content
    assert {:ok, ^payload} = Jason.decode(json)
  end

  defp assert_previous_result!(provider, previous) do
    restored =
      Enum.find(provider.params.context.messages, &(&1[:tool_call_id] == previous.tool_call_id))

    assert restored
    assert restored.content == previous.content
    assert restored.is_error == previous.is_error
  end

  defp assert_read_only_reopen!(path, log, payload) do
    journal_before = File.read!(path)
    requests_before = File.read!(log)
    journal_stat = File.stat!(path, time: :posix)
    requests_stat = File.stat!(log, time: :posix)

    assert {:ok, first} = Log.snapshot(path)
    assert {:ok, reopened} = Log.snapshot(path)
    assert reopened.messages == first.messages
    results = Enum.filter(reopened.messages, &(&1.role == :tool_result and &1.tool_name == @tool))
    assert length(results) == 5
    assert [empty, error, mixed, plain, repeated] = results
    assert_direct_result!(empty, payload, "empty")
    assert_direct_result!(error, payload, "error")
    assert_direct_result!(mixed, payload, "mixed")
    assert plain.content == [%{type: :text, text: "ordinary text stays unchanged"}]
    assert_direct_result!(repeated, payload, "empty")

    for {result, mode} <- Enum.zip(results, ["empty", "error", "mixed", "plain", "empty"]) do
      assert structured!(result)["details"] == envelope(payload, mode)
    end

    nested = Enum.find(reopened.messages, &(&1.role == :tool_result and &1.tool_name == "exec"))
    assert nested
    assert structured!(nested)["value"]["details"] == envelope(payload, "missing")
    assert [%{"text" => json}] = structured!(nested)["value"]["content"]
    assert {:ok, ^payload} = Jason.decode(json)

    assert File.read!(path) == journal_before
    assert File.read!(log) == requests_before
    assert File.stat!(path, time: :posix).mtime == journal_stat.mtime
    assert File.stat!(log, time: :posix).mtime == requests_stat.mtime
  end

  defp assert_calls!(log) do
    requests = log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.count(requests, &(&1["method"] == "initialize")) == 1
    calls = Enum.filter(requests, &(&1["method"] == "tools/call"))

    assert Enum.map(calls, &get_in(&1, ["params", "arguments", "mode"])) ==
             ["empty", "missing", "error", "mixed", "plain", "empty"]
  end

  defp prompt!(agent) do
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "Read the complete structured catalog")
    provider!(@root)
  end

  defp discover!(provider) do
    refute @tool in names(provider)
    provider = call!(provider, "tool_search", %{"query" => "structured catalog"})
    assert [%{"name" => @tool}] = structured!(result!(provider, "tool_search"))["tools"]
    assert @tool in names(provider)
    provider
  end

  defp provider!(session) do
    receive do
      {:structured_provider, pid, %{session_id: "child_" <> _} = params}
      when session == :child ->
        %{pid: pid, params: params}

      {:structured_provider, pid, %{session_id: id} = params} when id == session ->
        %{pid: pid, params: params}

      {:turn_error, error} ->
        flunk("structured MCP root failed: #{inspect(error)}")
    after
      8_000 -> flunk("structured MCP Provider did not start for #{session}")
    end
  end

  defp call!(provider, name, input) do
    send_call(provider, name, input)
    provider!(provider.params.session_id)
  end

  defp send_call(provider, name, input) do
    send(
      provider.pid,
      {:structured_response,
       [
         %{
           type: :tool_call,
           id: "structured-#{System.unique_integer([:positive])}",
           name: name,
           arguments: input,
           input_kind: if(is_binary(input), do: :custom, else: :function)
         }
       ]}
    )
  end

  defp finish!(provider, c) do
    send(provider.pid, {:structured_response, [%{type: :text, text: "done"}]})

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

      @root ->
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

  defp result!(provider, name) do
    Enum.find(Enum.reverse(provider.params.context.messages), &(&1[:tool_name] == name)) ||
      flunk("missing #{name} result in the actual next Provider request")
  end

  defp names(provider), do: Enum.map(provider.params.context.tools, & &1.name)

  defp structured!(result) do
    metadata = Map.get(result, :metadata, %{})

    case metadata[:structured_result] || metadata["structured_result"] do
      nil ->
        assert [%{type: :text, text: json}] = result.content
        Jason.decode!(json)

      value ->
        value
    end
  end

  defp payload do
    %{
      "items" =>
        Enum.map(1..80, fn index ->
          %{"index" => index, "label" => "条目 #{index}", "enabled" => rem(index, 2) == 0}
        end),
      "text" => String.duplicate("  完整原文\r\nwith spaces\n", 100),
      "none" => nil,
      "enabled" => true,
      "disabled" => false,
      "nested" => %{"tail" => [nil, false, true, "最终条目"]}
    }
  end

  defp envelope(payload, mode) do
    result =
      if mode == "plain",
        do: %{"isError" => false},
        else: %{"structuredContent" => payload, "isError" => mode == "error"}

    case mode do
      "missing" ->
        result

      mode when mode in ["mixed", "plain"] ->
        Map.put(result, "content", [
          %{"type" => "text", "text" => "ordinary text stays unchanged"}
        ])

      _ ->
        Map.put(result, "content", [])
    end
  end

  defp fixture do
    ~S"""
    import json,sys
    payload=json.load(open(sys.argv[1]))
    log=sys.argv[2]
    for line in sys.stdin:
        request=json.loads(line)
        method=request.get('method')
        ident=request.get('id')
        params=request.get('params',{})
        with open(log,'a') as output:
            output.write(json.dumps({'method':method,'params':params})+'\n')
        if ident is None: continue
        if method=='initialize':
            result={'protocolVersion':'2025-06-18','capabilities':{'tools':{}},'serverInfo':{'name':'catalog','version':'1'}}
        elif method=='tools/list':
            result={'tools':[{'name':'read_catalog','description':'Read the complete structured catalog','inputSchema':{'type':'object','properties':{'mode':{'type':'string'}},'required':['mode'],'additionalProperties':False}}]}
        elif method=='tools/call':
            mode=params['arguments']['mode']
            result={'structuredContent':payload,'isError':mode=='error'}
            if mode!='missing': result['content']=[]
            if mode in ['mixed','plain']: result['content']=[{'type':'text','text':'ordinary text stays unchanged'}]
            if mode=='plain': del result['structuredContent']
            if mode=='unknown':
                result={'content':[
                    {'type':'text','text':'ordinary sibling 中文\r\n  '},
                    {'type':'resource','resource':{'uri':'catalog://guide/中文','mimeType':'text/plain','text':'  embedded 中文\r\nsecond line\n'},'_meta':{'catalog/source':{'version':1,'cached':False}}},
                    {'type':'resource_link','uri':'https://example.test/catalog/guide','name':'目录指南','description':'  完整说明\r\nwith spaces\n','mimeType':'text/plain','_meta':{'catalog/link':{'optional':None}}},
                    {'type':'catalog_future','payload':payload,'_meta':{'catalog/future':{'enabled':True,'disabled':False}}}
                ],'isError':False,'_meta':{'catalog/receipt':{'complete':True,'optional':None}}}
        else:
            print(json.dumps({'jsonrpc':'2.0','id':ident,'error':{'code':-32601,'message':'Method not found'}}),flush=True)
            continue
        print(json.dumps({'jsonrpc':'2.0','id':ident,'result':result}),flush=True)
    """
  end
end
