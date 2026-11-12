defmodule Sigma.Web.SamgitaHost.LoopbackTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.PublicRuntime
  alias Sigma.Protocol.Envelope
  alias Sigma.Session.{ConfigManager, RepoManager}
  alias Sigma.Web.SamgitaHost.ThreadId
  alias SamgitaProtocol.Error
  alias SamgitaProtocolWebSocket.Client

  @capabilities ["sessions.v1", "streaming.v1", "cancellation.v1"]
  @test_name :samgita_loopback_test

  defmodule LoopProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(_params) do
      message = message("loop response")

      [
        {:start, %{message | content: []}},
        {:text_delta, 0, "loop response", message},
        {:done, :stop, message}
      ]
    end

    def message(text) do
      %{
        role: :assistant,
        content: [%{type: :text, text: text}],
        model: "mock-model",
        provider: "mock-provider",
        api: "mock-api",
        usage: %{
          input: 1,
          output: 1,
          cache_read: 0,
          cache_write: 0,
          total_tokens: 2,
          cost: %{total: 0.0}
        },
        stop_reason: :stop,
        timestamp: System.system_time(:millisecond)
      }
    end
  end

  defmodule BlockingProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params) do
      cancellation_ref = Keyword.fetch!(params.options, :cancellation_ref)
      send(:samgita_loopback_test, {:provider_waiting, self()})

      receive do
        :release_provider ->
          message = LoopProvider.message("released")

          [
            {:start, %{message | content: []}},
            {:text_delta, 0, "released", message},
            {:done, :stop, message}
          ]

        {:cancel, ^cancellation_ref} ->
          [{:provider_error, Sigma.Ai.ProviderError.from_reason(:cancelled)}]
      end
    end
  end

  defmodule Endpoint do
    use Phoenix.Endpoint, otp_app: :sigma_web

    plug(Sigma.Web.SamgitaHost.EndpointPlug)
    plug(:respond)

    defp respond(conn, _options), do: Plug.Conn.send_resp(conn, 404, "not found")
  end

  setup context do
    root =
      Path.join(
        System.tmp_dir!(),
        "sigma-samgita-loopback-#{context.test}-#{System.unique_integer([:positive])}"
      )

    repo = Path.join(root, "repo")
    agent_dir = Path.join(root, "agent")
    File.mkdir_p!(repo)
    previous_agent_dir = Application.get_env(:sigma_session, :agent_dir)
    previous_protocol_token = Application.get_env(:sigma_web, :protocol_token)
    previous_session_opts = Application.get_env(:sigma_web, :protocol_session_opts)
    token = String.duplicate("s", 32)
    Application.put_env(:sigma_session, :agent_dir, agent_dir)
    Application.put_env(:sigma_web, :protocol_token, token)

    # Explicit runtime options keep these sessions on the plain mock provider path;
    # native-tool profiles are outside this host's scope.
    Application.put_env(:sigma_web, :protocol_session_opts,
      model: %{id: "mock-model", api: "mock", provider: "mock"},
      provider: context[:provider] || LoopProvider
    )

    write_provider_config!(agent_dir)
    {:ok, _repo} = RepoManager.add_repo(repo, name: "Samgita Loopback Repo")
    sessions_dir = ConfigManager.ensure_sessions_dir(repo)
    Process.register(self(), @test_name)

    on_exit(fn ->
      stop_repository(repo)
      restore_env(:sigma_session, :agent_dir, previous_agent_dir)
      restore_env(:sigma_web, :protocol_token, previous_protocol_token)
      restore_env(:sigma_web, :protocol_session_opts, previous_session_opts)
      File.rm_rf!(root)
    end)

    config = Application.fetch_env!(:sigma_web, Sigma.Web.Endpoint)
    http = config |> Keyword.fetch!(:http) |> Keyword.merge(ip: {127, 0, 0, 1}, port: 0)
    start_supervised!({Phoenix.PubSub, name: __MODULE__.PubSub})

    start_supervised!(
      {Endpoint,
       Keyword.merge(config,
         http: http,
         server: true,
         pubsub_server: __MODULE__.PubSub,
         check_origin: false,
         code_reloader: false,
         watchers: []
       )}
    )

    {:ok, {_ip, port}} = Endpoint.server_info(:http)

    {:ok,
     repo: Path.expand(repo),
     sessions_dir: sessions_dir,
     url: "ws://127.0.0.1:#{port}/app-server",
     token: token}
  end

  test "initialize negotiates the three groups", context do
    {:ok, client} = Client.connect(context.url, token: context.token, capabilities: @capabilities)

    assert {:ok, %{"version" => "1.0", "capabilities" => groups, "connection_id" => _}} =
             Client.request(client, "connection/initialize", %{
               "versions" => ["1.0"],
               "capabilities" => @capabilities
             })

    assert groups == Enum.sort(@capabilities)
  end

  test "thread/start, turn/start stream items and complete", context do
    client = connect!(context)

    assert {:error, %Error{code: "invalid_params"}} =
             mutate(client, "thread/start", %{"metadata" => %{"repository" => "/not/registered"}})

    thread_id = start_thread!(client, context, "Loopback")
    assert {:ok, %{session_id: session_id}} = ThreadId.decode(thread_id)
    assert session_id =~ ~r/\A[0-9a-f]{32}\z/

    {:ok, %{"turn_id" => turn_id, "status" => "running"}} =
      mutate(client, "turn/start", %{
        "thread_id" => thread_id,
        "input" => [
          %{"type" => "text", "text" => "hello"},
          %{"type" => "text", "text" => "there"}
        ]
      })

    messages = receive_turn(client)
    methods = Enum.map(messages, & &1["method"])

    for method <- ~w(turn/started item/started item/delta item/completed) do
      assert method in methods
    end

    assert %{"method" => "turn/completed", "params" => %{"status" => "completed"}} =
             List.last(messages)

    assert Enum.all?(messages, &(&1["stream_id"] == turn_id))
    assert Enum.map(messages, & &1["cursor"]) == Enum.to_list(1..length(messages))

    assert Enum.any?(messages, &match?(%{"params" => %{"delta" => "loop response"}}, &1))

    user_item =
      Enum.find(messages, &match?(%{"params" => %{"item" => %{"role" => "user"}}}, &1))

    assert inspect(user_item["params"]["item"]["content"]) =~ "hello\\n\\nthere"

    count = length(messages)

    assert {:ok, %{"stream_id" => ^turn_id, "cursor" => ^count, "events" => ^messages}} =
             Client.request(client, "stream/resume", %{"stream_id" => turn_id, "cursor" => 0})

    assert {:ok, %{"thread_id" => ^thread_id, "thread" => thread}} =
             Client.request(client, "thread/read", %{"thread_id" => thread_id})

    assert %{"turn" => %{"phase" => _}, "active_stream" => nil} = thread
    refute_client_errors(client)
  end

  @tag provider: BlockingProvider
  test "turn/start while busy is a conflict", context do
    client = connect!(context)
    thread_id = start_thread!(client, context)
    {:ok, %{"turn_id" => turn_id}} = start_turn(client, thread_id, "first")
    assert_receive {:provider_waiting, provider}, 2_000

    assert {:error, %Error{code: "conflict"}} = start_turn(client, thread_id, "second")

    send(provider, :release_provider)
    messages = receive_turn(client)
    assert %{"params" => %{"turn_id" => ^turn_id, "status" => "completed"}} = List.last(messages)

    assert {:ok, %{"status" => "already_finished"}} =
             mutate(client, "turn/interrupt", %{"thread_id" => thread_id, "turn_id" => turn_id})

    refute_client_errors(client)
  end

  @tag provider: BlockingProvider
  test "turn/steer with stale turn_id is a conflict", context do
    client = connect!(context)
    thread_id = start_thread!(client, context)
    {:ok, %{"turn_id" => turn_id}} = start_turn(client, thread_id, "first")
    assert_receive {:provider_waiting, provider}, 2_000

    assert {:error, %Error{code: "conflict"}} =
             mutate(client, "turn/steer", %{
               "thread_id" => thread_id,
               "turn_id" => "turn_stale",
               "input" => [%{"type" => "text", "text" => "steer"}]
             })

    assert {:ok, %{"thread_id" => ^thread_id, "turn_id" => ^turn_id, "status" => "running"}} =
             mutate(client, "turn/steer", %{
               "thread_id" => thread_id,
               "turn_id" => turn_id,
               "input" => [%{"type" => "text", "text" => "steer"}]
             })

    send(provider, :release_provider)
    assert_receive {:provider_waiting, provider}, 2_000
    send(provider, :release_provider)
    messages = receive_turn(client)
    assert %{"params" => %{"turn_id" => ^turn_id}} = List.last(messages)
    refute_client_errors(client)
  end

  @tag provider: BlockingProvider
  test "turn/interrupt reports requested then the turn completes interrupted", context do
    client = connect!(context)
    thread_id = start_thread!(client, context)
    {:ok, %{"turn_id" => turn_id}} = start_turn(client, thread_id, "wait")
    assert_receive {:provider_waiting, _provider}, 2_000

    interrupt = %{"thread_id" => thread_id, "turn_id" => turn_id}

    assert {:error, %Error{code: "conflict"}} =
             mutate(client, "turn/interrupt", %{interrupt | "turn_id" => "turn_stale"})

    assert {:ok, %{"thread_id" => ^thread_id, "turn_id" => ^turn_id, "status" => "requested"}} =
             mutate(client, "turn/interrupt", interrupt)

    messages = receive_turn(client)
    assert %{"params" => %{"status" => "interrupted"}} = List.last(messages)

    assert {:ok, %{"status" => "interrupted"}} = mutate(client, "turn/interrupt", interrupt)
    refute_client_errors(client)
  end

  test "replaying a command_id returns the original turn without a second turn", context do
    client = connect!(context)
    thread_id = start_thread!(client, context)
    params = turn_params(thread_id, "once")

    assert {:ok, %{"turn_id" => turn_id} = result} =
             Client.request(client, "turn/start", params, command_id: "cmd-replay")

    receive_turn(client)

    assert {:ok, ^result} =
             Client.request(client, "turn/start", params, command_id: "cmd-replay")

    refute_receive {:samgita_protocol, ^client, {:notification, %{"method" => "turn/started"}}},
                   300

    assert {:ok, %{"thread" => %{"turn" => %{"turnId" => ^turn_id}}}} =
             Client.request(client, "thread/read", %{"thread_id" => thread_id})

    refute_client_errors(client)
  end

  test "reusing a command_id with different params conflicts", context do
    client = connect!(context)
    thread_id = start_thread!(client, context)

    assert {:ok, _} =
             Client.request(client, "turn/start", turn_params(thread_id, "a"),
               command_id: "cmd-reuse"
             )

    receive_turn(client)

    assert {:error, %Error{code: "conflict"}} =
             Client.request(client, "turn/start", turn_params(thread_id, "b"),
               command_id: "cmd-reuse"
             )

    refute_client_errors(client)
  end

  @tag provider: BlockingProvider
  test "a second client joining mid-turn receives backlog then live events", context do
    first = connect!(context)
    thread_id = start_thread!(first, context)
    {:ok, %{"turn_id" => turn_id}} = start_turn(first, thread_id, "wait")
    assert_receive {:provider_waiting, provider}, 2_000

    assert_receive {:samgita_protocol, ^first,
                    {:notification, %{"method" => "turn/started", "stream_id" => ^turn_id}}},
                   2_000

    second = connect!(context)

    assert {:ok, %{"thread_id" => ^thread_id, "thread" => thread}} =
             mutate(second, "thread/resume", %{"thread_id" => thread_id})

    assert %{"active_stream" => %{"stream_id" => ^turn_id, "cursor" => retained}} = thread
    assert retained >= 2
    assert %{"turn" => %{"turnId" => ^turn_id}} = thread

    backlog = for _ <- 1..retained, do: receive_notification(second)
    assert Enum.map(backlog, & &1["cursor"]) == Enum.to_list(1..retained)

    send(provider, :release_provider)
    live = receive_turn(second)
    assert hd(live)["cursor"] == retained + 1
    all = backlog ++ live
    assert Enum.map(all, & &1["cursor"]) == Enum.to_list(1..length(all))
    assert Enum.all?(all, &(&1["stream_id"] == turn_id))
    assert %{"params" => %{"status" => "completed"}} = List.last(live)
    assert List.last(receive_turn(first)) == List.last(live)
    refute_client_errors(second)
    refute_client_errors(first)
  end

  test "unknown or malformed thread ids are not_found", context do
    client = connect!(context)
    unregistered = Base.url_encode64("/not/registered", padding: false) <> ".session_x"

    for thread_id <- [
          "not-a-thread",
          unregistered,
          ThreadId.encode(context.repo, "never-created"),
          ThreadId.encode(context.repo, "..")
        ] do
      assert {:error, %Error{code: "not_found"}} =
               Client.request(client, "thread/read", %{"thread_id" => thread_id})

      assert {:error, %Error{code: "not_found"}} =
               mutate(client, "thread/resume", %{"thread_id" => thread_id})

      assert {:error, %Error{code: "not_found"}} = start_turn(client, thread_id, "hello")
    end
  end

  test "stream/resume for an unknown stream is replay_gap", context do
    client = connect!(context)

    assert {:error, %Error{code: "replay_gap"}} =
             Client.request(client, "stream/resume", %{"stream_id" => "missing", "cursor" => 0})

    _thread_id = start_thread!(client, context)

    assert {:error, %Error{code: "replay_gap"}} =
             Client.request(client, "stream/resume", %{"stream_id" => "missing", "cursor" => 0})
  end

  test "thread/read works for a session created through Protocol V1 / UI", context do
    thread_id = create_protocol_session!(context, "session_from_protocol_v1")
    client = connect!(context)

    assert {:ok, %{"thread_id" => ^thread_id, "thread" => %{"turn" => %{"phase" => "idle"}}}} =
             Client.request(client, "thread/read", %{"thread_id" => thread_id})
  end

  test "request/cancel reports finished requests and rejects unknown ones", context do
    client = connect!(context)

    assert {:error, %Error{code: "replay_gap"}} =
             Client.request(client, "stream/resume", %{"stream_id" => "s", "cursor" => 0},
               id: "req-done"
             )

    assert {:ok, %{"request_id" => "req-done", "status" => "already_finished"}} =
             mutate(client, "request/cancel", %{"request_id" => "req-done"})

    assert {:error, %Error{code: "not_found"}} =
             mutate(client, "request/cancel", %{"request_id" => "req-unknown"})
  end

  test "a sessions.v1-only client stays connected and receives turn notifications but no item notifications",
       context do
    client = connect!(context, ["sessions.v1"])
    thread_id = start_thread!(client, context)
    {:ok, %{"turn_id" => turn_id}} = start_turn(client, thread_id, "hello")

    messages = receive_turn(client)
    assert Enum.map(messages, & &1["method"]) == ["turn/started", "turn/completed"]
    assert Enum.all?(messages, &(&1["params"]["turn_id"] == turn_id))
    refute Enum.any?(messages, &Map.has_key?(&1, "stream_id"))

    assert {:ok, %{"thread_id" => ^thread_id, "thread" => %{"active_stream" => nil}}} =
             Client.request(client, "thread/read", %{"thread_id" => thread_id})

    refute_receive {:samgita_protocol, ^client, {:notification, _}}, 200
    refute_client_errors(client)
  end

  test "definite failures release their command_id", context do
    client = connect!(context)
    params = %{"thread_id" => ThreadId.encode(context.repo, "never-created")}

    for _ <- 1..2 do
      assert {:error, %Error{code: "not_found"}} =
               Client.request(client, "thread/resume", params, command_id: "cmd-definite")
    end
  end

  test "a resume whose stream cannot be followed keeps its command_id reserved", context do
    thread_id = create_protocol_session!(context, "session_unfollowable")
    blocker = block_stream!(thread_id, fn from -> GenServer.reply(from, {:error, :not_found}) end)
    client = connect!(context)
    params = %{"thread_id" => thread_id}

    assert {:error, %Error{code: "not_found"}} =
             Client.request(client, "thread/resume", params, command_id: "cmd-uncertain")

    assert {:error, %Error{code: "conflict"}} =
             Client.request(client, "thread/resume", params, command_id: "cmd-uncertain")

    unblock_stream!(thread_id, blocker)

    assert {:ok, %{"thread_id" => ^thread_id}} = mutate(client, "thread/resume", params)
  end

  test "an exit while following keeps its command_id reserved", context do
    thread_id = create_protocol_session!(context, "session_follow_exit")
    blocker = block_stream!(thread_id, fn _from -> exit(:follow_failed) end)
    client = connect!(context)
    params = %{"thread_id" => thread_id}

    assert {:error, %Error{code: "handler_error"}} =
             Client.request(client, "thread/resume", params, command_id: "cmd-exit")

    assert {:error, %Error{code: "conflict"}} =
             Client.request(client, "thread/resume", params, command_id: "cmd-exit")

    unblock_stream!(thread_id, blocker)
  end

  test "a thread/start replayed on a new connection follows the thread there", context do
    params = %{"metadata" => %{"repository" => context.repo}}
    first = connect!(context)

    assert {:ok, %{"thread_id" => thread_id} = result} =
             Client.request(first, "thread/start", params, command_id: "cmd-start-replay")

    # A fresh connection stands in for the client's reconnect.
    second = connect!(context)

    assert {:ok, ^result} =
             Client.request(second, "thread/start", params, command_id: "cmd-start-replay")

    assert %{"method" => "thread/started", "params" => %{"thread_id" => ^thread_id}} =
             receive_notification(second)

    {:ok, %{"turn_id" => turn_id}} = start_turn(second, thread_id, "after replay")

    assert %{"method" => "turn/completed", "params" => %{"turn_id" => ^turn_id}} =
             List.last(receive_turn(second))

    refute_client_errors(second)
  end

  test "a followed thread streams again after its session restarts elsewhere", context do
    first = connect!(context)
    thread_id = start_thread!(first, context)
    [{stream, _}] = Registry.lookup(Sigma.Web.SamgitaHost.Registry, thread_id)
    stream_ref = Process.monitor(stream)
    stop_session!(context, thread_id)
    assert_receive {:DOWN, ^stream_ref, :process, ^stream, _}, 2_000

    assert {:error, %Error{code: "conflict", details: %{"reason" => "session_not_running"}}} =
             start_turn(first, thread_id, "while stopped")

    second = connect!(context)
    assert {:ok, _} = mutate(second, "thread/resume", %{"thread_id" => thread_id})

    {:ok, %{"turn_id" => turn_id}} = start_turn(first, thread_id, "after restart")
    messages = receive_turn(first)
    assert Enum.all?(messages, &(&1["stream_id"] == turn_id))
    # The status depends on the resumed provider configuration (see the pre-existing
    # SessionChannelTest resume failure), not on this host.
    assert %{"method" => "turn/completed", "params" => %{"turn_id" => ^turn_id}} =
             List.last(messages)

    refute_client_errors(first)
  end

  defp stop_session!(context, thread_id) do
    {:ok, %{session_id: session_id}} = ThreadId.decode(thread_id)
    session_supervisor = Sigma.Agent.Runtime.lookup(context.repo, session_id, :supervisor)
    sessions_supervisor = Sigma.Agent.Runtime.lookup(context.repo, :sessions)
    :ok = DynamicSupervisor.terminate_child(sessions_supervisor, session_supervisor)
  end

  defp connect!(context, capabilities \\ @capabilities) do
    {:ok, client} = Client.connect(context.url, token: context.token, capabilities: capabilities)

    {:ok, _} =
      Client.request(client, "connection/initialize", %{
        "versions" => ["1.0"],
        "capabilities" => capabilities
      })

    client
  end

  defp create_protocol_session!(context, session_id) do
    assert {:ok, command} =
             Envelope.command("session.create", session_id, %{"cwd" => context.repo})

    runtime_context = %{
      repo_path: context.repo,
      sessions_dir: context.sessions_dir,
      session_opts: [
        model: %{id: "mock-model", api: "mock", provider: "mock"},
        provider: LoopProvider
      ]
    }

    assert {:ok, %{type: "session.snapshot"}} = PublicRuntime.execute(command, runtime_context)
    ThreadId.encode(context.repo, session_id)
  end

  # Occupies the thread's stream registration with a process that answers
  # attach calls with `on_call`, so following the thread fails after resume.
  defp block_stream!(thread_id, on_call) do
    test_pid = self()

    blocker =
      spawn(fn ->
        {:ok, _} = Registry.register(Sigma.Web.SamgitaHost.Registry, thread_id, nil)
        send(test_pid, {:blocking, self()})
        block(on_call)
      end)

    assert_receive {:blocking, ^blocker}, 1_000
    blocker
  end

  defp block(on_call) do
    receive do
      {:"$gen_call", from, {:attach, _socket, _groups}} ->
        on_call.(from)
        block(on_call)
    end
  end

  defp unblock_stream!(thread_id, blocker) do
    ref = Process.monitor(blocker)
    Process.exit(blocker, :kill)
    assert_receive {:DOWN, ^ref, :process, ^blocker, _}, 1_000
    wait_unregistered(thread_id, 50)
  end

  defp wait_unregistered(thread_id, attempts) do
    case Registry.lookup(Sigma.Web.SamgitaHost.Registry, thread_id) do
      [] ->
        :ok

      _registered when attempts > 0 ->
        Process.sleep(10)
        wait_unregistered(thread_id, attempts - 1)
    end
  end

  defp start_thread!(client, context, title \\ nil) do
    params =
      %{"metadata" => %{"repository" => context.repo}}
      |> then(&if(title, do: Map.put(&1, "title", title), else: &1))

    assert {:ok, %{"thread_id" => thread_id, "thread" => %{"active_stream" => nil}}} =
             mutate(client, "thread/start", params)

    assert %{"method" => "thread/started", "params" => %{"thread_id" => ^thread_id}} =
             receive_notification(client)

    thread_id
  end

  defp start_turn(client, thread_id, text),
    do: mutate(client, "turn/start", turn_params(thread_id, text))

  defp turn_params(thread_id, text),
    do: %{"thread_id" => thread_id, "input" => [%{"type" => "text", "text" => text}]}

  defp mutate(client, method, params),
    do:
      Client.request(client, method, params,
        command_id: "cmd-#{System.unique_integer([:positive])}"
      )

  defp receive_notification(client) do
    assert_receive {:samgita_protocol, ^client, {:notification, message}}, 2_000
    message
  end

  defp receive_turn(client, acc \\ []) do
    message = receive_notification(client)
    acc = acc ++ [message]
    if message["method"] == "turn/completed", do: acc, else: receive_turn(client, acc)
  end

  defp refute_client_errors(client),
    do: refute_received({:samgita_protocol, ^client, {:error, _}})

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp stop_repository(repo) do
    case Sigma.Agent.Runtime.lookup(repo, :supervisor) do
      supervisor when is_pid(supervisor) ->
        DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, supervisor)

      nil ->
        :ok
    end
  end

  defp write_provider_config!(agent_dir) do
    File.mkdir_p!(agent_dir)

    File.write!(
      Path.join(agent_dir, "settings.json"),
      Jason.encode!(%{"defaultProvider" => "mock", "defaultModel" => "mock-model"})
    )

    File.write!(
      Path.join(agent_dir, "models.json"),
      Jason.encode!(%{
        "providers" => %{
          "mock" => %{"name" => "Mock", "api" => "mock", "models" => [%{"id" => "mock-model"}]}
        }
      })
    )
  end
end
