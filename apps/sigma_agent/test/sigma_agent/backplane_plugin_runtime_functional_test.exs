defmodule Sigma.Agent.BackplanePluginRuntimeFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.PluginProtocol.Archive
  alias Sigma.Agent.Backplane.PluginRuntime
  alias Sigma.Coding.{Dispatcher, ToolResult}

  @moduletag :tmp_dir

  defmodule RetainedCleanupAdapter do
    alias Backplane.AgentRuntime.Error

    def start(_config, opts) do
      ledger = Keyword.fetch!(opts, :env)["SIGMA_CLEANUP_FIXTURE"]

      connection =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      File.write!(ledger <> ".pid", :erlang.term_to_binary(connection))
      {:ok, %{supervisor: connection, ledger: ledger}}
    end

    def tools(_connection, _timeout) do
      {:ok,
       [
         %{
           "name" => "echo",
           "description" => "Retained cleanup fixture",
           "inputSchema" => %{"type" => "object", "properties" => %{}}
         }
       ]}
    end

    def call(_connection, _name, _arguments, _timeout),
      do: {:ok, %{"content" => [%{"type" => "text", "text" => "still active"}]}}

    def stop(connection) do
      File.write!(connection.ledger, "cleanup\n", [:append])

      {:error,
       Error.new(:execution_failure, "fixture MCP cleanup failed",
         details: %{component: "example"}
       )}
    end
  end

  test "public plugin functions retain MCP results through Dispatcher and close their actual processes",
       %{tmp_dir: dir} do
    plugin = plugin!(dir, "example", "release-one")
    before = package_state(plugin)
    runtime = runtime!([plugin.record], "root-run")
    assert {:ok, [tool]} = PluginRuntime.tools(runtime)
    assert tool.description == "Complete plugin output"
    assert tool.schema["required"] == ["value"]
    assert is_function(tool.call_tool, 3)
    assert Process.alive?(tool.client)

    value = "  完整结果 e\u0301 👩‍💻\r\n尾行"
    assert {:ok, %ToolResult{} = result} = dispatch(tool, %{"value" => value}, dir)
    assert [%{type: :text, text: json}] = result.content
    assert Jason.decode!(json) == %{"release" => "release-one", "value" => value}
    assert result.details["structuredContent"] == Jason.decode!(json)
    refute result.is_error

    assert {:ok, %ToolResult{is_error: true}} =
             dispatch(tool, %{"value" => "ordinary failure", "fail" => true}, dir)

    assert {:ok, %ToolResult{is_error: false}} = dispatch(tool, %{"value" => "continued"}, dir)

    assert {:ok,
            %ToolResult{
              content: [%{type: :image, data: image, mime_type: "image/png", detail: "original"}],
              is_error: false
            } = image_result} = dispatch(tool, %{"value" => "image-only", "image" => true}, dir)

    assert String.starts_with?(image, "iVBORw0KGgo")

    assert image_result.details["content"] == [
             %{
               "type" => "image",
               "data" => image,
               "mimeType" => "image/png",
               "_meta" => %{"codex/imageDetail" => "original"}
             }
           ]

    assert {:ok, %{run_id: "root-run", entries: [entry]}} = PluginRuntime.snapshot(runtime)
    assert entry.session == tool.client
    assert entry.components["example"].status == :ready
    assert entry.diagnostics == []
    assert [started | calls] = events(plugin.log)
    assert started["event"] == "started"
    assert length(calls) == 4
    assert :ok = PluginRuntime.close(runtime)
    assert eventually(fn -> not File.exists?("/proc/#{started["pid"]}") end)
    refute Process.alive?(tool.client)
    assert :ok = PluginRuntime.close(runtime)

    assert {:ok,
            %{
              close_result: :ok,
              entries: [
                %{
                  close_result: :ok,
                  cleanup_report: %{
                    outcome: :confirmed,
                    run_id: "root-run",
                    components: %{"example" => %{outcome: :confirmed}}
                  }
                }
              ]
            }} =
             PluginRuntime.snapshot(runtime)

    assert events(plugin.log) == [started | calls]
    assert package_state(plugin) == before
  end

  test "root and child runs own separate public Sessions and pin immutable releases",
       %{tmp_dir: dir} do
    first = plugin!(dir, "example", "release-one")
    root = runtime!([first.record], "root-run")
    child = runtime!([first.record], "child-run")
    assert {:ok, [root_tool]} = PluginRuntime.tools(root)
    assert {:ok, [child_tool]} = PluginRuntime.tools(child)
    assert root_tool.name == child_tool.name
    assert root_tool.server_id == child_tool.server_id
    refute root_tool.client == child_tool.client

    second = plugin!(dir, "example", "release-two")
    following = runtime!([second.record], "child-followup")
    assert {:ok, [next_tool]} = PluginRuntime.tools(following)
    assert next_tool.name == root_tool.name
    refute next_tool.server_id == root_tool.server_id

    assert {:ok, old_result} = PluginRuntime.call_tool(root, root_tool.name, %{"value" => "root"})
    assert old_result["structuredContent"] == %{"release" => "release-one", "value" => "root"}
    assert :ok = PluginRuntime.close(child)
    assert Process.alive?(root_tool.client)

    assert {:ok, next_result} =
             PluginRuntime.call_tool(following, next_tool.name, %{"value" => "followup"})

    assert next_result["structuredContent"] == %{
             "release" => "release-two",
             "value" => "followup"
           }

    assert {:ok, unchanged} = PluginRuntime.call_tool(root, root_tool.name, %{"value" => "again"})
    assert unchanged["structuredContent"]["release"] == "release-one"
    assert :ok = PluginRuntime.close(root)
    assert :ok = PluginRuntime.close(following)

    assert eventually(fn ->
             Enum.all?(events(first.log) ++ events(second.log), fn event ->
               event["event"] != "started" or not File.exists?("/proc/#{event["pid"]}")
             end)
           end)
  end

  test "ordinary owner retirement joins the public Session and actual MCP process",
       %{tmp_dir: dir} do
    plugin = plugin!(dir, "example", "release-one")

    owner =
      spawn(fn ->
        receive do
          :retire -> :ok
        end
      end)

    runtime = runtime!([plugin.record], "owned-run", owner)
    assert {:ok, [tool]} = PluginRuntime.tools(runtime)
    assert [%{"event" => "started", "pid" => pid}] = events(plugin.log)
    monitor = Process.monitor(runtime)
    send(owner, :retire)
    assert_receive {:DOWN, ^monitor, :process, ^runtime, :normal}, 5_000
    refute Process.alive?(tool.client)
    assert eventually(fn -> not File.exists?("/proc/#{pid}") end)
  end

  test "an empty installed inventory creates no plugin Sessions", %{tmp_dir: dir} do
    runtime = runtime!([], "empty-run")
    assert {:ok, []} = PluginRuntime.tools(runtime)
    assert {:ok, %{entries: [], close_result: nil}} = PluginRuntime.snapshot(runtime)
    assert :ok = PluginRuntime.close(runtime)
    assert :ok = PluginRuntime.close(runtime)
    assert File.ls!(dir) == []
  end

  test "partial preparation retains the actual started Session until explicit cleanup",
       %{tmp_dir: dir} do
    plugin = plugin!(dir, "example", "release-one")
    before = package_state(plugin)
    incomplete = Map.delete(plugin.record, "root")
    runtime = runtime!([plugin.record, incomplete], "partially-prepared-run")

    assert {:error, %Backplane.AgentRuntime.Error{class: :validation} = original} =
             PluginRuntime.tools(runtime)

    assert {:ok, %{preparation_error: ^original, entries: [entry], close_result: nil}} =
             PluginRuntime.snapshot(runtime)

    assert Process.alive?(entry.session)
    assert [%{"event" => "started", "pid" => pid}] = events(plugin.log)
    assert :ok = PluginRuntime.close(runtime)
    refute Process.alive?(entry.session)
    assert eventually(fn -> not File.exists?("/proc/#{pid}") end)
    assert :ok = PluginRuntime.close(runtime)
    assert {:error, ^original} = PluginRuntime.tools(runtime)

    assert {:ok, %{preparation_error: ^original, entries: [%{close_result: :ok}]}} =
             PluginRuntime.snapshot(runtime)

    assert [%{"event" => "started", "pid" => ^pid}] = events(plugin.log)
    assert package_state(plugin) == before
  end

  test "a retired runtime preserves unknown outcomes through its MCP callback and Dispatcher",
       %{tmp_dir: dir} do
    plugin = plugin!(dir, "example", "release-one")
    runtime = runtime!([plugin.record], "retired-run")
    assert {:ok, [tool]} = PluginRuntime.tools(runtime)
    assert :ok = PluginRuntime.close(runtime)
    assert :ok = GenServer.stop(runtime, :normal)
    before = events(plugin.log)
    arguments = %{"value" => "after retirement"}

    assert {:error, %Backplane.AgentRuntime.Error{class: :unknown_outcome} = original} =
             PluginRuntime.call_tool(runtime, tool.name, arguments)

    assert {:error, %Sigma.Coding.ToolError{kind: :unknown_outcome} = callback_error} =
             tool.call_tool.("retired-call", arguments, [])

    assert callback_error.message == original.message
    assert callback_error.details == Backplane.AgentRuntime.Error.to_map(original)
    assert {:error, ^callback_error} = dispatch(tool, arguments, dir)
    assert events(plugin.log) == before
  end

  test "public cleanup failures retain their exact report without retrying independent bindings",
       %{tmp_dir: dir} do
    plugin = plugin!(dir, "example", "release-one")

    bindings =
      for run <- ["root-failed-cleanup", "child-failed-cleanup"] do
        ledger = Path.join(dir, run <> ".cleanup")

        on_exit(fn ->
          if File.exists?(ledger <> ".pid") do
            connection = :erlang.binary_to_term(File.read!(ledger <> ".pid"))
            send(connection, :stop)
          end
        end)

        runtime =
          runtime!([plugin.record], run, self(),
            mcp_adapter: RetainedCleanupAdapter,
            env: %{"SIGMA_CLEANUP_FIXTURE" => ledger}
          )

        assert {:ok, [tool]} = PluginRuntime.tools(runtime)
        connection = :erlang.binary_to_term(File.read!(ledger <> ".pid"))

        on_exit(fn ->
          # The public owner monitor may retire the Session after the test
          # exits. Join that exact process instead of racing alive?/stop.
          monitor = Process.monitor(tool.client)

          try do
            GenServer.stop(tool.client, :normal)
          catch
            :exit, {:noproc, _} -> :ok
          end

          assert_receive {:DOWN, ^monitor, :process, pid, reason}
                         when pid == tool.client and reason in [:normal, :noproc],
                         2_000
        end)

        %{
          runtime: runtime,
          session: tool.client,
          tool: tool,
          connection: connection,
          ledger: ledger
        }
      end

    [root, child] = bindings
    refute root.session == child.session
    refute root.connection == child.connection

    for binding <- [child, root] do
      assert {:error,
              %Backplane.AgentRuntime.Error{
                class: :unknown_outcome,
                details: %{report: %{outcome: :unconfirmed, components: components}}
              } = original} = PluginRuntime.close(binding.runtime)

      assert %{
               outcome: :failed,
               cleanup:
                 {:error,
                  %{
                    class: :execution_failure,
                    message: "fixture MCP cleanup failed",
                    details: %{component: "example"}
                  }}
             } = components["example"]

      assert Process.alive?(binding.session)
      assert Process.alive?(binding.connection)
      assert File.read!(binding.ledger) == "cleanup\n"
      assert {:error, ^original} = PluginRuntime.close(binding.runtime)
      assert File.read!(binding.ledger) == "cleanup\n"

      assert {:ok, %{close_result: {:error, ^original}, entries: [entry]}} =
               PluginRuntime.snapshot(binding.runtime)

      assert entry.close_result == {:error, original}
      assert entry.cleanup_report == original.details.report

      assert {:ok, report} =
               Backplane.AgentRuntime.Plugins.Session.cleanup_status(binding.session)

      assert report == entry.cleanup_report

      if binding == child do
        assert {:ok, %{"content" => [%{"text" => "still active"}]}} =
                 PluginRuntime.call_tool(root.runtime, root.tool.name, %{})
      end
    end
  end

  defp runtime!(installations, run_id, owner \\ self(), session_options \\ []) do
    start_supervised!(
      Supervisor.child_spec(
        {PluginRuntime,
         owner_pid: owner,
         run_id: run_id,
         installations: installations,
         session_options: session_options},
        id: {PluginRuntime, run_id}
      )
    )
  end

  defp dispatch(tool, arguments, cwd) do
    Dispatcher.dispatch(
      %{
        id: "plugin-#{System.unique_integer([:positive])}",
        name: tool.name,
        arguments: arguments
      },
      [tool],
      cwd: cwd,
      session_id: "plugin-runtime-functional"
    )
  end

  defp plugin!(dir, id, release) do
    python = System.find_executable("python3")
    assert is_binary(python)
    root = Path.join(dir, release)
    data = Path.join(dir, "data-" <> release)

    files = %{
      "plugin.json" =>
        Jason.encode!(%{
          "$schema" => "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
          "name" => id,
          "version" => "1.0.0"
        }),
      "mcp.json" =>
        Jason.encode!(%{
          "$schema" => "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json",
          "mcpServers" => %{
            id => %{
              "type" => "stdio",
              "command" => "./mcp-server",
              "args" => ["${PLUGIN_DATA}/calls.jsonl", release]
            }
          }
        }),
      "mcp-server" => "#!#{python}\n" <> server()
    }

    modes = %{"plugin.json" => 0o644, "mcp.json" => 0o644, "mcp-server" => 0o755}
    assert {:ok, archive} = Archive.pack(files, modes: modes)

    for {name, bytes} <- files do
      path = Path.join(root, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
      File.chmod!(path, Map.fetch!(modes, name))
    end

    digest = Archive.digest(archive)

    record = %{
      "status" => "installed",
      "registry_url" => "https://plugins.example",
      "plugin_id" => id,
      "release_id" => release,
      "artifact_digest" => digest,
      "content_digest" => digest,
      "root" => root,
      "data_dir" => data
    }

    %{record: record, root: root, log: Path.join(data, "calls.jsonl")}
  end

  defp package_state(plugin) do
    Map.new(Path.wildcard(Path.join(plugin.root, "**/*")), fn path ->
      stat = path |> File.stat!(time: :posix) |> Map.take([:size, :mtime, :ctime, :inode, :mode])
      {path, {File.read!(path), stat}}
    end)
  end

  defp events(path),
    do: path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  defp eventually(fun, attempts \\ 150)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp server do
    """
    import json,os,sys
    log,release=sys.argv[1:]
    with open(log,'a') as f: f.write(json.dumps({'event':'started','pid':os.getpid()})+'\\n')
    for line in sys.stdin:
        request=json.loads(line)
        if 'id' not in request: continue
        method=request['method']
        if method=='server/discover':
            print(json.dumps({'jsonrpc':'2.0','id':request['id'],'error':{'code':-32601,'message':'Method not found'}}),flush=True)
            continue
        if method=='initialize':
            result={'protocolVersion':'2025-03-26','capabilities':{'tools':{}},'serverInfo':{'name':'example','version':'1.0.0'}}
        elif method=='tools/list':
            result={'tools':[{'name':'echo','description':'Complete plugin output','inputSchema':{'type':'object','properties':{'value':{'type':'string'},'fail':{'type':'boolean'},'image':{'type':'boolean'}},'required':['value']}}]}
        elif method=='tools/call':
            arguments=request['params']['arguments']
            with open(log,'a') as f: f.write(json.dumps({'event':'called','arguments':arguments})+'\\n')
            result={'content':[{'type':'text','text':'summary'}],'structuredContent':{'release':release,'value':arguments['value']},'isError':arguments.get('fail',False)}
            if arguments.get('image'):
                result={'content':[{'type':'image','mimeType':'image/png','data':'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jLfkAAAAASUVORK5CYII=','_meta':{'codex/imageDetail':'original'}}],'isError':False}
        else: result={}
        print(json.dumps({'jsonrpc':'2.0','id':request['id'],'result':result}),flush=True)
    """
  end
end
