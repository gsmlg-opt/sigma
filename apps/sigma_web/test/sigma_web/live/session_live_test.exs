defmodule Sigma.Web.SessionLiveTest do
  use Sigma.Web.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Sigma.Agent.Message

  @workdir "/tmp/pi-test"
  @encoded_workdir Base.url_encode64(@workdir)

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

  setup do
    File.mkdir_p!(@workdir)

    sessions_dir =
      Path.join(Sigma.Web.get_sessions_root(), Base.url_encode64(@workdir, padding: false))

    File.rm_rf!(sessions_dir)

    on_exit(fn ->
      stop_repository_supervisors(@workdir)
      Process.sleep(50)
      File.rm_rf!(@workdir)
    end)

    :ok
  end

  test "renders session page", %{conn: conn} do
    {:ok, _view, html} = live(conn, session_path(unique_session_id("render")))
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

  test "renders session menu anchors with selector-safe session ids", %{conn: conn} do
    session_id = "PR#5"
    sessions_dir = Sigma.Session.ConfigManager.sessions_dir(@workdir)
    File.mkdir_p!(sessions_dir)
    File.write!(Path.join(sessions_dir, "#{session_id}.jsonl"), "")

    {:ok, _view, html} = live(conn, session_path(session_id))

    assert html =~ ~s(id="session-menu-btn-UFIjNQ")
    assert html =~ ~s(anchor="#session-menu-btn-UFIjNQ")
    refute html =~ ~s(anchor="#session-menu-btn-PR#5")
  end

  test "opens a web shell panel from the session workspace", %{conn: conn} do
    {:ok, view, _html} = live(conn, session_path(unique_session_id("terminal")))

    html =
      view
      |> element("#web-shell-open-btn")
      |> render_click()

    assert html =~ ~s(id="web-shell-panel")
    assert html =~ ~s(phx-hook="WebShellTerminal")
    assert html =~ ~s(data-cwd="#{@workdir}")
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

      {:ok, view, html} = live(conn, session_path(unique_session_id("models")))

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
        Phoenix.PubSub.subscribe(Sigma.Web.PubSub, "session:#{session_id}")

        {:ok, view, _html} = live(conn, session_path(session_id))

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
    Phoenix.PubSub.subscribe(Sigma.Web.PubSub, "session:#{session_id}")
    {:ok, view, _html} = live(conn, session_path(session_id))

    render_submit(view, "send_prompt", %{"value" => "hello"})

    assert_receive {:agent_start, _}, 2000
    assert_receive {:turn_start}, 2000
    assert_receive {:message_start, %{role: :user, content: "hello"}}, 2000
    assert_receive {:message_end, %{role: :assistant}}, 2000
  end

  test "expands init slash command before submitting to the agent", %{conn: conn} do
    session_id = unique_session_id("init")
    Phoenix.PubSub.subscribe(Sigma.Web.PubSub, "session:#{session_id}")
    {:ok, view, _html} = live(conn, session_path(session_id))

    render_submit(view, "send_prompt", %{"value" => "/init"})

    assert_receive {:message_start, %{role: :user, content: content}}, 2000
    assert content =~ "Set up a minimal AGENTS.md"
    assert content =~ "Project AGENTS.md gives Sigma Agent persistent, team-shared instructions"
    refute content =~ "Claude Code"
  end

  test "rejects unknown slash commands", %{conn: conn} do
    session_id = unique_session_id("unknown")
    Phoenix.PubSub.subscribe(Sigma.Web.PubSub, "session:#{session_id}")
    {:ok, view, _html} = live(conn, session_path(session_id))

    assert render_submit(view, "send_prompt", %{"value" => "/compact"}) =~
             "Unknown slash command: /compact"

    refute_receive {:agent_start, _}, 200
  end

  test "renders streaming tool call before arguments are finalized", %{conn: conn} do
    {:ok, view, _html} = live(conn, session_path(unique_session_id("tool_call")))

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
    {:ok, view, _html} = live(conn, session_path(unique_session_id("user_left")))

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
    refute html =~ ~s(variant="filled")
  end

  test "renders message timestamps through the browser-local time hook", %{conn: conn} do
    {:ok, view, _html} = live(conn, session_path(unique_session_id("local_time")))

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
    {:ok, view, html} = live(conn, session_path(unique_session_id("context_size")))

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
    {:ok, view, _html} = live(conn, session_path(unique_session_id("context_monotonic")))

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

    {:ok, _view, html} = live(conn, session_path(session_id))

    assert html =~ "Context: ~12.3K tokens"
  end

  test "renders and answers an AskUserQuestion request", %{conn: conn} do
    session_id = "ask_#{System.unique_integer([:positive])}"
    path = "/repository/#{@encoded_workdir}/sessions/#{session_id}"
    {:ok, view, _html} = live(conn, path)
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
    {:ok, _view, _html} = live(conn, path)
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
    {:ok, view, _html} = live(conn, session_path(unique_session_id("examples")))

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

  defp session_path(session_id) do
    "/repository/#{@encoded_workdir}/sessions/#{URI.encode(session_id, &URI.char_unreserved?/1)}"
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

  defp with_agent_config(tmp_dir, fun) do
    previous_agent_dir = Application.get_env(:sigma_session, :agent_dir)
    previous_provider_config = Application.get_env(:sigma_web, :test_provider_config)

    Application.put_env(:sigma_session, :agent_dir, Path.join(tmp_dir, "agent"))
    Application.delete_env(:sigma_web, :test_provider_config)

    try do
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
