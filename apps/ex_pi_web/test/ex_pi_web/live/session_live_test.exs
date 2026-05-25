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
    assert html =~ "Session List"
    assert html =~ "Settings"
    assert html =~ "Skills"
    assert html =~ "New Session"
    assert html =~ ~s(href="/repository/#{@encoded_workdir}/skills")
    assert_session_sidebar_order(html)
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

  test "renders user messages aligned to the left", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/repository/#{@encoded_workdir}/sessions/test")

    message = %PiAgent.Message{
      id: "msg_user_left",
      role: :user,
      content: "hello",
      timestamp: 1_779_379_527_686
    }

    send(view.pid, {:message_start, message})

    html = render(view)
    assert html =~ ~s(id="msg_user_left")
    assert html =~ ~s(align="start")
    assert html =~ ~s(color="secondary")
    refute html =~ ~s(variant="filled")
  end

  test "renders and answers an AskUserQuestion request", %{conn: conn} do
    session_id = "ask_#{System.unique_integer([:positive])}"
    path = "/repository/#{@encoded_workdir}/sessions/#{session_id}"
    {:ok, view, _html} = live(conn, path)
    {:ok, {agent, _policy}} = PiWeb.SessionManager.get_agent(session_id)

    task =
      Task.async(fn ->
        PiAgent.ask_user_question(
          agent,
          %{
            question: "Which setup path should I use?",
            options: [
              %{label: "Project", value: "project", description: "Repository instructions"},
              %{label: "User", value: "user", description: nil}
            ],
            allow_freeform: true,
            placeholder: "Type another answer"
          },
          timeout: 1_000
        )
      end)

    Process.sleep(20)
    html = render(view)
    assert html =~ "Which setup path should I use?"
    assert html =~ "Project"
    assert html =~ "Type another answer"
    assert html =~ ~s(id="ask-user-question-option-)

    view
    |> form("#ask-user-questions form", %{
      "selected_answer" => "project",
      "answer" => ""
    })
    |> render_submit()

    assert {:ok, "project"} = Task.await(task)
    refute render(view) =~ "Which setup path should I use?"
  end

  test "reopens a pending AskUserQuestion after refresh", %{conn: conn} do
    session_id = "ask_refresh_#{System.unique_integer([:positive])}"
    path = "/repository/#{@encoded_workdir}/sessions/#{session_id}"
    {:ok, _view, _html} = live(conn, path)
    {:ok, {agent, _policy}} = PiWeb.SessionManager.get_agent(session_id)

    task =
      Task.async(fn ->
        PiAgent.ask_user_question(
          agent,
          %{
            question: "Which mode should I use?",
            options: ["Fast", "Accurate"],
            allow_freeform: true
          },
          timeout: 1_000
        )
      end)

    Process.sleep(20)
    {:ok, refreshed_view, refreshed_html} = live(conn, path)

    assert refreshed_html =~ "Which mode should I use?"
    assert refreshed_html =~ "Fast"
    assert refreshed_html =~ "Accurate"

    refreshed_view
    |> form("#ask-user-questions form", %{
      "selected_answer" => "Fast",
      "answer" => ""
    })
    |> render_submit()

    assert {:ok, "Fast"} = Task.await(task)
    refute render(refreshed_view) =~ "Which mode should I use?"
  end

  test "renders placeholder examples as selectable answers before freeform input", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/repository/#{@encoded_workdir}/sessions/test")

    send(
      view.pid,
      {:ask_user_question, "ask_examples",
       %{
         question: "How should the faster proxy be selected?",
         options: [],
         allow_freeform: true,
         placeholder: "e.g., geo-based, latency-based, load-balanced"
       }}
    )

    html = render(view)
    assert html =~ ~s(id="ask-user-question-option-ask_examples-1")
    assert html =~ ~s(id="ask-user-question-custom-ask_examples")
    assert html =~ ~s(id="ask-user-question-input-ask_examples")

    assert :binary.match(html, ~s(id="ask-user-question-option-ask_examples-1")) <
             :binary.match(html, ~s(id="ask-user-question-input-ask_examples"))

    assert html =~ "geo-based"
    assert html =~ "latency-based"
    assert html =~ "load-balanced"
    refute html =~ "e.g., geo-based, latency-based, load-balanced"
  end

  defp assert_session_sidebar_order(html) do
    assert :binary.match(html, "session-sidebar-settings") <
             :binary.match(html, "session-sidebar-skills")

    assert :binary.match(html, "session-sidebar-skills") <
             :binary.match(html, "session-sidebar-new-session")

    assert :binary.match(html, "session-sidebar-new-session") <
             :binary.match(html, "session-sidebar-session-list")
  end
end
