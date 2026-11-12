defmodule Sigma.Web.SamgitaHost.ThreadStreamTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.PublicRuntime
  alias Sigma.Protocol.Envelope
  alias Sigma.Session.{ConfigManager, RepoManager}
  alias Sigma.Web.ProtocolContext
  alias Sigma.Web.SamgitaHost.{ThreadId, ThreadStream}

  defmodule StreamProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(_params) do
      message = message("stream response")

      [
        {:start, %{message | content: []}},
        {:text_delta, 0, "stream response", message},
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

  defmodule BlockingStreamProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params) do
      test_pid = Keyword.fetch!(params.options, :test_pid)
      cancellation_ref = Keyword.fetch!(params.options, :cancellation_ref)
      send(test_pid, {:stream_provider_waiting, self()})

      receive do
        :release_stream_provider ->
          message = StreamProvider.message("released")

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

  setup context do
    root =
      Path.join(
        System.tmp_dir!(),
        "sigma-thread-stream-#{context.test}-#{System.unique_integer([:positive])}"
      )

    repo = Path.join(root, "repo")
    agent_dir = Path.join(root, "agent")
    File.mkdir_p!(repo)
    previous_agent_dir = Application.get_env(:sigma_session, :agent_dir)
    previous_mock_provider = Application.get_env(:sigma_web, :mock_provider_module)
    Application.put_env(:sigma_session, :agent_dir, agent_dir)
    Application.put_env(:sigma_web, :mock_provider_module, StreamProvider)
    write_provider_config!(agent_dir)
    {:ok, _repo} = RepoManager.add_repo(repo, name: "Thread Stream Repo")
    sessions_dir = ConfigManager.ensure_sessions_dir(repo)

    on_exit(fn ->
      stop_repository(repo)

      if previous_agent_dir do
        Application.put_env(:sigma_session, :agent_dir, previous_agent_dir)
      else
        Application.delete_env(:sigma_session, :agent_dir)
      end

      if previous_mock_provider do
        Application.put_env(:sigma_web, :mock_provider_module, previous_mock_provider)
      else
        Application.delete_env(:sigma_web, :mock_provider_module)
      end

      File.rm_rf!(root)
    end)

    {:ok, repo: Path.expand(repo), sessions_dir: sessions_dir}
  end

  test "a turn is delivered in cursor order to an attached socket", context do
    thread_id = create_thread!(context, "stream-order", provider: StreamProvider)
    assert {:ok, _pid} = ThreadStream.ensure(thread_id)
    assert {:ok, %{active_stream: nil}} = ThreadStream.attach(thread_id, self())

    submit!(context, "stream-order", "hello")
    messages = receive_turn()

    assert [%{"cursor" => 1} | _] = messages
    assert Enum.any?(messages, &(&1["method"] == "turn/started"))

    assert %{"method" => "turn/completed", "params" => %{"status" => "completed"}} =
             List.last(messages)

    assert Enum.map(messages, & &1["cursor"]) == Enum.to_list(1..length(messages))
    turn_id = hd(messages)["params"]["turn_id"]
    assert Enum.all?(messages, &(&1["stream_id"] == turn_id))
    assert Enum.any?(messages, &(&1["method"] == "item/delta"))

    assert {:ok, replayed} = ThreadStream.resume(thread_id, turn_id, 0)
    assert replayed == messages
  end

  test "a late attach receives the retained backlog before live events", context do
    session_id = "stream-late"

    thread_id =
      create_thread!(context, session_id,
        provider: BlockingStreamProvider,
        options: [test_pid: self()]
      )

    assert {:ok, _pid} = ThreadStream.ensure(thread_id)
    early = relay_socket(:early)
    assert {:ok, %{active_stream: nil}} = ThreadStream.attach(thread_id, early)

    submit!(context, session_id, "wait")
    assert_receive {:stream_provider_waiting, provider}, 1_000
    assert_receive {:early, %{"method" => "turn/started", "stream_id" => turn_id}}, 1_000

    assert {:ok, %{active_stream: %{"stream_id" => ^turn_id, "cursor" => retained}}} =
             ThreadStream.attach(thread_id, self())

    assert retained >= 1
    backlog = for _ <- 1..retained, do: receive_notification()
    assert Enum.map(backlog, & &1["cursor"]) == Enum.to_list(1..retained)
    assert Enum.any?(backlog, &(&1["method"] == "turn/started"))

    send(provider, :release_stream_provider)
    live = receive_turn()
    assert hd(live)["cursor"] == retained + 1

    assert Enum.map(live, & &1["cursor"]) ==
             Enum.to_list((retained + 1)..(retained + length(live)))

    assert Enum.all?(live, &(&1["stream_id"] == turn_id))
    assert %{"method" => "turn/completed"} = List.last(live)
  end

  test "an attach that lost the active turn's first cursor starts at the next turn", context do
    session_id = "stream-gap"

    thread_id =
      create_thread!(context, session_id,
        provider: BlockingStreamProvider,
        options: [test_pid: self()]
      )

    assert {:ok, _pid} = ThreadStream.ensure(thread_id, replay_limit: 1)
    early = relay_socket(:early)
    assert {:ok, _} = ThreadStream.attach(thread_id, early)

    submit!(context, session_id, "first")
    assert_receive {:stream_provider_waiting, provider}, 1_000
    assert_receive {:early, %{"method" => "turn/started"}}, 1_000
    assert_receive {:early, %{"cursor" => 2, "stream_id" => first_turn}}, 1_000

    assert {:ok, %{active_stream: nil}} = ThreadStream.attach(thread_id, self())
    send(provider, :release_stream_provider)
    assert_receive {:early, %{"method" => "turn/completed", "stream_id" => ^first_turn}}, 1_000
    refute_received {:protocol_notification, _}

    submit!(context, session_id, "second")
    assert_receive {:stream_provider_waiting, provider}, 1_000
    send(provider, :release_stream_provider)
    messages = receive_turn()

    assert [%{"cursor" => 1, "stream_id" => second_turn} | _] =
             messages

    refute second_turn == first_turn
  end

  test "two sockets both receive; one exiting does not stop the stream", context do
    session_id = "stream-two"
    thread_id = create_thread!(context, session_id, provider: StreamProvider)
    assert {:ok, stream} = ThreadStream.ensure(thread_id)
    other = relay_socket(:other)
    assert {:ok, _} = ThreadStream.attach(thread_id, other)
    assert {:ok, _} = ThreadStream.attach(thread_id, self())

    submit!(context, session_id, "first")
    mine = receive_turn()
    assert_receive {:other, %{"method" => "turn/completed"} = other_last}, 1_000
    assert other_last == List.last(mine)

    other_ref = Process.monitor(other)
    Process.exit(other, :kill)
    assert_receive {:DOWN, ^other_ref, :process, ^other, :killed}, 1_000

    submit!(context, session_id, "second")
    second = receive_turn()
    assert [%{"cursor" => 1} | _] = second
    refute hd(second)["stream_id"] == hd(mine)["stream_id"]
    assert Process.alive?(stream)
    assert {:ok, ^stream} = ThreadStream.ensure(thread_id)
  end

  test "resume returns replay_gap for unknown streams", context do
    thread_id = create_thread!(context, "stream-resume", provider: StreamProvider)

    assert {:error, %SamgitaProtocol.Error{code: "replay_gap"}} =
             ThreadStream.resume(thread_id, "missing-turn", 0)

    assert {:ok, _pid} = ThreadStream.ensure(thread_id)

    assert {:error, %SamgitaProtocol.Error{code: "replay_gap"}} =
             ThreadStream.resume(thread_id, "missing-turn", 0)
  end

  test "ensure rejects unknown threads and sessions that are not running", context do
    assert {:error, :not_found} = ThreadStream.ensure("not-a-thread")

    assert {:error, :not_found} =
             ThreadStream.ensure(ThreadId.encode(context.repo, "never-created"))
  end

  test "an idle stream with no sockets and no running turn exits", context do
    thread_id = create_thread!(context, "stream-idle", provider: StreamProvider)
    assert {:ok, pid} = ThreadStream.ensure(thread_id, idle_timeout: 0)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 1_000
    assert reason in [:normal, :noproc]
  end

  test "the stream stops when the session agent exits and a resumed session gets a fresh one",
       context do
    session_id = "stream-agent-exit"
    thread_id = create_thread!(context, session_id, provider: StreamProvider)
    assert {:ok, old} = ThreadStream.ensure(thread_id)
    ref = Process.monitor(old)

    session_supervisor = Sigma.Agent.Runtime.lookup(context.repo, session_id, :supervisor)
    sessions_supervisor = Sigma.Agent.Runtime.lookup(context.repo, :sessions)
    :ok = DynamicSupervisor.terminate_child(sessions_supervisor, session_supervisor)
    assert_receive {:DOWN, ^ref, :process, ^old, :normal}, 1_000

    assert {:ok, command} = Envelope.command("session.resume", session_id, %{})

    scope = %{
      workdir: context.repo,
      sessions_dir: context.sessions_dir,
      session_id: session_id,
      subscriber: self()
    }

    assert {:ok, %{type: "session.snapshot"}} =
             PublicRuntime.execute(command, ProtocolContext.build(scope, []))

    assert {:ok, fresh} = ThreadStream.ensure(thread_id)
    refute fresh == old
    assert {:ok, _} = ThreadStream.attach(thread_id, self())
    submit!(context, session_id, "after resume")
    # The fresh stream delivers the next turn; its outcome depends on the resumed provider
    # configuration (see the pre-existing SessionChannelTest resume failure), not on the stream.
    messages = receive_turn()
    assert Enum.map(messages, & &1["cursor"]) == Enum.to_list(1..length(messages))
  end

  @tag :capture_log
  test "a subscription cursor gap poisons the active turn", context do
    assert_loss_poisons_turn(context, "stream-gap-cursor", fn state, session_id, turn_id ->
      Envelope.event(
        "message.delta",
        session_id,
        %{
          "cursor" => state.next_cursor + 3,
          "deltaKind" => "text",
          "messageId" => "msg_crafted",
          "delta" => "x"
        },
        turn_id: turn_id
      )
    end)
  end

  @tag :capture_log
  test "a resync marker poisons the active turn", context do
    assert_loss_poisons_turn(context, "stream-resync", fn state, session_id, turn_id ->
      Envelope.event(
        "session.error",
        session_id,
        %{"cursor" => state.next_cursor, "snapshotRequired" => true},
        turn_id: turn_id,
        error: Sigma.Protocol.Error.new("resync_required", "Subscription state is incomplete.")
      )
    end)
  end

  test "events for an already terminated turn are dropped", context do
    session_id = "stream-terminated"
    thread_id = create_thread!(context, session_id, provider: StreamProvider)
    assert {:ok, pid} = ThreadStream.ensure(thread_id)
    assert {:ok, _} = ThreadStream.attach(thread_id, self())
    submit!(context, session_id, "done")
    messages = receive_turn()
    turn_id = hd(messages)["stream_id"]

    state = :sys.get_state(pid)

    {:ok, late} =
      Envelope.event(
        "message.delta",
        session_id,
        %{
          "cursor" => state.next_cursor,
          "deltaKind" => "text",
          "messageId" => "msg_late",
          "delta" => "late"
        },
        turn_id: turn_id
      )

    send(pid, {:sigma_protocol, state.subscription_id, late})
    assert {:ok, ^messages} = ThreadStream.resume(thread_id, turn_id, 0)
    assert %{active: nil} = :sys.get_state(pid)
    refute_received {:protocol_notification, _}
  end

  defp assert_loss_poisons_turn(context, session_id, craft) do
    thread_id =
      create_thread!(context, session_id,
        provider: BlockingStreamProvider,
        options: [test_pid: self()]
      )

    raw_attach!(context, session_id)
    assert {:ok, pid} = ThreadStream.ensure(thread_id)
    early = relay_socket(:early)
    assert {:ok, _} = ThreadStream.attach(thread_id, early)

    submit!(context, session_id, "first")
    assert_receive {:stream_provider_waiting, provider}, 1_000
    assert_receive {:early, %{"method" => "turn/started", "stream_id" => first_turn}}, 1_000

    state = :sys.get_state(pid)
    delivered = state.logs[first_turn].next_cursor - 1
    {:ok, event} = craft.(state, session_id, first_turn)
    send(pid, {:sigma_protocol, state.subscription_id, event})

    assert {:error, %SamgitaProtocol.Error{code: "replay_gap"}} =
             ThreadStream.resume(thread_id, first_turn, 0)

    assert {:ok, %{active_stream: nil}} = ThreadStream.attach(thread_id, self())

    send(provider, :release_stream_provider)
    assert_receive {:sigma_protocol, _, %Envelope{type: "turn.completed"}}, 1_000

    submit!(context, session_id, "second")
    assert_receive {:stream_provider_waiting, provider}, 1_000
    send(provider, :release_stream_provider)
    messages = receive_turn()
    assert [%{"cursor" => 1, "stream_id" => second_turn} | _] = messages
    refute second_turn == first_turn
    assert_receive {:early, %{"method" => "turn/completed", "stream_id" => ^second_turn}}, 1_000

    refute_received {:protocol_notification, %{"stream_id" => ^first_turn}}
    early_first = collect_early(first_turn, [])
    assert Enum.all?(early_first, &(&1["cursor"] <= delivered))
    refute Enum.any?(early_first, &(&1["method"] == "turn/completed"))
  end

  defp collect_early(turn_id, acc) do
    receive do
      {:early, %{"stream_id" => ^turn_id} = message} -> collect_early(turn_id, [message | acc])
    after
      0 -> acc
    end
  end

  defp raw_attach!(context, session_id) do
    assert {:ok, command} = Envelope.command("subscription.attach", session_id, %{})

    assert {:ok, %{payload: %{"attached" => true}}} =
             PublicRuntime.execute(command, runtime_context(context, subscriber: self()))
  end

  defp create_thread!(context, session_id, opts) do
    assert {:ok, command} =
             Envelope.command("session.create", session_id, %{
               "cwd" => context.repo,
               "metadata" => %{"cwd" => context.repo}
             })

    runtime_context =
      runtime_context(context,
        session_opts:
          Keyword.merge(
            [model: %{id: "mock-model", api: "mock", provider: "mock"}, provider: StreamProvider],
            opts
          )
      )

    assert {:ok, %{type: "session.snapshot"}} = PublicRuntime.execute(command, runtime_context)
    ThreadId.encode(context.repo, session_id)
  end

  defp submit!(context, session_id, content) do
    assert {:ok, command} =
             Envelope.command("prompt.submit", session_id, %{"content" => content})

    assert {:ok, %{type: "prompt.admitted"}} =
             PublicRuntime.execute(command, runtime_context(context, []))
  end

  defp runtime_context(context, extra) do
    Map.merge(%{repo_path: context.repo, sessions_dir: context.sessions_dir}, Map.new(extra))
  end

  defp relay_socket(tag) do
    test_pid = self()

    spawn(fn -> relay(test_pid, tag) end)
  end

  defp relay(test_pid, tag) do
    receive do
      {:protocol_notification, message} ->
        send(test_pid, {tag, message})
        relay(test_pid, tag)
    end
  end

  defp receive_notification do
    assert_receive {:protocol_notification, message}, 1_000
    message
  end

  defp receive_turn(acc \\ []) do
    message = receive_notification()
    acc = acc ++ [message]
    if message["method"] == "turn/completed", do: acc, else: receive_turn(acc)
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
