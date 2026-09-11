defmodule Sigma.Web.SessionLiveTest do
  use Sigma.Web.ConnCase, async: false
  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog

  alias Sigma.Agent.Message
  alias Sigma.Session.{ConfigManager, Log, RepoManager}

  @workdir "/tmp/pi-test"
  @encoded_workdir Base.url_encode64(@workdir, padding: false)
  @png_data Base.encode64(<<137, 80, 78, 71, 13, 10, 26, 10>>)

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

  defmodule ManualCompactionProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(%{purpose: :compaction}) do
      message = %{
        role: :assistant,
        content: [%{type: :text, text: "Compact session summary"}],
        model: "mock-model",
        provider: "mock-provider",
        usage: %{input: 20, output: 3, total_tokens: 23},
        stop_reason: :stop,
        timestamp: System.system_time(:millisecond)
      }

      [{:start, %{message | content: []}}, {:done, :stop, message}]
    end

    def stream(%{purpose: :turn}) do
      message = %{
        role: :assistant,
        content: [%{type: :text, text: "Context measured"}],
        model: "mock-model",
        provider: "mock-provider",
        usage: %{input: 100_000, output: 1, total_tokens: 100_001},
        stop_reason: :stop,
        timestamp: System.system_time(:millisecond)
      }

      [{:start, %{message | content: []}}, {:done, :stop, message}]
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

  defmodule PermissionToolProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params) do
      last_message = List.last(params.context.messages)

      content =
        if last_message && last_message.role == :tool_result do
          [%{type: :text, text: "permission flow complete"}]
        else
          target = Application.fetch_env!(:sigma_web, :permission_test_path)

          [
            %{
              type: :tool_call,
              id: "permission_bash_call",
              name: "bash",
              arguments: %{"command" => "printf permitted > #{target}"}
            }
          ]
        end

      stop_reason =
        if last_message && last_message.role == :tool_result, do: :stop, else: :tool_use

      message = %{
        role: :assistant,
        content: content,
        model: "mock-model",
        provider: "mock-provider",
        api: "mock-api",
        usage: %{
          input: 1,
          output: 1,
          cache_read: 0,
          cache_write: 0,
          total_tokens: 2,
          cost: %{total: 0.0, input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0}
        },
        stop_reason: stop_reason,
        timestamp: System.system_time(:millisecond)
      }

      [{:start, message}, {:done, stop_reason, message}]
    end
  end

  defmodule BlockingTurnProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params) do
      test_pid = Application.fetch_env!(:sigma_web, :blocking_provider_pid)
      cancellation_ref = Keyword.fetch!(params.options, :cancellation_ref)

      prompt =
        params.context.messages
        |> List.last()
        |> Map.fetch!(:content)
        |> List.wrap()
        |> Enum.reverse()
        |> Enum.find_value(fn
          %{type: :text, text: text} -> text
          text when is_binary(text) -> text
          _part -> nil
        end)

      send(test_pid, {:web_provider_waiting, self(), prompt})

      receive do
        :release_web_provider ->
          Sigma.Web.MockProvider.stream(params)

        {:cancel, ^cancellation_ref} ->
          [{:provider_error, Sigma.Ai.ProviderError.from_reason(:cancelled)}]
      end
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
    {:ok, view, html} = live_loaded(conn, session_path(unique_session_id("render")))
    assert html =~ "Ask ∑ anything"
    refute html =~ "Enter sends"
    refute html =~ "Ctrl+Enter to send"
    assert html =~ ~s(id="prompt-input")
    assert html =~ ~s(phx-hook="ChatInputHook")
    assert html =~ "/init"
    assert html =~ ~s(phx-update="ignore")
    assert html =~ "Session List"
    assert html =~ "Settings"
    assert html =~ "Skills"
    assert html =~ "New Session"
    assert html =~ "Terminal"
    assert html =~ ~s(id="session-terminal-open-btn")
    assert html =~ ~s(id="session-observability-open-btn")
    assert html =~ ~s(href="/repository/#{@encoded_workdir}/skills")
    assert_session_sidebar_order(html)

    drawer_html = render_click(view, "toggle_observability")
    assert drawer_html =~ ~s(id="session-observability-drawer")
    assert drawer_html =~ ~s(aria-label="Close session observability")
  end

  @tag :tmp_dir
  test "loads session while agent startup is still busy", %{conn: conn, tmp_dir: tmp_dir} do
    with_agent_config(tmp_dir, fn ->
      write_provider_configs("openai", "smart", %{"openai" => ["smart"]})
      trust_workdir!(@workdir)
      write_session_start_hook!(@workdir, "sleep 2", timeout: 3)

      {:ok, view, _html} = live(conn, session_path(unique_session_id("slow-start")))
      html = render(view)

      assert html =~ "Ask ∑ anything"
      refute html =~ "Could not load session"
      refute html =~ "pending_user_questions"

      loaded_html = render_async(view, 4_000)
      assert loaded_html =~ "Ask ∑ anything"
      refute loaded_html =~ "Could not load session"
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

    [compact_button] =
      html
      |> Floki.parse_document!()
      |> Floki.find("#compact-session-btn")

    assert has_attr?(compact_button, "disabled")
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

    :ok =
      Sigma.Session.Log.persist_event(
        source_path,
        {:message_end, Message.assistant("m2", %{content: "done"})}
      )

    File.write!(Path.join(sessions_dir, "fork_collision_1.jsonl"), "existing 1\n")
    File.write!(Path.join(sessions_dir, "fork_collision_2.jsonl"), "existing 2\n")

    with_fork_id_generator(~w(fork_collision_1 fork_collision_2 fork_success), fn ->
      {:ok, view, _html} = live_loaded(conn, session_path(session_id))

      html =
        render_hook(view, "session_menu_action", %{
          "value" => "fork",
          "session" => session_id
        })

      assert html =~ ~s(id="fork-session-modal")

      assert {:error,
              {:live_redirect, %{to: "/repository/#{@encoded_workdir}/sessions/fork_success"}}} =
               render_submit(view, "confirm_fork", %{
                 "title" => "Fork after collisions",
                 "switch" => "true"
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

  test "opens one session-owned terminal and closes it explicitly", %{conn: conn} do
    {:ok, view, _html} = live_loaded(conn, session_path(unique_session_id("terminal")))

    html =
      view
      |> element("#session-terminal-open-btn")
      |> render_click()

    assert html =~ ~s(id="session-terminal-panel")
    assert html =~ ~s(phx-hook="SessionTerminals")

    assert_eventually(fn -> render(view) =~ "1 retained terminals" end)
    html = render(view)

    [terminal_id] =
      html
      |> Floki.parse_document!()
      |> Floki.find("[role=tab]")
      |> Floki.attribute("data-terminal-id")

    render_hook(view, "terminal_close", %{"terminal_id" => terminal_id})
    assert_eventually(fn -> render(view) =~ "No retained terminals." end)
  end

  test "two windows share the catalog while keeping terminal selection local", %{conn: conn} do
    session_id = unique_session_id("terminal-windows")
    path = session_path(session_id)
    {:ok, first, _html} = live_loaded(conn, path)
    {:ok, second, _html} = live_loaded(conn, path)

    render_hook(first, "terminal_open", %{})
    render_hook(second, "terminal_open", %{})

    assert_eventually(fn -> terminal_ids(render(first)) |> length() == 1 end)
    assert_eventually(fn -> terminal_ids(render(second)) == terminal_ids(render(first)) end)

    render_hook(first, "terminal_create", %{})
    assert_eventually(fn -> terminal_ids(render(first)) |> length() == 2 end)
    assert_eventually(fn -> terminal_ids(render(second)) == terminal_ids(render(first)) end)
    [first_id, second_id] = terminal_ids(render(first))

    render_hook(first, "terminal_select", %{"terminal_id" => first_id})
    render_hook(second, "terminal_select", %{"terminal_id" => second_id})
    assert selected_terminal_id(render(first)) == first_id
    assert selected_terminal_id(render(second)) == second_id

    render_hook(first, "terminal_rename_submit", %{
      "terminal_id" => first_id,
      "label" => "Shared terminal"
    })

    assert_eventually(fn -> render(second) =~ "Shared terminal" end)

    Enum.each([first_id, second_id], fn terminal_id ->
      render_hook(first, "terminal_close", %{"terminal_id" => terminal_id})
    end)

    assert_eventually(fn -> terminal_ids(render(first)) == [] end)
    assert_eventually(fn -> terminal_ids(render(second)) == [] end)
  end

  test "disabled terminal gate is explicit and never creates a fallback shell", %{conn: conn} do
    previous = Application.get_env(:sigma_web, :session_terminals_enabled)
    Application.put_env(:sigma_web, :session_terminals_enabled, false)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:sigma_web, :session_terminals_enabled),
        else: Application.put_env(:sigma_web, :session_terminals_enabled, previous)
    end)

    {:ok, view, html} = live_loaded(conn, session_path(unique_session_id("terminal-disabled")))
    assert html =~ "Terminals disabled"

    html = render_hook(view, "terminal_open", %{})
    assert html =~ "Terminals are disabled by the deployment configuration."
    assert html =~ "Terminal is unavailable: disabled"
    refute html =~ ~s(data-terminal-host="true")
  end

  test "takeover fences the old window and forged browser scope is rejected", %{conn: conn} do
    session_id = unique_session_id("terminal-fence")
    path = session_path(session_id)
    {:ok, first, _html} = live_loaded(conn, path)
    {:ok, second, _html} = live_loaded(conn, path)

    render_hook(first, "terminal_open", %{})
    assert_eventually(fn -> terminal_ids(render(first)) |> length() == 1 end)
    [terminal_id] = terminal_ids(render(first))

    render_hook(second, "terminal_open", %{})
    assert_eventually(fn -> render(second) =~ "sigma-terminal-state is-running" end)
    render_hook(second, "terminal_select", %{"terminal_id" => terminal_id})

    assert_eventually(fn ->
      terminal_fence(render(second), terminal_id)["attachment_id"] != nil
    end)

    render_hook(second, "terminal_take_control", %{"terminal_id" => terminal_id})
    assert render(second) =~ "You control input"

    old_fence = terminal_fence(render(first), terminal_id)
    render_hook(first, "terminal_heartbeat", old_fence)
    assert render(first) =~ "Read only"

    forged = Map.put(terminal_fence(render(second), terminal_id), "repository_id", "forged")
    html = render_hook(second, "terminal_input", Map.put(forged, "data_base64", "QQ=="))
    assert html =~ "Terminal request failed: session_scope_mismatch"

    render_hook(second, "terminal_close", %{"terminal_id" => terminal_id})
    assert_eventually(fn -> terminal_ids(render(second)) == [] end)
  end

  test "terminal bytes stay out of the session journal and default logs", %{conn: conn} do
    session_id = unique_session_id("terminal-content")
    {:ok, view, _html} = live_loaded(conn, session_path(session_id))
    render_hook(view, "terminal_open", %{})
    assert_eventually(fn -> render(view) =~ "sigma-terminal-state is-running" end)
    [terminal_id] = terminal_ids(render(view))

    assert_eventually(fn -> terminal_fence(render(view), terminal_id)["attachment_id"] != nil end)
    fence = terminal_fence(render(view), terminal_id)
    sentinel = "terminal-secret-#{System.unique_integer([:positive])}"

    logs =
      capture_log(fn ->
        render_hook(
          view,
          "terminal_input",
          Map.put(fence, "data_base64", Base.encode64("printf '#{sentinel}\\n'\n"))
        )
      end)

    refute logs =~ sentinel
    storage_path = session_storage_path(session_id)
    refute File.exists?(storage_path) and File.read!(storage_path) =~ sentinel

    render_hook(view, "terminal_close", %{"terminal_id" => terminal_id})
    assert_eventually(fn -> terminal_ids(render(view)) == [] end)
  end

  @tag :tmp_dir
  test "model selector persists the selected model without rewriting legacy metadata", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    with_agent_config(tmp_dir, fn ->
      write_provider_configs("openai", "smart", %{
        "openai" => ["fast", "smart"],
        "anthropic" => ["claude", "opus"]
      })

      session_id = unique_session_id("models")
      sessions_dir = ConfigManager.sessions_dir(@workdir)
      meta_path = Path.join(sessions_dir, "#{session_id}.meta.json")
      storage_path = Path.join(sessions_dir, "#{session_id}.jsonl")
      File.mkdir_p!(sessions_dir)

      meta_bytes =
        Jason.encode!(%{
          "cwd" => @workdir,
          "branch" => "main",
          "provider_id" => "openai",
          "model_id" => "smart"
        })

      File.write!(meta_path, meta_bytes)
      assert :ok = Log.persist_event(storage_path, {:agent_start, @workdir})

      {:ok, view, html} = live_loaded(conn, session_path(session_id))

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

      assert {:ok, snapshot} = Log.snapshot(storage_path)
      assert %{provider_id: "anthropic", model_id: "opus"} = snapshot
      assert File.read!(meta_path) == meta_bytes
    end)
  end

  @tag :tmp_dir
  test "model selector leaves state unchanged when the journal append fails", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    with_agent_config(tmp_dir, fn ->
      write_provider_configs("openai", "smart", %{
        "openai" => ["smart"],
        "anthropic" => ["opus"]
      })

      session_id = unique_session_id("model-write-failure")
      sessions_dir = ConfigManager.sessions_dir(@workdir)
      meta_path = Path.join(sessions_dir, "#{session_id}.meta.json")
      storage_path = Path.join(sessions_dir, "#{session_id}.jsonl")
      File.mkdir_p!(sessions_dir)

      meta_bytes = Jason.encode!(%{"cwd" => @workdir})
      File.write!(meta_path, meta_bytes)
      assert :ok = Log.persist_event(storage_path, {:agent_start, @workdir})

      {:ok, view, html} = live_loaded(conn, session_path(session_id))

      anthropic_value =
        html
        |> Floki.parse_document!()
        |> Floki.find("#model-select option")
        |> Enum.find(&(option_text(&1) == "anthropic: opus"))
        |> Floki.attribute("value")
        |> List.first()

      File.write!(storage_path, "{torn", [:append])

      html = render_change(view, "select_model", %{"model" => anthropic_value})

      assert html =~ "Could not persist model selection."

      selected_option =
        html
        |> Floki.parse_document!()
        |> Floki.find("#model-select option")
        |> Enum.find(&selected?/1)

      assert option_text(selected_option) == "openai: smart"
      assert File.read!(meta_path) == meta_bytes

      settings =
        Sigma.Session.ConfigManager.agent_dir()
        |> Path.join("settings.json")
        |> File.read!()
        |> Jason.decode!()

      assert settings["defaultProvider"] == "openai"
      assert settings["defaultModel"] == "smart"

      agent = Sigma.Agent.Runtime.lookup(@workdir, session_id, :agent)
      assert %{model: %{id: "smart"}} = :sys.get_state(agent)
    end)
  end

  @tag :tmp_dir
  test "restores a legacy sidecar model and migrates its next change", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    with_agent_config(tmp_dir, fn ->
      write_provider_configs("openai", "smart", %{
        "openai" => ["smart"],
        "anthropic" => ["opus"]
      })

      session_id = unique_session_id("session-model")
      sessions_dir = ConfigManager.sessions_dir(@workdir)
      meta_path = Path.join(sessions_dir, "#{session_id}.meta.json")
      File.mkdir_p!(sessions_dir)

      meta_bytes =
        Jason.encode!(%{"cwd" => @workdir, "provider_id" => "anthropic", "model_id" => "opus"})

      File.write!(meta_path, meta_bytes)

      {:ok, view, html} = live_loaded(conn, session_path(session_id))

      selected_option =
        html
        |> Floki.parse_document!()
        |> Floki.find("#model-select option")
        |> Enum.find(&selected?/1)

      assert option_text(selected_option) == "anthropic: opus"
      assert File.read!(meta_path) == meta_bytes

      openai_value =
        html
        |> Floki.parse_document!()
        |> Floki.find("#model-select option")
        |> Enum.find(&(option_text(&1) == "openai: smart"))
        |> Floki.attribute("value")
        |> List.first()

      render_change(view, "select_model", %{"model" => openai_value})

      log_path = Path.join(sessions_dir, "#{session_id}.jsonl")
      assert {:ok, snapshot} = Log.snapshot(log_path)

      assert %{
               header: %{"cwd" => @workdir},
               provider_id: "openai",
               model_id: "smart"
             } = snapshot

      assert File.read!(meta_path) == meta_bytes
    end)
  end

  @tag :tmp_dir
  test "restores journal model before legacy session metadata", %{conn: conn, tmp_dir: tmp_dir} do
    with_agent_config(tmp_dir, fn ->
      write_provider_configs("openai", "smart", %{
        "openai" => ["smart"],
        "anthropic" => ["opus"]
      })

      session_id = unique_session_id("journal-model")
      sessions_dir = ConfigManager.sessions_dir(@workdir)
      meta_path = Path.join(sessions_dir, "#{session_id}.meta.json")
      log_path = Path.join(sessions_dir, "#{session_id}.jsonl")
      File.mkdir_p!(sessions_dir)

      meta_bytes =
        Jason.encode!(%{"cwd" => @workdir, "provider_id" => "openai", "model_id" => "smart"})

      File.write!(meta_path, meta_bytes)

      assert :ok = Log.persist_event(log_path, {:agent_start, @workdir})
      assert {:ok, _entry_id} = Log.append_model_change(log_path, "anthropic", "opus")
      log_bytes = File.read!(log_path)

      {:ok, _view, html} = live_loaded(conn, session_path(session_id))

      selected_option =
        html
        |> Floki.parse_document!()
        |> Floki.find("#model-select option")
        |> Enum.find(&selected?/1)

      assert option_text(selected_option) == "anthropic: opus"
      assert File.read!(meta_path) == meta_bytes
      assert File.read!(log_path) == log_bytes

      settings =
        Sigma.Session.ConfigManager.agent_dir()
        |> Path.join("settings.json")
        |> File.read!()
        |> Jason.decode!()

      assert settings["defaultProvider"] == "openai"
      assert settings["defaultModel"] == "smart"
    end)
  end

  @tag :tmp_dir
  test "does not restore legacy model metadata over an invalid journal model change", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    with_agent_config(tmp_dir, fn ->
      write_provider_configs("openai", "smart", %{
        "openai" => ["smart"],
        "anthropic" => ["opus"]
      })

      session_id = unique_session_id("invalid-journal-model")
      sessions_dir = ConfigManager.sessions_dir(@workdir)
      meta_path = Path.join(sessions_dir, "#{session_id}.meta.json")
      log_path = Path.join(sessions_dir, "#{session_id}.jsonl")
      File.mkdir_p!(sessions_dir)

      File.write!(
        meta_path,
        Jason.encode!(%{"cwd" => @workdir, "provider_id" => "anthropic", "model_id" => "opus"})
      )

      assert :ok = Log.persist_event(log_path, {:agent_start, @workdir})

      assert :ok =
               Sigma.Session.Storage.JsonlFile.append(log_path, %{
                 "type" => "model_change",
                 "id" => "invalid-model",
                 "parentId" => nil,
                 "timestamp" => "2026-08-11T00:00:00Z",
                 "model" => "invalid"
               })

      {:ok, _view, html} = live_loaded(conn, session_path(session_id))

      selected_option =
        html
        |> Floki.parse_document!()
        |> Floki.find("#model-select option")
        |> Enum.find(&selected?/1)

      assert option_text(selected_option) == "openai: smart"
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

          session_id = unique_session_id("model-credential")
          sessions_dir = ConfigManager.sessions_dir(@workdir)
          storage_path = Path.join(sessions_dir, "#{session_id}.jsonl")
          File.mkdir_p!(sessions_dir)
          assert :ok = Log.persist_event(storage_path, {:agent_start, @workdir})

          {:ok, view, html} = live_loaded(conn, session_path(session_id))

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

        assert_eventually(fn ->
          html = render(view)
          html =~ "input: 90000" and html =~ "output: 1" and html =~ "Turn total"
        end)

        assert {:ok, messages} = Sigma.Session.Log.replay(storage_path)
        refute Enum.any?(messages, &(&1.role == :compaction_summary))
      end)
    end)
  end

  @tag :tmp_dir
  test "manual compaction lowers live context while durable usage survives restart", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    with_agent_config(tmp_dir, fn ->
      with_mock_provider(ManualCompactionProvider, fn ->
        write_provider_configs("openai", "smart", %{
          "openai" => [%{"id" => "smart", "contextWindow" => 1_000_000}]
        })

        session_id = unique_session_id("manual-context")
        storage_path = preload_compactable_history(session_id)

        Enum.each(12..23, fn index ->
          content = String.duplicate("long context #{index} ", 500)

          assert :ok =
                   Log.persist_event(
                     storage_path,
                     {:message_end, Message.user("u#{index}", content)}
                   )

          assert :ok =
                   Log.persist_event(
                     storage_path,
                     {:message_end,
                      Message.assistant("a#{index}", %{content: "processed #{index} #{content}"})}
                   )
        end)

        assert :ok =
                 Log.persist_event(
                   storage_path,
                   {:metrics, :request_finished,
                    %{
                      request_id: "historical-request",
                      session_id: session_id,
                      revision: 1,
                      status: :completed,
                      input_tokens_total: 106_976,
                      output_tokens_total: 0,
                      elapsed_ms: 1_000
                    }}
                 )

        Phoenix.PubSub.subscribe(Sigma.Web.PubSub, session_topic(@workdir, session_id))
        {:ok, view, _html} = live_loaded(conn, session_path(session_id))

        {:ok, {agent, _policy}} =
          Sigma.Web.SessionManager.get_agent(session_id, repo_path: @workdir)

        render_submit(view, "send_prompt", %{"value" => "measure before compaction"})
        assert_receive {:agent_end, _messages}, 3_000

        before_context =
          Sigma.Agent.status(agent).context_snapshot.next_request_estimated_input_tokens

        assert is_integer(before_context)
        render_click(view, "compact_session")

        html = render_async(view, 2_000)
        assert html =~ "successful: 1"
        assert html =~ "known total: 207000"

        after_context =
          Sigma.Agent.status(agent).context_snapshot.next_request_estimated_input_tokens

        assert after_context < before_context

        stop_repository_supervisors(@workdir)
        {:ok, _reloaded_view, reloaded_html} = live_loaded(conn, session_path(session_id))
        assert reloaded_html =~ "successful: 1"
        assert reloaded_html =~ "known total: 207000"
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

  test "accepts text and valid PNG from the send hook once", %{conn: conn} do
    session_id = unique_session_id("hook-image")
    Phoenix.PubSub.subscribe(Sigma.Web.PubSub, session_topic(@workdir, session_id))
    {:ok, view, _html} = live_loaded(conn, session_path(session_id))

    render_hook(view, "send_prompt", %{
      "value" => "describe this",
      "images" => [%{"mime_type" => "image/png", "data" => @png_data}]
    })

    assert_reply(view, %{status: "accepted"})
    assert_receive {:message_start, %{role: :user, content: content}}, 2000

    assert [%{type: :text, text: "describe this"}, %{type: :image, mime_type: "image/png"}] =
             content

    refute_receive {:message_start, %{role: :user}}, 200
  end

  test "accepts image-only prompts from the send hook", %{conn: conn} do
    session_id = unique_session_id("hook-image-only")
    Phoenix.PubSub.subscribe(Sigma.Web.PubSub, session_topic(@workdir, session_id))
    {:ok, view, _html} = live_loaded(conn, session_path(session_id))

    render_hook(view, "send_prompt", %{
      "value" => "",
      "images" => [%{"mime_type" => "image/png", "data" => @png_data}]
    })

    assert_reply(view, %{status: "accepted"})

    assert_receive {:message_start,
                    %{role: :user, content: [%{type: :image, mime_type: "image/png"}]}},
                   2000

    refute_receive {:message_start, %{role: :user}}, 200
  end

  test "rejects invalid image data with a trusted flash and no agent", %{conn: conn} do
    session_id = unique_session_id("hook-invalid-image")
    {:ok, view, _html} = live_loaded(conn, session_path(session_id))

    html =
      render_hook(view, "send_prompt", %{
        "value" => "describe this",
        "images" => [%{"mime_type" => "image/png", "data" => "not-base64"}]
      })

    assert_reply(view, %{status: "rejected"})
    assert html =~ "attached images is invalid"
    refute_receive {:agent_start, _}, 200
  end

  test "rejects signature mismatches and slash commands with images", %{conn: conn} do
    session_id = unique_session_id("hook-rejects")
    {:ok, view, _html} = live_loaded(conn, session_path(session_id))

    html =
      render_hook(view, "send_prompt", %{
        "value" => "describe this",
        "images" => [%{"mime_type" => "image/jpeg", "data" => @png_data}]
      })

    assert_reply(view, %{status: "rejected"})
    assert html =~ "attached images is invalid"

    html =
      render_hook(view, "send_prompt", %{
        "value" => "/init",
        "images" => [%{"mime_type" => "image/png", "data" => @png_data}]
      })

    assert_reply(view, %{status: "rejected"})
    assert html =~ "cannot be combined with slash commands"
    refute_receive {:agent_start, _}, 200
  end

  test "maps only bounded attachment errors to trusted flashes", %{conn: conn} do
    {:ok, view, _html} = live_loaded(conn, session_path(unique_session_id("hook-errors")))

    for {code, message} <- [
          {"unsupported_type", "Attach PNG"},
          {"too_many", "no more than four"},
          {"too_large", "at most 5 MiB"},
          {"read_failed", "could not read"},
          {"slash_command", "cannot be combined"}
        ] do
      assert render_hook(view, "attachment_error", %{"code" => code}) =~ message
    end

    html = render_hook(view, "attachment_error", %{"code" => "<script>alert(1)</script>"})
    refute html =~ "<script>"
    refute html =~ "alert(1)"
  end

  test "accepts an empty prompt without starting an agent", %{conn: conn} do
    {:ok, view, _html} = live_loaded(conn, session_path(unique_session_id("hook-empty")))

    render_hook(view, "send_prompt", %{"value" => "   ", "images" => []})
    assert_reply(view, %{status: "accepted"})
    refute_receive {:agent_start, _}, 200
  end

  test "queues prompts while an agent turn is in flight", %{conn: conn} do
    write_selectable_provider_configs()
    session_id = unique_session_id("hook-active-turn")
    Phoenix.PubSub.subscribe(Sigma.Web.PubSub, session_topic(@workdir, session_id))
    Application.put_env(:sigma_web, :blocking_provider_pid, self())
    on_exit(fn -> Application.delete_env(:sigma_web, :blocking_provider_pid) end)

    with_mock_provider(BlockingTurnProvider, fn ->
      {:ok, view, _html} = live_loaded(conn, session_path(session_id))
      render_hook(view, "send_prompt", %{"value" => "first", "images" => []})
      assert_reply(view, %{status: "accepted"})
      assert_receive {:web_provider_waiting, first_provider, "first"}, 1_000

      html = render_hook(view, "send_prompt", %{"value" => "second", "images" => []})
      assert_reply(view, %{status: "queued_as_follow_up"})
      assert html =~ "Prompt queued as follow-up"

      send(first_provider, :release_web_provider)
      assert_receive {:web_provider_waiting, second_provider, "second"}, 1_000
      send(second_provider, :release_web_provider)
    end)
  end

  test "queues a prompt while a retry is in flight", %{conn: conn} do
    write_selectable_provider_configs()
    session_id = unique_session_id("hook-retry-race")
    storage_path = session_storage_path(session_id)
    File.mkdir_p!(Path.dirname(storage_path))

    :ok =
      Sigma.Session.Log.persist_event(
        storage_path,
        {:message_end, Message.user("u_retry_race", "retry me")}
      )

    Phoenix.PubSub.subscribe(Sigma.Web.PubSub, session_topic(@workdir, session_id))

    Application.put_env(:sigma_web, :blocking_provider_pid, self())
    on_exit(fn -> Application.delete_env(:sigma_web, :blocking_provider_pid) end)

    with_mock_provider(BlockingTurnProvider, fn ->
      {:ok, view, _html} = live_loaded(conn, session_path(session_id))

      view
      |> element("#retry-u_retry_race")
      |> render_click()

      assert_receive {:web_provider_waiting, retry_provider, "retry me"}, 1_000
      html = render_hook(view, "send_prompt", %{"value" => "second", "images" => []})
      assert_reply(view, %{status: "queued_as_follow_up"})
      assert html =~ "Prompt queued as follow-up"
      send(retry_provider, :release_web_provider)
      assert_receive {:web_provider_waiting, second_provider, "second"}, 1_000
      send(second_provider, :release_web_provider)
    end)
  end

  test "shows busy errors for switch and fork without navigating or publishing a fork", %{
    conn: conn
  } do
    write_selectable_provider_configs()
    session_id = unique_session_id("busy-session-operation")
    target_id = unique_session_id("switch-target")
    target_path = session_storage_path(target_id)
    File.mkdir_p!(Path.dirname(target_path))
    :ok = Sigma.Session.Log.persist_event(target_path, {:agent_start, @workdir})

    Application.put_env(:sigma_web, :blocking_provider_pid, self())
    on_exit(fn -> Application.delete_env(:sigma_web, :blocking_provider_pid) end)

    with_fork_id_generator(["busy_fork_target"], fn ->
      with_mock_provider(BlockingTurnProvider, fn ->
        {:ok, view, _html} = live_loaded(conn, session_path(session_id))
        render_hook(view, "send_prompt", %{"value" => "working", "images" => []})
        assert_reply(view, %{status: "accepted"})
        assert_receive {:web_provider_waiting, provider, "working"}, 1_000

        html = render_hook(view, "switch_session", %{"session" => target_id})
        assert html =~ "Wait for the active turn to finish before switching sessions."

        html = render_hook(view, "fork_session", %{})
        assert html =~ "Wait for the active turn to finish before forking."
        refute File.exists?(session_storage_path("busy_fork_target"))

        send(provider, :release_web_provider)
      end)
    end)
  end

  test "switches an idle session through the runtime operation boundary", %{conn: conn} do
    session_id = unique_session_id("idle-session-operation")
    target_id = unique_session_id("idle-switch-target")
    target_path = session_storage_path(target_id)
    File.mkdir_p!(Path.dirname(target_path))
    :ok = Sigma.Session.Log.persist_event(target_path, {:agent_start, @workdir})

    {:ok, view, _html} = live_loaded(conn, session_path(session_id))
    expected_path = "/repository/#{@encoded_workdir}/sessions/#{target_id}"

    assert {:error, {:live_redirect, %{to: ^expected_path}}} =
             render_hook(view, "switch_session", %{"session" => target_id})
  end

  @tag :tmp_dir
  test "rejects send while the session is still loading", %{conn: conn, tmp_dir: tmp_dir} do
    with_agent_config(tmp_dir, fn ->
      write_provider_configs("openai", "smart", %{"openai" => ["smart"]})
      trust_workdir!(@workdir)
      write_session_start_hook!(@workdir, "sleep 2", timeout: 3)
      {:ok, view, _html} = live(conn, session_path(unique_session_id("hook-not-ready")))

      html = render_hook(view, "send_prompt", %{"value" => "hello", "images" => []})
      assert_reply(view, %{status: "rejected"})
      assert html =~ "Session is still loading"
      refute_receive {:agent_start, _}, 200
    end)
  end

  test "renders the chat input without generic send handling", %{conn: conn} do
    {:ok, _view, html} = live_loaded(conn, session_path(unique_session_id("chat-input")))

    refute html =~ ~s(clear-on-send="true")
    refute html =~ "duskmoon-send-send"
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
    assert html =~ "Resend"
    refute html =~ ~s(variant="filled")
  end

  test "renders persisted text and image content safely", %{conn: conn} do
    session_id = unique_session_id("persisted-image")
    storage_path = session_storage_path(session_id)
    image = %{type: :image, mime_type: "image/png", data: @png_data}
    content = [%{type: :text, text: "describe this"}, image]
    File.mkdir_p!(Path.dirname(storage_path))
    :ok = Log.persist_event(storage_path, {:message_end, Message.user("u_image", content)})

    {:ok, _view, html} = live_loaded(conn, session_path(session_id))

    assert html =~ "describe this"
    assert html =~ ~s(src="data:image/png;base64,#{@png_data}")
    assert html =~ ~s(alt="Attached image")
    assert html =~ ~s(loading="lazy")
    assert html =~ ~s(decoding="async")

    {:ok, _reloaded_view, reloaded_html} = live_loaded(conn, session_path(session_id))
    assert reloaded_html =~ ~s(src="data:image/png;base64,#{@png_data}")
    assert reloaded_html =~ ~s(loading="lazy")
    assert reloaded_html =~ ~s(decoding="async")
  end

  test "renders image-only persisted messages without a text artifact", %{conn: conn} do
    session_id = unique_session_id("image-only-replay")
    storage_path = session_storage_path(session_id)
    content = [%{type: :image, mime_type: "image/png", data: @png_data}]
    File.mkdir_p!(Path.dirname(storage_path))
    :ok = Log.persist_event(storage_path, {:message_end, Message.user("u_image_only", content)})

    {:ok, _view, html} = live_loaded(conn, session_path(session_id))

    assert html =~ ~s(src="data:image/png;base64,#{@png_data}")
    refute html =~ ~s(content="")
  end

  test "does not render unsafe replayed image blocks", %{conn: conn} do
    session_id = unique_session_id("unsafe-image-replay")
    storage_path = session_storage_path(session_id)
    content = [%{type: :image, mime_type: "image/png", data: "not-base64"}]
    File.mkdir_p!(Path.dirname(storage_path))
    :ok = Log.persist_event(storage_path, {:message_end, Message.user("u_unsafe_image", content)})

    {:ok, _view, html} = live_loaded(conn, session_path(session_id))

    refute html =~ "data:image/png"
    refute html =~ "Attached image"
  end

  test "skips a replayed message with too many images", %{conn: conn} do
    session_id = unique_session_id("too-many-replay-images")
    storage_path = session_storage_path(session_id)
    image = %{type: :image, mime_type: "image/png", data: @png_data}
    content = [%{type: :text, text: "many"} | List.duplicate(image, 5)]
    File.mkdir_p!(Path.dirname(storage_path))
    :ok = Log.persist_event(storage_path, {:message_end, Message.user("u_many_images", content)})

    {:ok, view, html} = live_loaded(conn, session_path(session_id))
    refute html =~ "data:image/png"

    html = view |> element("#retry-u_many_images") |> render_click()
    assert html =~ "Only text or image messages can be retried"
    refute_receive {:agent_start, _}, 200
  end

  test "skips a replayed message whose images exceed the aggregate limit", %{conn: conn} do
    session_id = unique_session_id("large-replay-images")
    storage_path = session_storage_path(session_id)
    bytes = <<137, 80, 78, 71, 13, 10, 26, 10>> <> :binary.copy(<<0>>, 3_000_000 - 8)
    data = Base.encode64(bytes)
    large_image = %{type: :image, mime_type: "image/png", data: data}
    large_images = List.duplicate(large_image, 4)
    File.mkdir_p!(Path.dirname(storage_path))

    :ok =
      Log.persist_event(
        storage_path,
        {:message_end, Message.user("u_large_images", large_images)}
      )

    assert {:ok, messages} = Log.replay(storage_path)
    assert Enum.any?(messages, &(&1.id == "u_large_images" and &1.content == large_images))

    {:ok, view, html} = live_loaded(conn, session_path(session_id))
    refute html =~ "data:image/png"

    html = view |> element("#retry-u_large_images") |> render_click()
    assert html =~ "Only text or image messages can be retried"
    refute_receive {:agent_start, _}, 200
    refute_receive {:message_start, %{role: :user}}, 200
  end

  test "retries persisted text and image content in canonical order", %{conn: conn} do
    session_id = unique_session_id("retry-image")
    storage_path = session_storage_path(session_id)

    content = [
      %{type: :text, text: "retry this"},
      %{type: :image, mime_type: "image/png", data: @png_data}
    ]

    File.mkdir_p!(Path.dirname(storage_path))
    :ok = Log.persist_event(storage_path, {:message_end, Message.user("u_retry_image", content)})
    Phoenix.PubSub.subscribe(Sigma.Web.PubSub, session_topic(@workdir, session_id))

    {:ok, view, _html} = live_loaded(conn, session_path(session_id))
    view |> element("#retry-u_retry_image") |> render_click()

    assert_receive {:message_start, %{role: :user, content: ^content}}, 2000
  end

  test "does not retry a whitespace-only persisted text message", %{conn: conn} do
    session_id = unique_session_id("retry-blank")
    storage_path = session_storage_path(session_id)
    File.mkdir_p!(Path.dirname(storage_path))
    :ok = Log.persist_event(storage_path, {:message_end, Message.user("u_retry_blank", "   ")})
    {:ok, view, _html} = live_loaded(conn, session_path(session_id))

    html = view |> element("#retry-u_retry_blank") |> render_click()

    assert html =~ "Only text or image messages can be retried"
    refute_receive {:agent_start, _}, 200
  end

  test "retries an image when persisted text is only whitespace", %{conn: conn} do
    session_id = unique_session_id("retry-blank-image")
    storage_path = session_storage_path(session_id)

    content = [
      %{type: :text, text: "   "},
      %{type: :image, mime_type: "image/png", data: @png_data}
    ]

    File.mkdir_p!(Path.dirname(storage_path))

    :ok =
      Log.persist_event(
        storage_path,
        {:message_end, Message.user("u_retry_blank_image", content)}
      )

    Phoenix.PubSub.subscribe(Sigma.Web.PubSub, session_topic(@workdir, session_id))
    {:ok, view, _html} = live_loaded(conn, session_path(session_id))

    view |> element("#retry-u_retry_blank_image") |> render_click()

    assert_receive {:message_start,
                    %{
                      role: :user,
                      content: [%{type: :image, mime_type: "image/png", data: @png_data}]
                    }},
                   2000
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

  test "does not infer context size from an assistant message", %{conn: conn} do
    {:ok, view, html} = live_loaded(conn, session_path(unique_session_id("context_size")))

    assert html =~ ~s(id="session-context-size-unknown")
    assert html =~ "Context: unknown"

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
    assert html =~ ~s(id="session-context-size-unknown")
    assert html =~ "Context: unknown"
  end

  test "does not let replayed message usage replace runtime context", %{conn: conn} do
    {:ok, view, _html} =
      live_loaded(conn, session_path(unique_session_id("context_runtime_owned")))

    send(view.pid, {:message_end, assistant_usage_message("large", 12_345)})
    send(view.pid, {:message_end, assistant_usage_message("small", 105)})
    assert render(view) =~ "Context: unknown"
  end

  test "keeps context unknown when journal replay only has message usage", %{conn: conn} do
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

    assert html =~ "Context: unknown"
  end

  test "projects durable metric facts into the live session rail", %{conn: conn} do
    session_id = unique_session_id("live_metrics")
    {:ok, view, _html} = live_loaded(conn, session_path(session_id))

    send(view.pid, {
      :metrics,
      :request_started,
      %{
        request_id: "req_live",
        session_id: session_id,
        revision: 0,
        turn_id: "turn_live"
      }
    })

    send(view.pid, {
      :metrics,
      :request_finished,
      %{
        request_id: "req_live",
        session_id: session_id,
        revision: 1,
        turn_id: "turn_live",
        status: :completed,
        input_tokens_total: 120,
        output_tokens_total: 30,
        elapsed_ms: 1_000
      }
    })

    assert_eventually(fn ->
      html = render(view)
      html =~ "Usage" and html =~ "150" and html =~ "coverage: 1/1"
    end)
  end

  test "restores persisted usage as owned by the logical route session", %{conn: conn} do
    session_id = unique_session_id("persisted_metrics")
    storage_path = session_storage_path(session_id)
    File.mkdir_p!(Path.dirname(storage_path))

    assert :ok = Sigma.Session.Log.persist_event(storage_path, {:agent_start, @workdir})

    assert :ok =
             Sigma.Session.Log.persist_event(
               storage_path,
               {:metrics, :request_finished,
                %{
                  request_id: "persisted-request",
                  session_id: session_id,
                  revision: 1,
                  status: :completed,
                  input_tokens_total: 75,
                  output_tokens_total: 25,
                  elapsed_ms: 1_000
                }}
             )

    {:ok, _view, html} = live_loaded(conn, session_path(session_id))
    assert html =~ "known total: 100"
    refute html =~ "inherited: 100 tokens"
  end

  test "offers checkpoint Retry separately from Resend and requires confirmation", %{conn: conn} do
    session_id = unique_session_id("retry_confirmation")
    storage_path = session_storage_path(session_id)
    File.mkdir_p!(Path.dirname(storage_path))
    user = %{Message.user("retry-user", "try again") | metadata: %{turn_id: "original-turn"}}

    assert :ok = Log.persist_event(storage_path, {:agent_start, @workdir})
    assert :ok = Log.persist_event(storage_path, {:message_end, user})

    assert :ok =
             Log.persist_event(
               storage_path,
               {:message_end, Message.assistant("retry-answer", %{content: "old answer"})}
             )

    {:ok, view, html} = live_loaded(conn, session_path(session_id))
    assert html =~ ~s(id="retry-turn-retry-user")
    assert html =~ ~s(id="retry-retry-user")
    assert Floki.find(Floki.parse_document!(html), "#retry-user.sigma-chat-with-actions") != []

    modal_html = render_click(view, "prepare_retry", %{"msg-id" => "retry-user"})
    assert modal_html =~ ~s(id="retry-turn-modal")
    assert modal_html =~ "Retry once"
    assert modal_html =~ "do not roll back files"

    closed_html = render_click(view, "cancel_retry")
    refute closed_html =~ ~s(id="retry-turn-modal")
  end

  test "Fork requires confirmation and can create without switching", %{conn: conn} do
    session_id = unique_session_id("fork_confirmation")
    target_id = unique_session_id("fork_target")

    with_fork_id_generator([target_id], fn ->
      {:ok, view, _html} = live_loaded(conn, session_path(session_id))

      modal_html = render_click(view, "fork_session")
      assert modal_html =~ ~s(id="fork-session-modal")
      assert modal_html =~ "latest completed turn"
      assert modal_html =~ "Target title"
      assert modal_html =~ "shared workspaces remain shared"

      html =
        render_submit(view, "confirm_fork", %{
          "title" => "Alternative investigation",
          "switch" => "false"
        })

      refute html =~ ~s(id="fork-session-modal")
      assert html =~ "Fork created without starting a model request."

      assert {:ok, meta_path} =
               Sigma.Session.SessionFiles.meta_path(
                 Sigma.Session.ConfigManager.sessions_dir(@workdir),
                 target_id
               )

      assert Jason.decode!(File.read!(meta_path))["title"] == "Alternative investigation"
    end)
  end

  test "confirming Retry navigates and reloads the replacement branch", %{conn: conn} do
    session_id = unique_session_id("retry_branch_reload")
    path = session_path(session_id)
    storage_path = session_storage_path(session_id)
    File.mkdir_p!(Path.dirname(storage_path))

    first = %{Message.user("retry-first", "first prompt") | metadata: %{turn_id: "turn-first"}}

    second = %{
      Message.user("retry-second", "second prompt")
      | metadata: %{turn_id: "turn-second"}
    }

    assert :ok = Log.persist_event(storage_path, {:agent_start, @workdir})
    assert :ok = Log.persist_event(storage_path, {:message_end, first})

    assert :ok =
             Log.persist_event(
               storage_path,
               {:message_end, Message.assistant("first-answer", %{content: "first answer"})}
             )

    assert :ok = Log.persist_event(storage_path, {:message_end, second})

    assert :ok =
             Log.persist_event(
               storage_path,
               {:message_end, Message.assistant("second-answer", %{content: "second answer"})}
             )

    {:ok, view, _html} = live_loaded(conn, path)
    assert render_click(view, "prepare_retry", %{"msg-id" => "retry-first"}) =~ "Retry once"
    render_click(view, "confirm_retry")
    assert_redirect(view, path)

    assert_eventually(fn ->
      case Log.snapshot(storage_path) do
        {:ok, snapshot} ->
          Enum.any?(snapshot.messages, fn message ->
            message.role == :user and
              (message.metadata[:retry_of_turn_id] || message.metadata["retry_of_turn_id"]) ==
                "turn-first"
          end)

        _ ->
          false
      end
    end)

    assert_eventually(fn ->
      case Log.branch_summaries(storage_path) do
        {:ok, [active, original]} ->
          active.active? and active.retry_of_turn_id == "turn-first" and
            get_in(active, [:last_assistant, :text]) == "I am a mock response." and
            not original.active? and
            get_in(original, [:last_assistant, :text]) == "second answer"

        _other ->
          false
      end
    end)

    {:ok, _reloaded_view, reloaded_html} = live_loaded(conn, path)
    assert reloaded_html =~ "first prompt"

    transcript_text =
      reloaded_html
      |> Floki.parse_document!()
      |> Floki.find("#messages")
      |> Floki.text()

    refute transcript_text =~ "second prompt"
    assert reloaded_html =~ "Alternative executions"
    assert reloaded_html =~ "Original execution"
    assert reloaded_html =~ "second answer"
    assert reloaded_html =~ "I am a mock response."
    assert reloaded_html =~ "turn-first"

    assert {:ok, entries} = Sigma.Session.Storage.JsonlFile.read(storage_path)
    assert Enum.any?(entries, &(get_in(&1, ["message", "id"]) == "second-answer"))

    assert Enum.count(entries, fn entry ->
             get_in(entry, ["message", "metadata", "retry_of_turn_id"]) == "turn-first"
           end) == 1
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

    hook_buttons =
      html
      |> Floki.parse_document!()
      |> Floki.find(~s(#ask-user-questions el-dm-button[phx-hook="WebComponentHook"]))

    assert [_cancel_button, _submit_button] = hook_buttons
    assert Enum.all?(hook_buttons, &has_attr?(&1, "id"))

    view
    |> form("#ask-user-questions form", %{
      "selected_answer" => "project",
      "answer" => ""
    })
    |> render_submit()

    assert {:ok, "project"} = Task.await(task)
    refute render(view) =~ "Which setup path should I use?"
  end

  @tag :tmp_dir
  test "guarded permission resolves exactly one LiveView approval for allow and deny", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    write_selectable_provider_configs()

    assert {:ok, _permissions} =
             ConfigManager.update_permissions(%{
               "default" => "allow",
               "rules" => %{"bash" => "ask"}
             })

    with_mock_provider(PermissionToolProvider, fn ->
      allow_target = Path.join(tmp_dir, "allowed")
      Application.put_env(:sigma_web, :permission_test_path, allow_target)
      on_exit(fn -> Application.delete_env(:sigma_web, :permission_test_path) end)

      allow_session_id = unique_session_id("permission-allow")
      {:ok, allow_view, _html} = live_loaded(conn, session_path(allow_session_id))
      render_submit(allow_view, "send_prompt", %{"value" => "run", "images" => []})

      assert_permission_question(allow_view)

      allow_view
      |> form("#ask-user-questions form", %{
        "selected_answer" => "allow_once"
      })
      |> render_submit()

      assert_eventually(fn -> File.read(allow_target) == {:ok, "permitted"} end)
      refute render(allow_view) =~ "Allow bash for this tool call?"

      deny_target = Path.join(tmp_dir, "denied")
      Application.put_env(:sigma_web, :permission_test_path, deny_target)
      deny_session_id = unique_session_id("permission-deny")
      {:ok, deny_view, _html} = live_loaded(conn, session_path(deny_session_id))
      render_submit(deny_view, "send_prompt", %{"value" => "run", "images" => []})

      assert_permission_question(deny_view)

      deny_view
      |> form("#ask-user-questions form", %{
        "selected_answer" => "deny_once"
      })
      |> render_submit()

      Process.sleep(50)
      refute File.exists?(deny_target)
      refute render(deny_view) =~ "Allow bash for this tool call?"
    end)
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
          timeout: 5_000
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
        context_diagnostics: [],
        context_trace: [],
        context_token_count: 0,
        context_window: nil,
        current_model_value: nil,
        effective_cwd: @workdir,
        encoded_repository: @encoded_workdir,
        log_entries: [],
        log_filter: nil,
        log_search: "",
        model_options: [],
        branch_summaries: [],
        pending_mcp_elicitations: [],
        pending_compaction: false,
        pending_fork: nil,
        pending_retry: nil,
        pending_user_questions: [],
        parent_session_id: nil,
        runtime_status: :idle,
        session_id: "render_session",
        session_ready: true,
        sessions: [],
        show_logs: false,
        show_observability: false,
        terminal_attachments: %{},
        terminal_capability: %{status: :available, reason: nil, details: %{}},
        terminal_catalog: %{
          status: :available,
          entries: [],
          retained_count: 0,
          state_counts: %{},
          revision: 0,
          selected_id: nil
        },
        terminal_panel_open: false,
        terminal_pending_creators: MapSet.new(),
        terminal_selected_id: nil,
        terminal_session:
          Sigma.Agent.Terminals.Identity.session(@workdir, "render_session", "test"),
        storage_path: session_storage_path("render_session"),
        streaming_message_id: nil,
        streams: %{messages: []},
        tool_results: %{},
        turn_in_flight: false,
        workdir: @workdir
      },
      Map.new(overrides)
    )
  end

  defp live_loaded(conn, path) do
    {:ok, view, _html} = live(conn, path)
    {:ok, view, render_async(view, 3_000)}
  end

  defp session_topic(workdir, session_id) do
    repo_key = ConfigManager.repository_key(workdir)
    "session:#{repo_key}:#{session_id}"
  end

  defp assert_permission_question(view) do
    assert_eventually(fn -> render(view) =~ "Allow bash for this tool call?" end)
    html = render(view)
    assert html =~ "Allow once"
    assert html =~ "Deny once"
    assert [_one_form] = html |> Floki.parse_document!() |> Floki.find("#ask-user-questions form")
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

  defp terminal_ids(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("[role=tab][data-terminal-id]")
    |> Floki.attribute("data-terminal-id")
  end

  defp selected_terminal_id(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find(~s([role=tab][aria-selected="true"]))
    |> Floki.attribute("data-terminal-id")
    |> List.first()
  end

  defp terminal_fence(html, terminal_id) do
    document = Floki.parse_document!(html)
    [root] = Floki.find(document, "#session-terminal-panel")
    [panel] = Floki.find(document, ~s([role=tabpanel][data-terminal-id="#{terminal_id}"]))

    %{
      "repository_id" => attr(root, "data-terminal-repository"),
      "session_id" => attr(root, "data-terminal-session"),
      "incarnation_id" => attr(root, "data-terminal-incarnation"),
      "terminal_id" => terminal_id,
      "generation" => attr(panel, "data-terminal-generation"),
      "catalog_revision" => attr(root, "data-terminal-catalog-revision"),
      "attachment_id" => attr(panel, "data-terminal-attachment"),
      "control_epoch" => attr(panel, "data-terminal-control-epoch")
    }
  end

  defp attr(node, name), do: node |> Floki.attribute(name) |> List.first()

  defp selected?({_tag, attrs, _children}) do
    Enum.any?(attrs, fn
      {"selected", value} -> value in ["", "true", "selected"]
      _ -> false
    end)
  end
end
