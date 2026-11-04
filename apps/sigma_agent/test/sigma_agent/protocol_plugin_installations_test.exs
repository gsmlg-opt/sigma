defmodule Sigma.Agent.ProtocolPluginInstallationsTest do
  use ExUnit.Case, async: false

  alias Backplane.PluginProtocol.Archive
  alias Sigma.Agent.{PublicRuntime, Runtime}
  alias Sigma.Agent.Backplane.{CodexResources, NativeTools, PluginResources}
  alias Backplane.AgentRuntime.Codex.Session
  alias Sigma.Protocol.{Codec, Envelope}

  @moduletag :tmp_dir
  @session "plugin-installation-protocol"
  @capability "plugins.install.v1"

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    def stream(params) do
      send(params.options[:test_pid], {:plugin_protocol_provider, self(), params})

      receive do
        {:plugin_protocol_response, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            content: content,
            stop_reason: reason,
            usage: %{input: 1, output: 1, total_tokens: 2},
            model: "plugin-protocol-test",
            provider: "plugin-protocol-test",
            api: "openai-responses",
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, reason, message}]
      end
    end
  end

  setup %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    sessions = Path.join(dir, "sessions")
    agent_dir = Path.join(dir, "agent")
    File.mkdir_p!(repo)
    File.mkdir_p!(sessions)
    File.mkdir_p!(agent_dir)
    previous = Application.get_env(:sigma_session, :agent_dir)
    Application.put_env(:sigma_session, :agent_dir, agent_dir)

    # The live session override is intentionally different from global settings.
    File.write!(
      Path.join(agent_dir, "settings.json"),
      Jason.encode!(%{
        "plugins" => %{
          "registryUrl" => "http://global-config.example",
          "requestsRoot" => Path.join(dir, "global-plugins")
        }
      })
    )

    files = %{
      "plugin.json" =>
        Jason.encode!(%{
          "$schema" => "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
          "name" => "example",
          "version" => "1.0.0"
        }),
      "skills/example/SKILL.md" =>
        "---\r\nname: example\r\ndescription: Plugin protocol skill\r\n---\r\n完整 e\u0301\r\n"
    }

    assert {:ok, archive} = Archive.pack(files)
    File.write!(Path.join(dir, "artifact.tgz"), archive)

    release = %{
      "plugin_id" => "plugin-example",
      "release_id" => "release-example",
      "artifact_digest" => Archive.digest(archive)
    }

    File.write!(Path.join(dir, "release.json"), Jason.encode!(release))
    log = Path.join(dir, "registry.jsonl")
    File.write!(log, "")

    port =
      Port.open({:spawn_executable, System.find_executable("python3")}, [
        :binary,
        :exit_status,
        args: ["-u", "-c", registry(), dir]
      ])

    assert_receive {^port, {:data, address}}, 5_000
    {number, ""} = Integer.parse(String.trim(address))
    root = Path.join(dir, "plugins")
    config = %{"registryUrl" => "http://127.0.0.1:#{number}", "requestsRoot" => root}

    context = %{
      repo_path: repo,
      sessions_dir: sessions,
      session_opts: [
        native_tools: true,
        native_plugins: config,
        native_memory_root: Path.join(dir, "memories"),
        tools: [],
        hook_specs: [],
        model: %{
          id: "plugin-protocol-test",
          provider: "plugin-protocol-test",
          api: "openai-responses"
        },
        provider: Provider,
        options: [test_pid: self()]
      ]
    }

    assert {:ok, _} = execute(context, "session.create", %{"cwd" => repo})

    on_exit(fn ->
      if supervisor = Runtime.lookup(repo, :supervisor),
        do: DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, supervisor)

      for plugin_root <- [root, Path.join(dir, "global-plugins")] do
        case Registry.lookup(Sigma.Agent.RepositoryRegistry, {:plugin_requests, plugin_root}) do
          [{writer, _}] -> GenServer.stop(writer, :normal)
          [] -> :ok
        end
      end

      if Port.info(port), do: Port.close(port)

      if previous,
        do: Application.put_env(:sigma_session, :agent_dir, previous),
        else: Application.delete_env(:sigma_session, :agent_dir)
    end)

    %{
      dir: dir,
      root: root,
      config: config,
      context: context,
      log: log,
      files: files,
      requests: Path.join(root, "requests.json"),
      ledger: Path.join(root, "installations.json"),
      journal: Path.join(sessions, @session <> ".jsonl")
    }
  end

  test "live configured requests page, install and reopen keep exact durable outcomes without replay",
       c do
    [first, second] = requests!(c, 2)
    requests_before = file_state(c.requests)
    journal_before = file_state(c.journal)

    assert {:ok, page} = execute(c.context, "plugins.requests", opted(%{"limit" => 1}))
    assert page.type == "plugins.requests.page"
    assert page.payload["registryUrl"] == c.config["registryUrl"]
    assert page.payload["configured"]
    assert page.payload["total"] == 2

    assert [%{"requestId" => second_id, "requestStatus" => "requested", "status" => "requested"}] =
             page.payload["items"]

    assert second_id == second["id"]
    assert page.payload["nextOffset"] == 1

    continuation = %{
      "limit" => 1,
      "offset" => 1,
      "expectedRevision" => page.payload["revision"]
    }

    assert {:ok, next} = execute(c.context, "plugins.requests", opted(continuation))
    assert [%{"requestId" => first_id}] = next.payload["items"]
    assert first_id == first["id"]
    assert is_nil(next.payload["nextOffset"])
    assert File.read!(c.log) == ""

    assert {:ok, installed} =
             execute(c.context, "plugins.install", opted(%{"requestId" => first_id}))

    assert installed.type == "plugins.installed"
    receipt = installed.payload["installation"]
    assert receipt["requestId"] == first_id
    assert receipt["status"] == "installed"
    assert receipt["releaseId"] == "release-example"
    assert receipt["registryUrl"] == c.config["registryUrl"]
    assert length(http_requests(c)) == 2

    assert {:error, %{error: %{code: "plugin_requests_stale"}}} =
             execute(c.context, "plugins.requests", opted(continuation))

    assert {:ok, current} = execute(c.context, "plugins.requests", opted())

    assert Enum.find(current.payload["items"], &(&1["requestId"] == first_id))["status"] ==
             "installed"

    ledger_before = file_state(c.ledger)

    assert {:ok, repeated} =
             execute(c.context, "plugins.install", opted(%{"requestId" => first_id}))

    assert repeated.payload == installed.payload
    assert file_state(c.ledger) == ledger_before
    assert file_state(c.requests) == requests_before
    assert file_state(c.journal) == journal_before
    assert length(http_requests(c)) == 2

    [{writer, _}] = Registry.lookup(Sigma.Agent.RepositoryRegistry, {:plugin_requests, c.root})
    GenServer.stop(writer, :normal)
    assert {:ok, reopened} = execute(c.context, "plugins.requests", opted())
    assert reopened.payload == current.payload
    assert file_state(c.ledger) == ledger_before
    assert file_state(c.requests) == requests_before
    assert file_state(c.journal) == journal_before
    assert length(http_requests(c)) == 2
  end

  test "explicit nil session configuration remains disabled despite global plugin settings", c do
    disabled =
      put_in(
        c.context,
        [:session_opts],
        Keyword.put(c.context.session_opts, :native_plugins, nil)
      )

    assert {:ok, _} =
             execute(disabled, "session.create", %{"cwd" => c.context.repo_path}, "disabled")

    assert {:ok, page} = execute(disabled, "plugins.requests", opted(), "disabled")
    assert page.payload["configured"] == false
    assert page.payload["items"] == []
    assert page.payload["total"] == 0
    assert is_nil(page.payload["registryUrl"])
    assert File.read!(c.log) == ""
    refute File.exists?(Path.join(c.dir, "global-plugins"))
  end

  test "Protocol explicit installation completes the waiting native invocation and next Provider",
       c do
    agent = Runtime.lookup(c.context.repo_path, @session, :agent)
    assert :ok = Sigma.Agent.subscribe(agent)
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "Install the plugin")
    {pid, _params} = provider!()
    send(pid, {:plugin_protocol_response, [plugin_call("native-protocol-install")]})
    assert eventually(fn -> File.exists?(c.requests) end)
    [request] = Jason.decode!(File.read!(c.requests))["requests"]
    refute_receive {:plugin_protocol_provider, _, _}, 50
    before = file_state(c.requests)

    assert {:ok, event} =
             execute(c.context, "plugins.install", opted(%{"requestId" => request["id"]}))

    assert event.payload["installation"]["status"] == "installed"
    {pid, params} = provider!()

    result =
      Enum.find(
        params.context.messages,
        &(Map.get(&1, :tool_call_id) == "native-protocol-install")
      )

    assert result
    completed = plugin_result!(result)
    assert completed["status"] == "completed"
    assert completed["user_confirmed"]
    assert completed["request_id"] == request["plugin_request_id"]
    send(pid, {:plugin_protocol_response, [%{type: :text, text: "installed"}]})
    assert_receive {:agent_end, _}, 10_000

    assert {:ok, _} =
             Sigma.Session.Writer.flush(Runtime.lookup(c.context.repo_path, @session, :writer))

    assert file_state(c.requests) == before
    assert length(http_requests(c)) == 2
    assert {:ok, journal} = Sigma.Session.Log.snapshot(c.journal)
    saved = Enum.find(journal.messages, &(field(&1, :tool_call_id) == "native-protocol-install"))
    assert saved
    assert field(saved, :role) in [:tool_result, "tool_result"]
    refute field(saved, :is_error)
    assert plugin_result!(saved) == completed
    assert completed["tool_id"] == request["arguments"]["tool_id"]
    assert completed["completed"]
  end

  test "installation failure preserves the public error class and the requested receipt", c do
    [request] = requests!(c, 1)
    before = file_state(c.requests)
    File.write!(Path.join(c.dir, "release.json"), Jason.encode!(%{"_status" => 503}))

    assert {:error, event} =
             execute(c.context, "plugins.install", opted(%{"requestId" => request["id"]}))

    assert event.type == "session.error"
    assert event.error.code == "execution_failure"
    assert event.error.message == "plugin package preparation failed"
    assert event.error.details == %{}
    assert file_state(c.requests) == before
    refute File.exists?(c.ledger)
    assert {:ok, page} = execute(c.context, "plugins.requests", opted())
    assert [%{"status" => "requested"}] = page.payload["items"]
  end

  defp requests!(c, count) do
    resources =
      start_supervised!(
        {CodexResources,
         workspace: c.context.repo_path,
         owner_pid: self(),
         plugins: c.config,
         memory_root: Path.join(c.dir, "request-memories")}
      )

    authority = %{
      caller: "protocol-request-only",
      run_id: "protocol-request-only",
      grants: NativeTools.plugin_names(),
      tool_revision: 1
    }

    assert {:ok, binding} = CodexResources.bind(resources, authority)
    assert {:ok, context} = CodexResources.context(resources, binding)

    assert {:ok, profile} =
             NativeTools.profile(context, authority, %{}, tools: NativeTools.plugin_names())

    assert :ok = Session.attach(binding, profile)

    requests =
      Enum.map(1..count, fn index ->
        call = plugin_call("plugin-protocol-#{index}")

        operation = %{
          run_id: binding.run_id,
          incarnation: binding.run_incarnation,
          caller: authority.caller,
          invocation_id: call.id,
          tool_call_id: call.id,
          tool_name: call.name,
          arguments: call.arguments,
          backend_context: %{plugin_resources: context.plugin_resources}
        }

        assert {:ok, request} = PluginResources.request_install(call.arguments, operation)
        request
      end)

    assert :ok = Session.prepare_detach(binding)
    assert {:ok, %{status: :retained}} = Session.detach(binding)
    assert {:ok, %{status: :confirmed}} = CodexResources.close(resources)
    requests
  end

  defp plugin_call(id),
    do: %{
      type: :tool_call,
      id: id,
      name: "request_plugin_install",
      arguments: %{
        "tool_type" => "plugin",
        "action_type" => "install",
        "tool_id" => "plugin-example",
        "suggest_reason" => "  安装请求 #{id}\r\n完整 e\u0301"
      },
      input_kind: :function
    }

  defp eventually(check, left \\ 500)
  defp eventually(check, 0), do: check.()

  defp eventually(check, left) do
    if check.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(check, left - 1)
        )
  end

  defp provider! do
    receive do
      {:plugin_protocol_provider, pid, params} -> {pid, params}
      {:turn_error, error} -> flunk("plugin protocol turn failed: #{inspect(error)}")
    after
      10_000 -> flunk("plugin protocol Provider did not start")
    end
  end

  defp plugin_result!(message) do
    message
    |> field(:content)
    |> Enum.find(&(field(&1, :type) in [:text, "text"]))
    |> field(:text)
    |> Jason.decode!()
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp execute(context, type, payload, session \\ @session) do
    assert {:ok, command} = Envelope.command(type, session, payload)
    assert {:ok, encoded} = Codec.encode(command)
    assert {:ok, command} = Codec.decode(encoded)
    result = PublicRuntime.execute(command, context)

    case result do
      {_, %Envelope{} = event} ->
        assert {:ok, response} = Codec.encode(event)
        assert {:ok, ^event} = Codec.decode(response)

      _ ->
        :ok
    end

    result
  end

  defp opted(payload \\ %{}), do: Map.put(payload, "requiredCapabilities", [@capability])

  defp http_requests(c),
    do: File.read!(c.log) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  defp file_state(path) do
    stat = File.stat!(path, time: :posix)
    {File.read!(path), stat.mtime, stat.inode}
  end

  defp registry do
    """
    import http.server,json,sys,threading,pathlib,urllib.parse
    directory=pathlib.Path(sys.argv[1])
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self,*args): pass
        def do_GET(self):
            with (directory/'registry.jsonl').open('a') as log: log.write(json.dumps({'path':self.path})+'\\n')
            path=urllib.parse.urlsplit(self.path).path
            if '/artifacts/' in path:
                body=(directory/'artifact.tgz').read_bytes()
                status=200
            else:
                value=json.loads((directory/'release.json').read_text())
                body=json.dumps(value).encode()
                status=value.get('_status',200)
            self.send_response(status)
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
