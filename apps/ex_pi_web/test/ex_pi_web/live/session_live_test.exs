defmodule PiWeb.SessionLiveTest do
  use PiWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  @workdir "/tmp/pi-test"
  @encoded_workdir Base.url_encode64(@workdir)

  setup do
    File.mkdir_p!(@workdir)

    sessions_dir =
      Path.join(PiWeb.get_sessions_root(), Base.url_encode64(@workdir, padding: false))

    File.rm_rf!(sessions_dir)
    on_exit(fn -> File.rm_rf!(@workdir) end)
    :ok
  end

  test "renders session page", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/repository/#{@encoded_workdir}/sessions/test")
    assert html =~ "Ask π anything"
    assert html =~ "⌘/Ctrl+Enter to send"
    assert html =~ ~s(id="prompt-input")
    assert html =~ ~s(phx-hook="ChatInputHook")
    assert html =~ "/init"
    assert html =~ ~s(phx-update="ignore")
  end

  test "submits prompt", %{conn: conn} do
    Phoenix.PubSub.subscribe(PiWeb.PubSub, "session:test")
    {:ok, view, _html} = live(conn, "/repository/#{@encoded_workdir}/sessions/test")

    render_submit(view, "send_prompt", %{"value" => "hello"})

    assert_receive {:agent_start, _}, 2000
    assert_receive {:turn_start}, 2000
    assert_receive {:message_start, %{role: :user, content: "hello"}}, 2000
    assert_receive {:message_end, %{role: :assistant}}, 2000
  end

  test "expands init slash command before submitting to the agent", %{conn: conn} do
    Phoenix.PubSub.subscribe(PiWeb.PubSub, "session:test")
    {:ok, view, _html} = live(conn, "/repository/#{@encoded_workdir}/sessions/test")

    render_submit(view, "send_prompt", %{"value" => "/init"})

    assert_receive {:message_start, %{role: :user, content: content}}, 2000
    assert content =~ "Set up a minimal AGENTS.md"
    assert content =~ "Project AGENTS.md gives Pi Agent persistent, team-shared instructions"
    refute content =~ "Claude Code"
  end

  test "rejects unknown slash commands", %{conn: conn} do
    Phoenix.PubSub.subscribe(PiWeb.PubSub, "session:test")
    {:ok, view, _html} = live(conn, "/repository/#{@encoded_workdir}/sessions/test")

    assert render_submit(view, "send_prompt", %{"value" => "/compact"}) =~
             "Unknown slash command: /compact"

    refute_receive {:agent_start, _}, 200
  end

  test "renders streaming tool call before arguments are finalized", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/repository/#{@encoded_workdir}/sessions/test")

    message = %PiAgent.Message{
      id: "msg_assistant_tool_call",
      role: :assistant,
      content: [
        %{type: :thinking, thinking: "I need to read a file."},
        %{
          type: :tool_call,
          id: "call_function_read_1",
          name: "read",
          partial_json: ""
        }
      ],
      timestamp: 1_779_379_527_686
    }

    send(view.pid, {:message_update, message, {:toolcall_start, 1, %{}}})

    assert render(view) =~ "read"
  end
end
