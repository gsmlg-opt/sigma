defmodule Sigma.Web.SessionChannelTest do
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest

  alias Sigma.Agent.PublicRuntime
  alias Sigma.Protocol.{Codec, Envelope}
  alias Sigma.Session.{ConfigManager, RepoManager}

  @endpoint Sigma.Web.Endpoint

  defmodule ChannelProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params) do
      response = Keyword.get(params.options, :response, "channel response")
      message = message(response)
      [{:start, %{message | content: []}}, {:text_delta, 0, response, message}, {:done, :stop, message}]
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

  defmodule BlockingChannelProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params) do
      test_pid = Keyword.fetch!(params.options, :test_pid)
      cancellation_ref = Keyword.fetch!(params.options, :cancellation_ref)
      send(test_pid, {:channel_provider_waiting, self()})

      receive do
        :release_channel_provider ->
          message = ChannelProvider.message("released")
          [{:start, %{message | content: []}}, {:done, :stop, message}]

        {:cancel, ^cancellation_ref} ->
          [{:provider_error, Sigma.Ai.ProviderError.from_reason(:cancelled)}]
      end
    end
  end

  setup context do
    root =
      Path.join(
        System.tmp_dir!(),
        "sigma-channel-#{context.test}-#{System.unique_integer([:positive])}"
      )

    repo = Path.join(root, "repo")
    agent_dir = Path.join(root, "agent")
    File.mkdir_p!(repo)
    previous_agent_dir = Application.get_env(:sigma_session, :agent_dir)
    previous_protocol_token = Application.get_env(:sigma_web, :protocol_token)
    previous_mock_provider = Application.get_env(:sigma_web, :mock_provider_module)
    Application.put_env(:sigma_session, :agent_dir, agent_dir)
    protocol_token = String.duplicate("t", 32)
    Application.put_env(:sigma_web, :protocol_token, protocol_token)
    Application.put_env(:sigma_web, :mock_provider_module, ChannelProvider)
    write_provider_config!(agent_dir)
    {:ok, _repo} = RepoManager.add_repo(repo, name: "Channel Repo")
    sessions_dir = ConfigManager.ensure_sessions_dir(repo)

    on_exit(fn ->
      stop_repository(repo)

      if previous_agent_dir do
        Application.put_env(:sigma_session, :agent_dir, previous_agent_dir)
      else
        Application.delete_env(:sigma_session, :agent_dir)
      end


      if previous_protocol_token do
        Application.put_env(:sigma_web, :protocol_token, previous_protocol_token)
      else
        Application.delete_env(:sigma_web, :protocol_token)
      end


      if previous_mock_provider do
        Application.put_env(:sigma_web, :mock_provider_module, previous_mock_provider)
      else
        Application.delete_env(:sigma_web, :mock_provider_module)
      end

      File.rm_rf!(root)
    end)

    {:ok,
     repo: repo,
     sessions_dir: sessions_dir,
     encoded_repo: Base.url_encode64(repo, padding: false),
     protocol_token: protocol_token}
  end

  test "WebSocket attaches, streams a turn, and reconnects to a current snapshot", context do
    session_id = "websocket-stream"
    create_session!(context, session_id, provider: ChannelProvider)
    socket = join_session!(context, session_id)

    push_command(socket, command!("subscription.attach", session_id))
    assert %{payload: %{"attached" => true}} = receive_type("session.snapshot")

    push_command(socket, command!("prompt.submit", session_id, %{"content" => "hello"}))
    assert %{payload: %{"status" => "accepted"}} = receive_type("prompt.admitted")
    events = receive_until("turn.completed", [])
    assert Enum.any?(events, &(&1.type == "message.delta"))

    Process.unlink(socket.channel_pid)
    leave_ref = leave(socket)
    assert_reply leave_ref, :ok

    reconnected = join_session!(context, session_id)
    push_command(reconnected, command!("session.status", session_id))

    assert %{type: "session.snapshot", payload: %{"turn" => %{"phase" => "completed"}}} =
             receive_type("session.snapshot")
  end

  test "WebSocket disconnect does not cancel a turn and a reconnected client can cancel explicitly", context do
    session_id = "websocket-cancel"

    create_session!(context, session_id,
      provider: BlockingChannelProvider,
      options: [test_pid: self()]
    )

    socket = join_session!(context, session_id)
    push_command(socket, command!("subscription.attach", session_id))
    assert %{payload: %{"attached" => true}} = receive_type("session.snapshot")
    push_command(socket, command!("prompt.submit", session_id, %{"content" => "wait"}))
    assert_receive {:channel_provider_waiting, _provider}, 1_000

    Process.unlink(socket.channel_pid)
    leave_ref = leave(socket)
    assert_reply leave_ref, :ok
    assert %{phase: :streaming_provider} =
             Sigma.Agent.status(Sigma.Agent.Runtime.lookup(context.repo, session_id, :agent))

    reconnected = join_session!(context, session_id)
    push_command(reconnected, command!("subscription.attach", session_id))
    assert %{payload: %{"attached" => true}} = receive_type("session.snapshot")
    push_command(reconnected, command!("turn.cancel", session_id))

    assert %{
             type: "session.snapshot",
             payload: %{"cancellation" => %{"status" => "cancelling"}}
           } = receive_type("session.snapshot")

    assert %{type: "turn.cancelled"} = receive_type("turn.cancelled")
    refute_push "event", _payload, 50
  end

  test "WebSocket rejects missing or incorrect capability tokens", context do
    assert :error = connect(Sigma.Web.AgentSocket, %{"repository" => context.encoded_repo})

    assert :error =
             connect(Sigma.Web.AgentSocket, %{
               "repository" => context.encoded_repo,
               "token" => String.duplicate("x", 32)
             })
  end

  test "WebSocket resumes a stopped session from saved provider configuration", context do
    session_id = "websocket-stopped-resume"
    create_session!(context, session_id, provider: ChannelProvider)
    session_supervisor = Sigma.Agent.Runtime.lookup(context.repo, session_id, :supervisor)
    sessions_supervisor = Sigma.Agent.Runtime.lookup(context.repo, :sessions)
    :ok = DynamicSupervisor.terminate_child(sessions_supervisor, session_supervisor)
    assert nil == Sigma.Agent.Runtime.lookup(context.repo, session_id, :agent)

    socket = join_session!(context, session_id)
    push_command(socket, command!("session.resume", session_id))
    assert %{type: "session.snapshot"} = receive_type("session.snapshot")
    assert is_pid(Sigma.Agent.Runtime.lookup(context.repo, session_id, :agent))

    push_command(socket, command!("subscription.attach", session_id))
    assert %{payload: %{"attached" => true}} = receive_type("session.snapshot")
    push_command(socket, command!("prompt.submit", session_id, %{"content" => "resumed"}))
    assert %{payload: %{"status" => "accepted"}} = receive_type("prompt.admitted")
    assert List.last(receive_until("turn.completed", [])).type == "turn.completed"
  end

  defp create_session!(context, session_id, opts) do
    runtime_context = %{
      repo_path: context.repo,
      sessions_dir: context.sessions_dir,
      session_opts:
        Keyword.merge(
          [
            model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
            provider: ChannelProvider
          ],
          opts
        )
    }

    assert {:ok, command} =
             Envelope.command("session.create", session_id, %{
               "cwd" => context.repo,
               "metadata" => %{"cwd" => context.repo}
             })

    assert {:ok, %{type: "session.snapshot"}} = PublicRuntime.execute(command, runtime_context)
  end

  defp join_session!(context, session_id) do
    assert {:ok, socket} =
             connect(Sigma.Web.AgentSocket, %{
               "repository" => context.encoded_repo,
               "token" => context.protocol_token
             })

    assert {:ok, _reply, socket} =
             subscribe_and_join(socket, Sigma.Web.SessionChannel, "session:#{session_id}")

    socket
  end

  defp push_command(socket, command) do
    assert {:ok, encoded} = Codec.encode(command)
    push(socket, "command", %{"data" => encoded})
  end

  defp command!(type, session_id, payload \\ %{}) do
    {:ok, command} = Envelope.command(type, session_id, payload)
    command
  end

  defp receive_type(type) do
    assert_push "event", %{"data" => encoded}, 1_000
    assert {:ok, event} = Codec.decode(encoded)
    if event.type == type, do: event, else: receive_type(type)
  end

  defp receive_until(terminal_type, acc) do
    event = receive_type_any()
    events = acc ++ [event]
    if event.type == terminal_type, do: events, else: receive_until(terminal_type, events)
  end

  defp receive_type_any do
    assert_push "event", %{"data" => encoded}, 1_000
    assert {:ok, event} = Codec.decode(encoded)
    event
  end

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
          "mock" => %{
            "name" => "Mock",
            "api" => "mock",
            "models" => [%{"id" => "mock-model"}]
          }
        }
      })
    )
  end
end
