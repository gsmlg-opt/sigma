defmodule Sigma.Web.SessionCancelFunctionalTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest, only: [get: 2]
  import Phoenix.LiveViewTest

  alias Sigma.Agent.Message
  alias Sigma.Agent.{Runtime, Subagents}
  alias Sigma.Agent.Backplane.GoalStore
  alias Sigma.Session.{ConfigManager, Log, RepoManager, Writer}
  alias Sigma.Web.SessionLive

  @endpoint Sigma.Web.Endpoint
  @moduletag :tmp_dir
  @moduletag :detached_cancellation
  @session "detached-cancel-ui"

  defmodule Provider do
    @behaviour Sigma.Ai.Provider
    def output_token_limit(_model, _options), do: 2_000

    def stream(params) do
      send(params.options[:test_pid], {:cancel_ui_provider, self(), params})

      receive do
        {:response, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            content: content,
            stop_reason: reason,
            usage: %{input: 7, output: 3, total_tokens: 10},
            model: "cancel-ui",
            provider: "cancel-ui",
            api: "openai-responses",
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, reason, message}]
      end
    end
  end

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "root.jsonl")

    assert {:ok, handle} =
             Runtime.get_session(dir, @session,
               cwd: dir,
               transcript_path: path,
               native_tools: true,
               native_memory_root: Path.join(dir, "memories"),
               provider: Provider,
               model: %{id: "cancel-ui", provider: "cancel-ui", api: "openai-responses"},
               tools: [],
               hook_specs: [],
               options: [test_pid: self()]
             )

    on_exit(fn ->
      if pid = Runtime.lookup(dir, :supervisor),
        do: DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)

      GoalStore.retire(Path.join(path <> ".subagents", "goal"))
    end)

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        agent: handle.agent,
        workdir: dir,
        sessions_dir: dir,
        session_id: @session,
        runtime_status: :completed,
        turn_in_flight: false
      }
    }

    %{
      dir: dir,
      path: path,
      agent: handle.agent,
      host: Runtime.lookup(dir, @session, :subagents),
      socket: socket
    }
  end

  test "Stop subagents keeps the completed root phase after confirmed execution closure", c do
    child = detached_child!(c)
    ref = Process.monitor(child.pid)
    assert {:noreply, socket} = SessionLive.handle_event("cancel_turn", %{}, c.socket)
    assert socket.assigns.runtime_status == :completed
    refute socket.assigns.turn_in_flight
    assert socket.assigns.flash == %{}
    assert_receive {:DOWN, ^ref, :process, _, _}, 8_000

    assert {:ok, %{execution_closed: true, generation_closed: false}} =
             Subagents.archive_sources(c.host)

    assert {:ok, %{status: :confirmed}} = Sigma.Agent.retire_host(c.agent)
    refute_receive {:cancel_ui_provider, _, _}, 0
  end

  test "Stop subagents displays a failed retirement without claiming cancellation is pending",
       c do
    child = detached_child!(c)

    receipt =
      Path.join([
        c.path <> ".subagents",
        child.params.session_id,
        "runtime",
        "host-retirement.etf"
      ])

    File.rename!(receipt, receipt <> ".saved")
    File.mkdir!(receipt)

    try do
      assert {:noreply, socket} = SessionLive.handle_event("cancel_turn", %{}, c.socket)
      assert socket.assigns.runtime_status == :completed
      refute socket.assigns.turn_in_flight
      assert socket.assigns.flash["error"] == "The session command failed."

      assert {:ok, %{execution_closed: false, execution_result: {:error, actual}}} =
               Subagents.archive_sources(c.host)

      assert inspect(actual) =~ "eisdir"
    after
      File.rmdir!(receipt)
      File.rename!(receipt <> ".saved", receipt)
    end

    assert {:ok, %{status: :confirmed}} = Sigma.Agent.retire_host(c.agent)
    refute_receive {:cancel_ui_provider, _, _}, 0
  end

  test "reload retains cancelled tool-only history during a later active turn", c do
    previous_agent_dir = Application.get_env(:sigma_session, :agent_dir)
    Application.put_env(:sigma_session, :agent_dir, Path.join(c.dir, "display-agent"))

    on_exit(fn ->
      if previous_agent_dir,
        do: Application.put_env(:sigma_session, :agent_dir, previous_agent_dir),
        else: Application.delete_env(:sigma_session, :agent_dir)
    end)

    session_id = "cancelled-display"
    path = Path.join(ConfigManager.ensure_sessions_dir(c.dir), session_id <> ".jsonl")
    assert {:ok, _} = RepoManager.add_repo(c.dir, name: "Cancelled display")
    assert :ok = Log.persist_event(path, {:agent_start, c.dir})
    assert :ok = Log.persist_event(path, {:message_end, Message.user("older-user", "Earlier")})

    assert :ok =
             Log.persist_event(
               path,
               {:message_end, Message.assistant("older-assistant", %{content: "Old"})}
             )

    assert :ok = Log.persist_event(path, {:message_end, Message.user("kept-user", "Wait")})
    assert {:ok, %{active_leaf_id: first_kept}} = Log.snapshot(path)

    for event <- [
          {:metrics, :turn_started, %{session_id: session_id, turn_id: "cancelled-turn"}},
          {:message_end,
           %Message{
             id: "cancelled-assistant",
             role: :assistant,
             metadata: %{turn_id: "cancelled-turn"},
             content: [
               %{
                 type: :tool_call,
                 id: "cancelled-clock",
                 name: "clock::sleep",
                 arguments: %{"duration_ms" => 60_000}
               }
             ]
           }},
          {:metrics, :turn_finished,
           %{session_id: session_id, turn_id: "cancelled-turn", revision: 1, status: :cancelled}},
          {:compact, %{content: "Earlier context compacted"}, first_kept}
        ] do
      assert :ok = Log.persist_event(path, event)
    end

    assert {:ok, snapshot} = Log.snapshot(path)

    assert [summary, %{id: "kept-user"}, %{id: "cancelled-assistant", content: []}] =
             snapshot.messages

    assert summary.role == :compaction_summary

    assert {:ok, handle} =
             Runtime.get_session(c.dir, session_id,
               cwd: c.dir,
               transcript_path: path,
               native_tools: true,
               native_memory_root: Path.join(c.dir, "display-memories"),
               provider: Provider,
               model: %{id: "cancel-ui", provider: "cancel-ui", api: "openai-responses"},
               messages: snapshot.messages,
               context_messages: snapshot.context_messages,
               tools: [],
               hook_specs: [],
               options: [test_pid: self()]
             )

    on_exit(fn -> GoalStore.retire(Path.join(path <> ".subagents", "goal")) end)
    route = "/repository/#{Base.url_encode64(c.dir, padding: false)}/sessions/#{session_id}"
    {:ok, idle, _} = live(Phoenix.ConnTest.build_conn(), route)
    render_async(idle, 8_000)
    idle_snapshot = display_snapshot(idle, session_id)
    assert Enum.map(idle_snapshot.messages, & &1.id) == Enum.map(snapshot.messages, & &1.id)

    assert [%{name: "clock::sleep", statusLabel: "turn cancelled", result: nil}] =
             List.last(idle_snapshot.messages).tools

    GenServer.stop(idle.pid)
    assert {:accepted, _} = Sigma.Agent.prompt(handle.agent, "Continue after cancellation")
    current = provider!(session_id)

    refute Enum.any?(current.params.context.messages, fn message ->
             Enum.any?(List.wrap(message.content), &match?(%{type: :tool_call}, &1))
           end)

    writer = Runtime.lookup(c.dir, session_id, :writer)
    assert {:ok, _} = Writer.flush(writer)
    before_reload = File.read!(path)
    {:ok, active, _} = live(Phoenix.ConnTest.build_conn(), route)
    render_async(active, 8_000)
    active_snapshot = display_snapshot(active, session_id)
    assert active_snapshot.runtime.active
    cancelled = Enum.find(active_snapshot.messages, &(&1.id == "cancelled-assistant"))

    assert [%{name: "clock::sleep", statusLabel: "turn cancelled", result: nil}] = cancelled.tools
    assert Enum.take(active_snapshot.messages, 3) == idle_snapshot.messages
    assert File.read!(path) == before_reload
    send(current.pid, {:response, [%{type: :text, text: "Continued"}]})
    assert eventually(fn -> Sigma.Agent.status(handle.agent).phase == :completed end)
    GenServer.stop(active.pid)
    assert {:ok, %{status: :confirmed}} = Sigma.Agent.retire_host(handle.agent)
  end

  defp display_snapshot(view, session_id) do
    %{proxy: {ref, _, _}} = view
    drain_display_snapshots(ref)
    render_hook(view, "chat.sync", %{"id" => "messages", "conversation_id" => session_id})
    assert_push_event(view, "chat:event", %{type: "chat.snapshot"} = snapshot)
    snapshot
  end

  defp drain_display_snapshots(ref) do
    receive do
      {^ref, {:push_event, "chat:event", %{type: "chat.snapshot"}}} ->
        drain_display_snapshots(ref)
    after
      0 -> :ok
    end
  end

  defp detached_child!(c) do
    assert {:accepted, _} = Sigma.Agent.prompt(c.agent, "Delegate work beyond this turn")
    root = provider!(@session)

    send(
      root.pid,
      {:response,
       [
         %{
           type: :tool_call,
           id: "cancel-ui-spawn",
           name: "spawn_agent",
           input_kind: :function,
           arguments: %{"task_name" => "contributor", "message" => "Wait", "fork_turns" => "none"}
         }
       ]}
    )

    child = provider!(:child)
    root = provider!(@session)
    send(root.pid, {:response, [%{type: :text, text: "Root completed"}]})
    assert eventually(fn -> Sigma.Agent.status(c.agent).phase == :completed end)
    assert eventually(fn -> is_nil(:sys.get_state(c.agent).goal_idle_task) end)
    child
  end

  defp provider!(session) do
    receive do
      {:cancel_ui_provider, pid, %{session_id: "child_" <> _} = params} when session == :child ->
        %{pid: pid, params: params}

      {:cancel_ui_provider, pid, %{session_id: ^session} = params} ->
        %{pid: pid, params: params}
    after
      8_000 -> flunk("Provider did not start for #{session}")
    end
  end

  defp eventually(fun, attempts \\ 400)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end
end
