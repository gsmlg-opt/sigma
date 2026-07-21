defmodule Sigma.Web.NewSessionLiveTest do
  use Sigma.Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Sigma.Session.{ConfigManager, RepoManager}
  alias Sigma.Session.Storage.JsonlFile

  @tag :tmp_dir
  test "rejects unregistered repository route", %{conn: conn, tmp_dir: tmp_dir} do
    with_agent_dir(tmp_dir, fn ->
      path = System.tmp_dir!()
      encoded = Base.url_encode64(path, padding: false)

      assert {:error,
              {:redirect, %{to: "/", flash: %{"error" => "Repository is not registered."}}}} =
               live(conn, "/repository/#{encoded}/sessions/new")
    end)
  end

  @tag :tmp_dir
  test "rejects invalid repository route", %{conn: conn, tmp_dir: tmp_dir} do
    with_agent_dir(tmp_dir, fn ->
      assert {:error,
              {:redirect, %{to: "/", flash: %{"error" => "Repository is not registered."}}}} =
               live(conn, "/repository/not-base64!/sessions/new")
    end)
  end

  @tag :tmp_dir
  test "disconnected mount does not run git discovery", %{tmp_dir: tmp_dir} do
    repo = Path.join(tmp_dir, "repo")
    File.mkdir_p!(repo)

    with_agent_dir(tmp_dir, fn ->
      {:ok, _repo} = RepoManager.add_repo(repo, name: "Repo")

      with_fake_git(tmp_dir, fn git_log ->
        encoded_repository = Base.url_encode64(repo, padding: false)
        socket = %Phoenix.LiveView.Socket{}

        assert {:ok, socket} =
                 Sigma.Web.NewSessionLive.mount(
                   %{"repository" => encoded_repository},
                   %{},
                   socket
                 )

        refute File.exists?(git_log)
        assert socket.assigns.session_options_loading
      end)
    end)
  end

  @tag :tmp_dir
  test "defaults new sessions to project MCP servers and allows disabling", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    workdir =
      Path.join(System.tmp_dir!(), "sigma-new-session-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workdir)

    on_exit(fn -> File.rm_rf!(workdir) end)

    with_agent_dir(tmp_dir, fn ->
      ConfigManager.put_mcp_server("github", %{"type" => "stdio", "command" => "npx"})
      {:ok, _repo} = RepoManager.add_repo(workdir, name: "Repo")
      {:ok, _repo} = RepoManager.set_mcp_server_ids(workdir, ["github"])

      encoded_repository = Base.url_encode64(workdir, padding: false)
      {:ok, view, html} = live(conn, "/repository/#{encoded_repository}/sessions/new")

      assert html =~ "New Session"
      assert html =~ "Skills"
      assert html =~ "Session List"
      assert html =~ "Settings"
      refute html =~ "All Repositories"
      assert html =~ ~s(href="/repository/#{encoded_repository}")
      assert html =~ ~s(href="/repository/#{encoded_repository}/settings")
      assert html =~ ~s(href="/repository/#{encoded_repository}/skills")
      assert html =~ "Loading session options"

      html = render_async(view, 1_000)
      assert html =~ "MCP Servers"
      assert html =~ "github"
      assert html =~ ~s(value="github" checked)

      render_change(view, "select_mcp_servers", %{})
      render_click(view, "create_session")

      [meta_path] = Path.wildcard(Path.join(ConfigManager.sessions_dir(workdir), "*.meta.json"))
      session_id = Path.basename(meta_path, ".meta.json")
      log_path = Path.join(ConfigManager.sessions_dir(workdir), "#{session_id}.jsonl")

      assert %{"mcp_server_ids" => []} = meta_path |> File.read!() |> Jason.decode!()
      assert {:ok, [%{"type" => "session", "cwd" => ^workdir}]} = JsonlFile.read(log_path)

      {:ok, session_view, _session_html} =
        live(conn, "/repository/#{encoded_repository}/sessions/#{session_id}")

      session_html = render_async(session_view, 1_000)
      menu_token = Base.url_encode64(session_id, padding: false)
      assert session_html =~ ~s(id="session-menu-btn-#{menu_token}")
    end)
  end

  @tag :tmp_dir
  test "stores selected model in new session metadata", %{conn: conn, tmp_dir: tmp_dir} do
    workdir =
      Path.join(System.tmp_dir!(), "sigma-new-session-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workdir)

    on_exit(fn -> File.rm_rf!(workdir) end)

    with_agent_dir(tmp_dir, fn ->
      write_provider_configs("openai", "smart", %{
        "openai" => ["fast", "smart"],
        "anthropic" => ["claude", "opus"]
      })

      {:ok, _repo} = RepoManager.add_repo(workdir, name: "Repo")
      encoded_repository = Base.url_encode64(workdir, padding: false)

      {:ok, view, _html} = live(conn, "/repository/#{encoded_repository}/sessions/new")
      html = render_async(view, 1_000)

      options = Floki.parse_document!(html) |> Floki.find("#session-model-select option")

      assert Enum.map(options, &option_text/1) == [
               "openai: fast",
               "openai: smart",
               "anthropic: claude",
               "anthropic: opus"
             ]

      anthropic_value =
        options
        |> Enum.find(&(option_text(&1) == "anthropic: opus"))
        |> Floki.attribute("value")
        |> List.first()

      render_change(view, "select_model", %{"model" => anthropic_value})
      assert {:error, {:live_redirect, %{kind: :push}}} = render_click(view, "create_session")

      [meta_path] = Path.wildcard(Path.join(ConfigManager.sessions_dir(workdir), "*.meta.json"))

      assert %{"provider_id" => "anthropic", "model_id" => "opus"} =
               meta_path |> File.read!() |> Jason.decode!()
    end)
  end

  @tag :tmp_dir
  test "rejects invalid worktree names", %{conn: conn, tmp_dir: tmp_dir} do
    workdir =
      Path.join(System.tmp_dir!(), "sigma-new-session-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workdir)
    init_git_repo!(workdir)

    on_exit(fn -> File.rm_rf!(workdir) end)

    with_agent_dir(tmp_dir, fn ->
      {:ok, _repo} = RepoManager.add_repo(workdir, name: "Repo")
      encoded_repository = Base.url_encode64(workdir, padding: false)
      sessions_dir = ConfigManager.sessions_dir(workdir)

      {:ok, view, _html} = live(conn, "/repository/#{encoded_repository}/sessions/new")
      render_async(view, 1_000)

      render_click(view, "set_mode", %{"mode" => "create_worktree"})
      render_change(view, "update_worktree_name", %{"worktree_name" => "../escape"})

      rendered = render_click(view, "create_session")
      assert is_binary(rendered)
      assert rendered =~ "Invalid worktree name"
      assert [] = Path.wildcard(Path.join(sessions_dir, "*.meta.json"))
      assert [] = Path.wildcard(Path.join(sessions_dir, "*.jsonl"))
    end)
  end

  @tag :tmp_dir
  test "rejects worktree creation without a selected branch", %{conn: conn, tmp_dir: tmp_dir} do
    workdir =
      Path.join(System.tmp_dir!(), "sigma-new-session-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workdir)

    on_exit(fn -> File.rm_rf!(workdir) end)

    with_agent_dir(tmp_dir, fn ->
      {:ok, _repo} = RepoManager.add_repo(workdir, name: "Repo")
      encoded_repository = Base.url_encode64(workdir, padding: false)
      sessions_dir = ConfigManager.sessions_dir(workdir)

      {:ok, view, _html} = live(conn, "/repository/#{encoded_repository}/sessions/new")
      render_async(view, 1_000)

      render_click(view, "set_mode", %{"mode" => "create_worktree"})
      render_change(view, "update_worktree_name", %{"worktree_name" => "feature-worktree"})

      rendered = render_click(view, "create_session")
      assert is_binary(rendered)
      assert rendered =~ "Select a branch before creating a worktree"
      assert [] = Path.wildcard(Path.join(sessions_dir, "*.meta.json"))
      assert [] = Path.wildcard(Path.join(sessions_dir, "*.jsonl"))
    end)
  end

  @tag :tmp_dir
  test "rejects forged worktree branches", %{conn: conn, tmp_dir: tmp_dir} do
    workdir =
      Path.join(System.tmp_dir!(), "sigma-new-session-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workdir)
    init_git_repo!(workdir)

    on_exit(fn -> File.rm_rf!(workdir) end)

    with_agent_dir(tmp_dir, fn ->
      {:ok, _repo} = RepoManager.add_repo(workdir, name: "Repo")
      encoded_repository = Base.url_encode64(workdir, padding: false)
      sessions_dir = ConfigManager.sessions_dir(workdir)

      {:ok, view, _html} = live(conn, "/repository/#{encoded_repository}/sessions/new")
      render_async(view, 1_000)

      render_change(view, "select_branch", %{"branch" => "forged-branch"})
      render_click(view, "set_mode", %{"mode" => "create_worktree"})
      render_change(view, "update_worktree_name", %{"worktree_name" => "feature-worktree"})

      rendered = render_click(view, "create_session")
      assert is_binary(rendered)
      assert rendered =~ "Select a valid branch before creating a worktree"
      assert [] = Path.wildcard(Path.join(sessions_dir, "*.meta.json"))
      assert [] = Path.wildcard(Path.join(sessions_dir, "*.jsonl"))
      refute File.exists?(Path.join([workdir, ".trees", "feature-worktree"]))
    end)
  end

  @tag :tmp_dir
  test "rejects stale worktree branches before creating the worktree root", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    workdir =
      Path.join(System.tmp_dir!(), "sigma-new-session-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workdir)
    init_git_repo!(workdir)
    run_git!(workdir, ["branch", "stale-branch"])

    on_exit(fn -> File.rm_rf!(workdir) end)

    with_agent_dir(tmp_dir, fn ->
      {:ok, _repo} = RepoManager.add_repo(workdir, name: "Repo")
      encoded_repository = Base.url_encode64(workdir, padding: false)
      sessions_dir = ConfigManager.sessions_dir(workdir)
      worktree_path = Path.join([workdir, ".trees", "stale-worktree"])

      {:ok, view, _html} = live(conn, "/repository/#{encoded_repository}/sessions/new")
      render_async(view, 1_000)

      render_change(view, "select_branch", %{"branch" => "stale-branch"})
      render_click(view, "set_mode", %{"mode" => "create_worktree"})
      render_change(view, "update_worktree_name", %{"worktree_name" => "stale-worktree"})

      run_git!(workdir, ["branch", "-D", "stale-branch"])

      rendered = render_click(view, "create_session")
      assert is_binary(rendered)
      assert rendered =~ "Select a valid branch before creating a worktree"
      assert [] = Path.wildcard(Path.join(sessions_dir, "*.meta.json"))
      assert [] = Path.wildcard(Path.join(sessions_dir, "*.jsonl"))
      refute File.exists?(Path.join(workdir, ".trees"))
      refute File.exists?(worktree_path)
    end)
  end

  @tag :tmp_dir
  test "existing worktree selector form has a recovery id", %{conn: conn, tmp_dir: tmp_dir} do
    workdir =
      Path.join(System.tmp_dir!(), "sigma-new-session-#{System.unique_integer([:positive])}")

    worktree_path = Path.join([workdir, ".trees", "feature-existing"])

    File.mkdir_p!(workdir)
    init_git_repo!(workdir)
    run_git!(workdir, ["branch", "feature-existing"])
    run_git!(workdir, ["worktree", "add", worktree_path, "feature-existing"])

    on_exit(fn -> File.rm_rf!(workdir) end)

    with_agent_dir(tmp_dir, fn ->
      {:ok, _repo} = RepoManager.add_repo(workdir, name: "Repo")
      encoded_repository = Base.url_encode64(workdir, padding: false)

      {:ok, view, _html} = live(conn, "/repository/#{encoded_repository}/sessions/new")
      render_async(view, 1_000)

      html = render_click(view, "set_mode", %{"mode" => "existing_worktree"})
      assert html =~ ~s(id="worktree-select-form")
    end)
  end

  @tag :tmp_dir
  test "failed git worktree creation does not write session files", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    workdir =
      Path.join(System.tmp_dir!(), "sigma-new-session-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workdir)
    init_git_repo!(workdir)

    on_exit(fn -> File.rm_rf!(workdir) end)

    with_agent_dir(tmp_dir, fn ->
      {:ok, _repo} = RepoManager.add_repo(workdir, name: "Repo")
      encoded_repository = Base.url_encode64(workdir, padding: false)
      sessions_dir = ConfigManager.sessions_dir(workdir)

      {:ok, view, _html} = live(conn, "/repository/#{encoded_repository}/sessions/new")
      render_async(view, 1_000)

      render_click(view, "set_mode", %{"mode" => "create_worktree"})
      render_change(view, "update_worktree_name", %{"worktree_name" => "feature-worktree"})

      rendered = render_click(view, "create_session")
      assert is_binary(rendered)
      assert rendered =~ "Failed to create worktree"
      assert [] = Path.wildcard(Path.join(sessions_dir, "*.meta.json"))
      assert [] = Path.wildcard(Path.join(sessions_dir, "*.jsonl"))
    end)
  end

  @tag :tmp_dir
  test "creates worktree sessions with metadata and log cwd", %{conn: conn, tmp_dir: tmp_dir} do
    workdir =
      Path.join(System.tmp_dir!(), "sigma-new-session-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workdir)
    init_git_repo!(workdir)
    run_git!(workdir, ["branch", "feature-success"])

    on_exit(fn -> File.rm_rf!(workdir) end)

    with_agent_dir(tmp_dir, fn ->
      {:ok, _repo} = RepoManager.add_repo(workdir, name: "Repo")
      encoded_repository = Base.url_encode64(workdir, padding: false)
      sessions_dir = ConfigManager.sessions_dir(workdir)
      worktree_path = Path.join([workdir, ".trees", "feature-success-worktree"])

      {:ok, view, _html} = live(conn, "/repository/#{encoded_repository}/sessions/new")
      render_async(view, 1_000)

      render_change(view, "select_branch", %{"branch" => "feature-success"})
      html = render_click(view, "set_mode", %{"mode" => "create_worktree"})
      assert html =~ ~s(id="worktree-name-form")

      render_change(view, "update_worktree_name", %{"worktree_name" => "feature-success-worktree"})

      assert {:error, {:live_redirect, %{kind: :push}}} = render_click(view, "create_session")
      assert File.dir?(worktree_path)

      [meta_path] = Path.wildcard(Path.join(sessions_dir, "*.meta.json"))
      session_id = Path.basename(meta_path, ".meta.json")
      log_path = Path.join(sessions_dir, "#{session_id}.jsonl")

      assert %{"cwd" => ^worktree_path, "worktree" => true} =
               meta_path |> File.read!() |> Jason.decode!()

      assert {:ok, [%{"type" => "session", "cwd" => ^worktree_path}]} = JsonlFile.read(log_path)
    end)
  end

  @tag :tmp_dir
  test "rejects symlinked worktree roots", %{conn: conn, tmp_dir: tmp_dir} do
    workdir =
      Path.join(System.tmp_dir!(), "sigma-new-session-#{System.unique_integer([:positive])}")

    target_dir =
      Path.join(System.tmp_dir!(), "sigma-worktree-target-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workdir)
    File.mkdir_p!(target_dir)
    init_git_repo!(workdir)
    run_git!(workdir, ["branch", "feature-symlink"])
    File.ln_s!(target_dir, Path.join(workdir, ".trees"))

    on_exit(fn ->
      File.rm_rf!(workdir)
      File.rm_rf!(target_dir)
    end)

    with_agent_dir(tmp_dir, fn ->
      {:ok, _repo} = RepoManager.add_repo(workdir, name: "Repo")
      encoded_repository = Base.url_encode64(workdir, padding: false)
      sessions_dir = ConfigManager.sessions_dir(workdir)

      {:ok, view, _html} = live(conn, "/repository/#{encoded_repository}/sessions/new")
      render_async(view, 1_000)

      render_change(view, "select_branch", %{"branch" => "feature-symlink"})
      render_click(view, "set_mode", %{"mode" => "create_worktree"})
      render_change(view, "update_worktree_name", %{"worktree_name" => "symlink-worktree"})

      rendered = render_click(view, "create_session")
      assert is_binary(rendered)
      assert rendered =~ "Invalid worktree root"
      assert [] = Path.wildcard(Path.join(sessions_dir, "*.meta.json"))
      assert [] = Path.wildcard(Path.join(sessions_dir, "*.jsonl"))
      refute File.exists?(Path.join(target_dir, "symlink-worktree"))
    end)
  end

  @tag :tmp_dir
  test "rejects symlinked final worktree paths", %{conn: conn, tmp_dir: tmp_dir} do
    workdir =
      Path.join(System.tmp_dir!(), "sigma-new-session-#{System.unique_integer([:positive])}")

    target_dir =
      Path.join(System.tmp_dir!(), "sigma-worktree-target-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workdir)
    File.mkdir_p!(target_dir)
    init_git_repo!(workdir)
    run_git!(workdir, ["branch", "feature-final-symlink"])
    File.mkdir_p!(Path.join(workdir, ".trees"))
    File.ln_s!(target_dir, Path.join([workdir, ".trees", "safe-name"]))

    on_exit(fn ->
      File.rm_rf!(workdir)
      File.rm_rf!(target_dir)
    end)

    with_agent_dir(tmp_dir, fn ->
      {:ok, _repo} = RepoManager.add_repo(workdir, name: "Repo")
      encoded_repository = Base.url_encode64(workdir, padding: false)
      sessions_dir = ConfigManager.sessions_dir(workdir)

      {:ok, view, _html} = live(conn, "/repository/#{encoded_repository}/sessions/new")
      render_async(view, 1_000)

      render_change(view, "select_branch", %{"branch" => "feature-final-symlink"})
      render_click(view, "set_mode", %{"mode" => "create_worktree"})
      render_change(view, "update_worktree_name", %{"worktree_name" => "safe-name"})

      rendered = render_click(view, "create_session")
      assert is_binary(rendered)
      assert rendered =~ "Invalid worktree path"
      assert [] = Path.wildcard(Path.join(sessions_dir, "*.meta.json"))
      assert [] = Path.wildcard(Path.join(sessions_dir, "*.jsonl"))
      refute File.exists?(Path.join(target_dir, ".git"))
      refute File.exists?(Path.join(target_dir, "README.md"))
    end)
  end

  defp with_agent_dir(tmp_dir, fun) do
    previous = Application.get_env(:sigma_session, :agent_dir)
    Application.put_env(:sigma_session, :agent_dir, Path.join(tmp_dir, "agent"))

    try do
      fun.()
    after
      if previous do
        Application.put_env(:sigma_session, :agent_dir, previous)
      else
        Application.delete_env(:sigma_session, :agent_dir)
      end
    end
  end

  defp with_fake_git(tmp_dir, fun) do
    bin_dir = Path.join(tmp_dir, "bin")
    File.mkdir_p!(bin_dir)
    git_log = Path.join(tmp_dir, "git.log")
    git_path = Path.join(bin_dir, "git")

    File.write!(git_path, """
    #!/bin/sh
    echo "$@" >> "#{git_log}"
    exit 0
    """)

    File.chmod!(git_path, 0o755)
    previous_path = System.get_env("PATH")
    System.put_env("PATH", "#{bin_dir}:#{previous_path}")

    try do
      fun.(git_log)
    after
      if previous_path do
        System.put_env("PATH", previous_path)
      else
        System.delete_env("PATH")
      end
    end
  end

  defp init_git_repo!(workdir) do
    run_git!(workdir, ["init", "-b", "main"])
    run_git!(workdir, ["config", "user.email", "sigma@example.com"])
    run_git!(workdir, ["config", "user.name", "Sigma Test"])
    File.write!(Path.join(workdir, "README.md"), "# Test repo\n")
    run_git!(workdir, ["add", "README.md"])
    run_git!(workdir, ["commit", "-m", "initial commit"])
  end

  defp run_git!(workdir, args) do
    case System.cmd("git", args, cd: workdir, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end

  defp write_provider_configs(default_provider_id, default_model, providers) do
    agent_dir = ConfigManager.agent_dir()
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

  defp option_text(option) do
    option
    |> Floki.text()
    |> String.trim()
  end
end
