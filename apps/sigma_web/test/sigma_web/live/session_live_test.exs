defmodule Sigma.Web.SessionLiveTest do
  use Sigma.Web.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Sigma.Agent.Message
  alias Sigma.Session.{ConfigManager, RepoManager}

  @workdir "/tmp/pi-test"
  @encoded_workdir Base.url_encode64(@workdir, padding: false)

  defmodule HighUsageProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(_params) do
      initial_msg = %{
        role: :assistant,
        content: [],
        model: "mock-model",
        provider: "mock-provider",
        api: "mock-api",
        usage: %{
          input: 90_000,
          output: 0,
          cache_read: 0,
          cache_write: 0,
          total_tokens: 90_000,
          cost: %{total: 0.0, input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0}
        },
        stop_reason: nil,
        timestamp: System.system_time(:millisecond)
      }

      delta_msg = %{initial_msg | content: [%{type: :text, text: "High usage response"}]}

      done_msg = %{
        delta_msg
        | stop_reason: :stop,
          usage: %{delta_msg.usage | output: 1, total_tokens: 90_001}
      }

      [
        {:start, initial_msg},
        {:text_delta, 0, "High usage response", delta_msg},
        {:done, :stop, done_msg}
      ]
    end
  end

  defmodule CaptureProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params) do
      send(Application.fetch_env!(:sigma_web, :capture_provider_pid), {:provider_params, params})
      Sigma.Web.MockProvider.stream(params)
    end
  end

  setup do
    previous_agent_dir = Application.get_env(:sigma_session, :agent_dir)

    agent_dir =
      Path.join(System.tmp_dir!(), "sigma-session-live-#{System.unique_integer([:positive])}")

    Application.put_env(:sigma_session, :agent_dir, agent_dir)

    on_exit(fn ->
      stop_repository_supervisors(@workdir)
      Process.sleep(50)
      File.rm_rf!(@workdir)
      File.rm_rf!(agent_dir)

      if previous_agent_dir do
        Application.put_env(:sigma_session, :agent_dir, previous_agent_dir)
      else
        Application.delete_env(:sigma_session, :agent_dir)
      end
    end)

    File.mkdir_p!(@workdir)

    sessions_dir = ConfigManager.sessions_dir(@workdir)

    File.rm_rf!(sessions_dir)
    {:ok, _repo} = RepoManager.add_repo(@workdir, name: "Repo")

    :ok
  end

  test "rejects unregistered repository route", %{conn: conn} do
    path = System.tmp_dir!()
    encoded = Base.url_encode64(path, padding: false)

    assert {:error, {:redirect, %{to: "/", flash: %{"error" => "Repository is not registered."}}}} =
             live(conn, "/repository/#{encoded}/sessions/#{unique_session_id("unregistered")}")
  end

  test "rejects invalid repository route", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/", flash: %{"error" => "Repository is not registered."}}}} =
             live(conn, "/repository/not-base64!/sessions/#{unique_session_id("invalid")}")
  end

  test "renders session page", %{conn: conn} do
    {:ok, _view, html} = live_loaded(conn, session_path(unique_session_id("render")))
    assert html =~ "Ask ∑ anything"
    assert html =~ "⌘/Ctrl+Enter to send"
    assert html =~ ~s(id="prompt-input")
    assert html =~ ~s(phx-hook="ChatInputHook")
    assert html =~ "/init"
    assert html =~ ~s(phx-update="ignore")
    assert html =~ "Session List"
    assert html =~ "Settings"
    assert html =~ "Skills"
    assert html =~ "New Session"
    assert html =~ "Terminal"
    assert html =~ ~s(id="web-shell-open-btn")
    assert html =~ ~s(href="/repository/#{@encoded_workdir}/skills")
    assert_session_sidebar_order(html)
  end

  @tag :tmp_dir
  test "loads session while agent startup is still busy", %{conn: conn, tmp_dir: tmp_dir} do
    with_agent_config(tmp_dir, fn ->
      write_provider_configs("openai", "smart", %{"openai" => ["smart"]})
      trust_workdir!(@workdir)
      write_session_start_hook!(@workdir, "sleep 2", timeout: 3)

      {:ok, view, _html} = live(conn, session_path(unique_session_id("slow-start")))
      html = render_async(view, 1000)

      assert html =~ "Ask ∑ anything"
      refute html =~ "Could not load session"
      refute html =~ "pending_user_questions"
    end)
  end

  test "does not render the ignored prompt input disabled while loading" do
    html =
      session_render_assigns(session_ready: false, turn_in_flight: false)
      |> render_session()

    [prompt_input] =
      html
      |> Floki.parse_document!()
      |> Floki.find("#prompt-input")

    refute has_attr?(prompt_input, "disabled")
  end

  test "renders session menu anchors with selector-safe session ids", %{conn: conn} do
    session_id = unique_session_id("selector-safe")
    listed_session_id = "PR#5"
    sessions_dir = Sigma.Session.ConfigManager.sessions_dir(@workdir)
    File.mkdir_p!(sessions_dir)
    File.write!(Path.join(sessions_dir, "#{listed_session_id}.jsonl"), "")

    {:ok, _view, html} = live_loaded(conn, session_path(session_id))

    assert html =~ ~s(id="session-menu-btn-UFIjNQ")
    assert html =~ ~s(anchor="#session-menu-btn-UFIjNQ")
    refute html =~ ~s(anchor="#session-menu-btn-PR#5")
  end

  test "renders basename session id with hash", %{conn: conn} do
    session_id = "PR#5"
    sessions_dir = Sigma.Session.ConfigManager.sessions_dir(@workdir)
    File.mkdir_p!(sessions_dir)
    File.write!(Path.join(sessions_dir, "#{session_id}.jsonl"), "")

    {:ok, _view, html} = live_loaded(conn, session_path(session_id))

    assert html =~ "Ask ∑ anything"
    assert html =~ ~s(id="session-menu-btn-UFIjNQ")
  end

  test "rejects traversal session id route without touching escaped paths", %{conn: conn} do
    sessions_dir = Sigma.Session.ConfigManager.sessions_dir(@workdir)
    outside_path = Path.expand("../escape.jsonl", sessions_dir)

    File.mkdir_p!(sessions_dir)
    File.write!(outside_path, "outside\n")

    assert {:error,
            {:redirect,
             %{
               to: "/repository/#{@encoded_workdir}",
               flash: %{"error" => "Invalid session id."}
             }}} =
             live(conn, session_path("../escape"))

    assert File.read!(outside_path) == "outside\n"
  end

  test "rejects slash-containing session id route", %{conn: conn} do
    assert {:error,
            {:redirect,
             %{
               to: "/repository/#{@encoded_workdir}",
               flash: %{"error" => "Invalid session id."}
             }}} =
             live(conn, session_path("a/b"))
  end

  test "delete menu action rejects traversal session ids", %{conn: conn} do
    session_id = unique_session_id("delete-safe")
    sessions_dir = Sigma.Session.ConfigManager.sessions_dir(@workdir)
    outside_path = Path.expand("../escape.jsonl", sessions_dir)

    File.mkdir_p!(sessions_dir)
    File.write!(outside_path, "outside\n")

    {:ok, view, _html} = live_loaded(conn, session_path(session_id))

    assert render_hook(view, "session_menu_action", %{
             "value" => "delete",
             "session" => "../escape"
           }) =~ "Invalid session id"

    assert File.read!(outside_path) == "outside\n"
  end

  test "rename session rejects traversal target names", %{conn: conn} do
    session_id = unique_session_id("rename-safe")
    sessions_dir = Sigma.Session.ConfigManager.sessions_dir(@workdir)
    source_path = Path.join(sessions_dir, "#{session_id}.jsonl")
    outside_path = Path.expand("../escape.jsonl", sessions_dir)

    File.mkdir_p!(sessions_dir)
    File.write!(source_path, "source\n")

    {:ok, view, _html} = live_loaded(conn, session_path(session_id))

    assert render_submit(view, "rename_session", %{
             "old_id" => session_id,
             "new_name" => "../escape"
           }) =~ "Invalid session id"

    assert File.read!(source_path) == "source\n"
    refute File.exists?(outside_path)
  end

  test "fork retries colliding generated ids before navigating", %{conn: conn} do
    session_id = unique_session_id("fork-source")
    sessions_dir = Sigma.Session.ConfigManager.sessions_dir(@workdir)
    File.mkdir_p!(sessions_dir)

    source_path = Path.join(sessions_dir, "#{session_id}.jsonl")
    :ok = Sigma.Session.Log.persist_event(source_path, {:agent_start, @workdir})

    :ok =
      Sigma.Session.Log.persist_event(source_path, {:message_end, Message.user("m1", "hello")})

    File.write!(Path.join(sessions_dir, "fork_collision_1.jsonl"), "existing 1\n")
    File.write!(Path.join(sessions_dir, "fork_collision_2.jsonl"), "existing 2\n")

    with_fork_id_generator(~w(fork_collision_1 fork_collision_2 fork_success), fn ->
      {:ok, view, _html} = live_loaded(conn, session_path(session_id))

      assert {:error,
              {:live_redirect, %{to: "/repository/#{@encoded_workdir}/sessions/fork_success"}}} =
               render_hook(view, "session_menu_action", %{
                 "value" => "fork",
                 "session" => session_id
               })
    end)

    assert File.read!(Path.join(sessions_dir, "fork_collision_1.jsonl")) == "existing 1\n"
    assert File.read!(Path.join(sessions_dir, "fork_collision_2.jsonl")) == "existing 2\n"
    assert File.regular?(Path.join(sessions_dir, "fork_success.jsonl"))
  end

  test "same raw session id in different repositories does not receive each other's events", %{
    conn: conn
  } do
    session_id = unique_session_id("shared")
    other_workdir = unique_workdir("session-live-shared")
    register_repo!(other_workdir, "Other Repo")

    on_exit(fn ->
      stop_repository_supervisors(other_workdir)
      File.rm_rf!(other_workdir)
    end)

    {:ok, view, _html} = live_loaded(conn, session_path(session_id))
    {:ok, other_view, _html} = live_loaded(conn, session_path(other_workdir, session_id))

    render_submit(view, "send_prompt", %{"value" => "from repo one"})

    assert_eventually(fn -> render(view) =~ "from repo one" end)
    refute_eventually(fn -> render(other_view) =~ "from repo one" end)
  end

  test "opens a web shell panel from the session workspace", %{conn: conn} do
    {:ok, view, _html} = live_loaded(conn, session_path(unique_session_id("terminal")))

    html =
      view
      |> element("#web-shell-open-btn")
      |> render_click()

    assert html =~ ~s(id="web-shell-panel")
    assert html =~ ~s(phx-hook="WebShellTerminal")
    assert html =~ ~s(data-cwd="#{@workdir}")
    assert html =~ "Starting shell..."

    html = render_hook(view, "web_shell_resize", %{"cols" => 132, "rows" => 31})

    assert html =~ "Shell ready"
  end

  @tag :tmp_dir
  test "model selector lists all configured models and selects default model", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    with_agent_config(tmp_dir, fn ->
      write_provider_configs("openai", "smart", %{
        "openai" => ["fast", "smart"],
        "anthropic" => ["claude", "opus"]
      })

      {:ok, view, html} = live_loaded(conn, session_path(unique_session_id("models")))

      options = Floki.parse_document!(html) |> Floki.find("#model-select option")

      assert html =~ ~s(id="model-select")

      assert Enum.map(options, &option_text/1) == [
               "openai: fast",
               "openai: smart",
               "anthropic: claude",
               "anthropic: opus"
             ]

      selected_value =
        options
        |> Enum.find(&selected?/1)
        |> Floki.attribute("value")
        |> List.first()

      assert {:ok, %{"provider_id" => "openai", "model_id" => "smart"}} =
               Jason.decode(selected_value)

      anthropic_value =
        options
        |> Enum.find(&(option_text(&1) == "anthropic: opus"))
        |> Floki.attribute("value")
        |> List.first()

      render_change(view, "select_model", %{"model" => anthropic_value})

      settings =
        Sigma.Session.ConfigManager.agent_dir()
        |> Path.join("settings.json")
        |> File.read!()
        |> Jason.decode!()

      assert settings["defaultProvider"] == "anthropic"
      assert settings["defaultModel"] == "opus"
    end)
  end

  @tag :tmp_dir
  test "model selector passes selected provider credential to the agent", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    with_agent_config(tmp_dir, fn ->
      with_mock_provider(CaptureProvider, fn ->
        with_capture_provider_pid(self(), fn ->
          write_selectable_provider_configs()

          {:ok, view, html} =
            live_loaded(conn, session_path(unique_session_id("model-credential")))

          minimax_value =
            html
            |> Floki.parse_document!()
            |> Floki.find("#model-select option")
            |> Enum.find(&(option_text(&1) == "MiniMax: MiniMax-M3"))
            |> Floki.attribute("value")
            |> List.first()

          render_change(view, "select_model", %{"model" => minimax_value})
          render_submit(view, "send_prompt", %{"value" => "hello"})

          assert_receive {:provider_params, %{model: %{id: "MiniMax-M3"}, options: options}},
                         3000

          assert Keyword.get(options, :api_key) == "secret-key"
          assert Keyword.get(options, :auth_type) == "x-api-key"
        end)
      end)
    end)
  end

  @tag :tmp_dir
  test "does not compact when usage fits configured model context window", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    with_agent_config(tmp_dir, fn ->
      with_mock_provider(HighUsageProvider, fn ->
        write_provider_configs("openai", "smart", %{
          "openai" => [%{"id" => "smart", "contextWindow" => 1_000_000}]
        })

        session_id = unique_session_id("large-context")
        storage_path = preload_compactable_history(session_id)
        Phoenix.PubSub.subscribe(Sigma.Web.PubSub, session_topic(@workdir, session_id))

        {:ok, view, _html} = live_loaded(conn, session_path(session_id))

        render_submit(view, "send_prompt", %{"value" => "hello"})

        assert_receive {:agent_end, _messages}, 3000
        refute_receive {:compact, %Message{role: :compaction_summary}, _first_kept_id}, 200

        assert {:ok, messages} = Sigma.Session.Log.replay(storage_path)
        refute Enum.any?(messages, &(&1.role == :compaction_summary))
      end)
    end)
  end

  test "submits prompt", %{conn: conn} do
    session_id = unique_session_id("submit")
    Phoenix.PubSub.subscribe(Sigma.Web.PubSub, session_topic(@workdir, session_id))
    {:ok, view, _html} = live_loaded(conn, session_path(session_id))

    render_submit(view, "send_prompt", %{"value" => "hello"})

    assert_receive {:agent_start, _}, 2000
    assert_receive {:turn_start}, 2000
    assert_receive {:message_start, %{role: :user, content: "hello"}}, 2000
    assert_receive {:message_end, %{role: :assistant}}, 2000
  end

  test "retries a persisted user message", %{conn: conn} do
    session_id = unique_session_id("retry")
    storage_path = session_storage_path(session_id)
    File.mkdir_p!(Path.dirname(storage_path))

    :ok =
      Sigma.Session.Log.persist_event(
        storage_path,
        {:message_end, Message.user("u_retry", "try again")}
      )

    Phoenix.PubSub.subscribe(Sigma.Web.PubSub, session_topic(@workdir, session_id))

    {:ok, view, _html} = live_loaded(conn, session_path(session_id))

    view
    |> element("#retry-u_retry")
    |> render_click()

    assert_receive {:agent_start, _}, 2000
    assert_receive {:turn_start}, 2000
    assert_receive {:message_start, %{role: :user, content: "try again"}}, 2000
  end

  test "expands init slash command before submitting to the agent", %{conn: conn} do
    session_id = unique_session_id("init")
    Phoenix.PubSub.subscribe(Sigma.Web.PubSub, session_topic(@workdir, session_id))
    {:ok, view, _html} = live_loaded(conn, session_path(session_id))

    render_submit(view, "send_prompt", %{"value" => "/init"})

    assert_receive {:message_start, %{role: :user, content: content}}, 2000
    assert content =~ "Set up a minimal AGENTS.md"
    assert content =~ "Project AGENTS.md gives Sigma Agent persistent, team-shared instructions"
    refute content =~ "Claude Code"
  end

  test "rejects unknown slash commands", %{conn: conn} do
    session_id = unique_session_id("unknown")
    Phoenix.PubSub.subscribe(Sigma.Web.PubSub, session_topic(@workdir, session_id))
    {:ok, view, _html} = live_loaded(conn, session_path(session_id))

    assert render_submit(view, "send_prompt", %{"value" => "/compact"}) =~
             "Unknown slash command: /compact"

    refute_receive {:agent_start, _}, 200
  end

  test "renders streaming tool call before arguments are finalized", %{conn: conn} do
    {:ok, view, _html} = live_loaded(conn, session_path(unique_session_id("tool_call")))

    message = %Sigma.Agent.Message{
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
    {:ok, view, _html} = live_loaded(conn, session_path(unique_session_id("user_left")))

    message = %Sigma.Agent.Message{
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
    assert html =~ ~s(id="retry-msg_user_left")
    assert html =~ "Retry"
    refute html =~ ~s(variant="filled")
  end

  test "renders message timestamps through the browser-local time hook", %{conn: conn} do
    {:ok, view, _html} = live_loaded(conn, session_path(unique_session_id("local_time")))

    message = %Sigma.Agent.Message{
      id: "msg_user_time",
      role: :user,
      content: "hello",
      timestamp: 1_779_379_527_686
    }

    send(view.pid, {:message_start, message})

    html = render(view)
    assert html =~ ~s(id="msg_user_time-local-time")
    assert html =~ ~s(phx-hook="LocalTime")
    assert html =~ ~s(data-ts="1779379527686")
  end

  test "renders latest session context size below the chat box", %{conn: conn} do
    {:ok, view, html} = live_loaded(conn, session_path(unique_session_id("context_size")))

    assert html =~ ~s(id="session-context-size")
    assert html =~ "Context: 0 tokens"

    message = %Sigma.Agent.Message{
      id: "msg_context_size",
      role: :assistant,
      content: [%{type: :text, text: "done"}],
      timestamp: 1_779_379_527_686,
      usage: %{
        input: 12_345,
        output: 67,
        cache_read: 0,
        cache_write: 0,
        total_tokens: 12_412,
        cost: %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0, total: 0.0}
      }
    }

    send(view.pid, {:message_end, message})

    html = render(view)
    assert html =~ "Context: ~12.3K tokens"
    assert html =~ ~s(title="12,345 tokens")
  end

  test "keeps session context size readable and monotonic", %{conn: conn} do
    {:ok, view, _html} = live_loaded(conn, session_path(unique_session_id("context_monotonic")))

    send(view.pid, {:message_end, assistant_usage_message("large", 12_345)})
    assert render(view) =~ "Context: ~12.3K tokens"

    send(view.pid, {:message_end, assistant_usage_message("small", 105)})
    assert render(view) =~ "Context: ~12.3K tokens"

    send(view.pid, {:message_end, assistant_usage_message("larger", 15_200)})
    assert render(view) =~ "Context: ~15.2K tokens"
  end

  test "keeps session context size monotonic after replay", %{conn: conn} do
    session_id = unique_session_id("context_replay")
    storage_path = session_storage_path(session_id)
    File.mkdir_p!(Path.dirname(storage_path))

    :ok =
      Sigma.Session.Log.persist_event(
        storage_path,
        {:message_end, assistant_usage_message("large", 12_345)}
      )

    :ok =
      Sigma.Session.Log.persist_event(
        storage_path,
        {:message_end, assistant_usage_message("small", 105)}
      )

    {:ok, _view, html} = live_loaded(conn, session_path(session_id))

    assert html =~ "Context: ~12.3K tokens"
  end

  test "renders and answers an AskUserQuestion request", %{conn: conn} do
    session_id = "ask_#{System.unique_integer([:positive])}"
    path = "/repository/#{@encoded_workdir}/sessions/#{session_id}"
    {:ok, view, _html} = live_loaded(conn, path)
    {:ok, {agent, _policy}} = Sigma.Web.SessionManager.get_agent(session_id, repo_path: @workdir)

    task =
      Task.async(fn ->
        Sigma.Agent.ask_user_question(
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
    {:ok, _view, _html} = live_loaded(conn, path)
    {:ok, {agent, _policy}} = Sigma.Web.SessionManager.get_agent(session_id, repo_path: @workdir)

    task =
      Task.async(fn ->
        Sigma.Agent.ask_user_question(
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
    {:ok, refreshed_view, refreshed_html} = live_loaded(conn, path)

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
    {:ok, view, _html} = live_loaded(conn, session_path(unique_session_id("examples")))

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

  defp unique_session_id(prefix) do
    "#{prefix}_#{System.unique_integer([:positive, :monotonic])}"
  end

  defp unique_workdir(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive, :monotonic])}")
  end

  defp with_fork_id_generator(ids, fun) do
    previous = Application.get_env(:sigma_web, :session_live_fork_id_generator)
    {:ok, agent} = Agent.start_link(fn -> ids end)

    Application.put_env(:sigma_web, :session_live_fork_id_generator, fn ->
      Agent.get_and_update(agent, fn
        [id | rest] -> {id, rest}
        [] -> {"fork_exhausted", []}
      end)
    end)

    try do
      fun.()
    after
      Agent.stop(agent)

      if previous do
        Application.put_env(:sigma_web, :session_live_fork_id_generator, previous)
      else
        Application.delete_env(:sigma_web, :session_live_fork_id_generator)
      end
    end
  end

  defp register_repo!(workdir, name) do
    File.mkdir_p!(workdir)
    {:ok, _repo} = RepoManager.add_repo(workdir, name: name)
  end

  defp trust_workdir!(workdir) do
    agent_dir = Sigma.Session.ConfigManager.agent_dir()
    File.mkdir_p!(agent_dir)

    File.write!(
      Path.join(agent_dir, "repos.jsonl"),
      Jason.encode!(%{"path" => Path.expand(workdir), "trusted" => true}) <> "\n"
    )
  end

  defp write_session_start_hook!(workdir, command, opts) do
    hooks_dir = Path.join(workdir, ".pi")
    File.mkdir_p!(hooks_dir)

    File.write!(
      Path.join(hooks_dir, "hooks.json"),
      Jason.encode!([
        %{
          "event" => "SessionStart",
          "hooks" => [
            %{
              "hooks" => [
                %{"command" => command, "timeout" => Keyword.fetch!(opts, :timeout)}
              ]
            }
          ]
        }
      ])
    )
  end

  defp session_path(session_id) do
    session_path(@workdir, session_id)
  end

  defp session_path(workdir, session_id) do
    encoded_workdir = ConfigManager.repository_key(workdir)
    "/repository/#{encoded_workdir}/sessions/#{URI.encode(session_id, &URI.char_unreserved?/1)}"
  end

  defp render_session(assigns) do
    assigns
    |> Map.put(:__changed__, %{})
    |> Sigma.Web.SessionLive.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp session_render_assigns(overrides) do
    Map.merge(
      %{
        active_provider_id: nil,
        context_token_count: 0,
        context_window: nil,
        current_model_value: nil,
        effective_cwd: @workdir,
        encoded_repository: @encoded_workdir,
        log_entries: [],
        log_filter: nil,
        log_search: "",
        model_options: [],
        pending_user_questions: [],
        renaming_session: nil,
        session_id: "render_session",
        session_ready: true,
        sessions: [],
        show_logs: false,
        show_web_shell: false,
        storage_path: session_storage_path("render_session"),
        streaming_message_id: nil,
        streams: %{messages: []},
        tool_results: %{},
        turn_in_flight: false,
        web_shell_status: "Shell ready",
        workdir: @workdir
      },
      Map.new(overrides)
    )
  end

  defp live_loaded(conn, path) do
    {:ok, view, _html} = live(conn, path)
    {:ok, view, render_async(view, 1_000)}
  end

  defp session_topic(workdir, session_id) do
    repo_key = ConfigManager.repository_key(workdir)
    "session:#{repo_key}:#{session_id}"
  end

  defp assert_eventually(fun),
    do: assert_eventually(fun, System.monotonic_time(:millisecond) + 2_000)

  defp assert_eventually(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition was not met before timeout")
      end

      Process.sleep(20)
      assert_eventually(fun, deadline)
    end
  end

  defp refute_eventually(fun),
    do: refute_eventually(fun, System.monotonic_time(:millisecond) + 300)

  defp refute_eventually(fun, deadline) do
    if fun.() do
      flunk("condition unexpectedly became true")
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(20)
        refute_eventually(fun, deadline)
      end
    end
  end

  defp stop_repository_supervisors(repo) do
    repo = Sigma.Agent.Runtime.normalize_repo_path(repo)

    for {_id, pid, :supervisor, [Sigma.Agent.RepositorySupervisor]} <-
          DynamicSupervisor.which_children(Sigma.Agent.DynamicSupervisor),
        Process.alive?(pid),
        repo_supervisor_for?(pid, repo) do
      ref = Process.monitor(pid)
      DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        500 -> :ok
      end
    end
  end

  defp repo_supervisor_for?(supervisor, repo) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(false, fn
      {Sigma.Agent.RepositoryProcess, pid, :worker, [Sigma.Agent.RepositoryProcess]}
      when is_pid(pid) ->
        %{repo_path: repo_path} = Sigma.Agent.RepositoryProcess.status(pid)
        repo_path == repo

      _ ->
        false
    end)
  end

  defp has_attr?({_tag, attrs, _children}, name) do
    Enum.any?(attrs, fn
      {^name, _value} -> true
      _ -> false
    end)
  end

  defp with_agent_config(tmp_dir, fun) do
    previous_agent_dir = Application.get_env(:sigma_session, :agent_dir)
    previous_provider_config = Application.get_env(:sigma_web, :test_provider_config)

    Application.put_env(:sigma_session, :agent_dir, Path.join(tmp_dir, "agent"))
    Application.delete_env(:sigma_web, :test_provider_config)

    try do
      {:ok, _repo} = RepoManager.add_repo(@workdir, name: "Repo")
      fun.()
    after
      if previous_agent_dir do
        Application.put_env(:sigma_session, :agent_dir, previous_agent_dir)
      else
        Application.delete_env(:sigma_session, :agent_dir)
      end

      if previous_provider_config do
        Application.put_env(:sigma_web, :test_provider_config, previous_provider_config)
      else
        Application.delete_env(:sigma_web, :test_provider_config)
      end
    end
  end

  defp with_mock_provider(provider_module, fun) do
    previous = Application.get_env(:sigma_web, :mock_provider_module)
    Application.put_env(:sigma_web, :mock_provider_module, provider_module)

    try do
      fun.()
    after
      if previous do
        Application.put_env(:sigma_web, :mock_provider_module, previous)
      else
        Application.delete_env(:sigma_web, :mock_provider_module)
      end
    end
  end

  defp with_capture_provider_pid(pid, fun) do
    previous = Application.get_env(:sigma_web, :capture_provider_pid)
    Application.put_env(:sigma_web, :capture_provider_pid, pid)

    try do
      fun.()
    after
      if previous do
        Application.put_env(:sigma_web, :capture_provider_pid, previous)
      else
        Application.delete_env(:sigma_web, :capture_provider_pid)
      end
    end
  end

  defp write_selectable_provider_configs do
    agent_dir = Sigma.Session.ConfigManager.agent_dir()
    File.mkdir_p!(agent_dir)

    File.write!(
      Path.join(agent_dir, "settings.json"),
      Jason.encode!(%{"defaultProvider" => "openai", "defaultModel" => "smart"})
    )

    File.write!(
      Path.join(agent_dir, "auth.json"),
      Jason.encode!(%{
        "minimax-cred" => %{"type" => "api_key", "key" => "secret-key", "name" => "MiniMax"}
      })
    )

    File.write!(
      Path.join(agent_dir, "models.json"),
      Jason.encode!(%{
        "providers" => %{
          "openai" => %{
            "name" => "openai",
            "api" => "mock",
            "models" => [%{"id" => "smart"}]
          },
          "minimax" => %{
            "name" => "MiniMax",
            "api" => "mock",
            "credential_id" => "minimax-cred",
            "authType" => "x-api-key",
            "models" => [%{"id" => "MiniMax-M3"}]
          }
        }
      })
    )
  end

  defp write_provider_configs(default_provider_id, default_model, providers) do
    agent_dir = Sigma.Session.ConfigManager.agent_dir()
    File.mkdir_p!(agent_dir)

    File.write!(
      Path.join(agent_dir, "settings.json"),
      Jason.encode!(%{"defaultProvider" => default_provider_id, "defaultModel" => default_model})
    )

    File.write!(
      Path.join(agent_dir, "models.json"),
      Jason.encode!(%{
        "providers" =>
          Enum.into(providers, %{}, fn {provider_id, models} ->
            {provider_id,
             %{
               "name" => provider_id,
               "api" => "mock",
               "models" => Enum.map(models, &test_model_config/1)
             }}
          end)
      })
    )
  end

  defp test_model_config(model) when is_map(model), do: model
  defp test_model_config(model), do: %{"id" => model}

  defp assistant_usage_message(id, input_tokens) do
    %Sigma.Agent.Message{
      id: "msg_context_#{id}",
      role: :assistant,
      content: [%{type: :text, text: "done"}],
      timestamp: 1_779_379_527_686,
      usage: %{
        input: input_tokens,
        output: 0,
        cache_read: 0,
        cache_write: 0,
        total_tokens: input_tokens,
        cost: %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0, total: 0.0}
      }
    }
  end

  defp preload_compactable_history(session_id) do
    storage_path = session_storage_path(session_id)
    File.mkdir_p!(Path.dirname(storage_path))

    :ok = Sigma.Session.Log.persist_event(storage_path, {:agent_start, @workdir})

    Enum.each(1..11, fn i ->
      :ok =
        Sigma.Session.Log.persist_event(
          storage_path,
          {:message_end, Message.user("u#{i}", "msg #{i}")}
        )

      :ok = Sigma.Session.Log.persist_event(storage_path, {:message_end, assistant_message(i)})
    end)

    storage_path
  end

  defp session_storage_path(session_id) do
    @workdir
    |> Sigma.Session.ConfigManager.sessions_dir()
    |> Path.join("#{session_id}.jsonl")
  end

  defp assistant_message(i) do
    %Message{
      id: "a#{i}",
      role: :assistant,
      content: [%{type: :text, text: "r#{i}"}],
      timestamp: i
    }
  end

  defp option_text(option) do
    option
    |> Floki.text()
    |> String.trim()
  end

  defp selected?({_tag, attrs, _children}) do
    Enum.any?(attrs, fn
      {"selected", value} -> value in ["", "true", "selected"]
      _ -> false
    end)
  end
end
