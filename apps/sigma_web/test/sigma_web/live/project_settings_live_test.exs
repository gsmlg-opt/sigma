defmodule Sigma.Web.ProjectSettingsLiveTest do
  use Sigma.Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Sigma.Session.{ConfigManager, RepoManager}

  @tag :tmp_dir
  test "saves project MCP server defaults", %{conn: conn, tmp_dir: tmp_dir} do
    with_agent_dir(tmp_dir, fn ->
      ConfigManager.put_mcp_server("github", %{
        "type" => "stdio",
        "command" => "npx",
        "args" => ["-y", "@modelcontextprotocol/server-github"]
      })

      {:ok, _repo} = RepoManager.add_repo(tmp_dir, name: "Repo")
      encoded_repository = Base.url_encode64(tmp_dir, padding: false)

      {:ok, view, html} = live(conn, "/repository/#{encoded_repository}/settings")
      assert html =~ "New Session"
      assert html =~ "Skills"
      assert html =~ "Session List"
      assert html =~ "Settings"
      refute html =~ "All Repositories"
      assert html =~ ~s(href="/repository/#{encoded_repository}/sessions/new")
      assert html =~ ~s(href="/repository/#{encoded_repository}/skills")
      assert html =~ ~s(href="/repository/#{encoded_repository}")

      assert html =~ "MCP Servers"
      assert html =~ "github"

      render_submit(view, "save", %{
        "name" => "Repo",
        "path" => tmp_dir,
        "mcp_server_ids" => ["github"]
      })

      assert %{"mcp_server_ids" => ["github"]} = RepoManager.get_repo(tmp_dir)
    end)
  end

  @tag :tmp_dir
  test "path update relocates a legacy pi-safe sessions directory", %{conn: conn, tmp_dir: tmp_dir} do
    unique = System.unique_integer([:positive])
    old_path = Path.join(System.tmp_dir!(), "sigma-settings-old-#{unique}")
    new_path = Path.join(System.tmp_dir!(), "sigma-settings-new-#{unique}")

    File.mkdir_p!(old_path)
    File.mkdir_p!(new_path)

    on_exit(fn ->
      File.rm_rf!(old_path)
      File.rm_rf!(new_path)
    end)

    with_agent_dir(tmp_dir, fn ->
      {:ok, _repo} = RepoManager.add_repo(old_path, name: "Repo")

      old_dir = ConfigManager.legacy_sessions_dir(old_path)
      File.mkdir_p!(old_dir)
      File.write!(Path.join(old_dir, "session.jsonl"), "legacy")

      encoded_repository = Base.url_encode64(old_path, padding: false)
      {:ok, view, _html} = live(conn, "/repository/#{encoded_repository}/settings")

      render_submit(view, "save", %{
        "name" => "Repo",
        "path" => new_path
      })

      new_dir = ConfigManager.sessions_dir(new_path)

      assert File.read!(Path.join(new_dir, "session.jsonl")) == "legacy"
      refute File.exists?(old_dir)
      assert %{"path" => ^new_path} = RepoManager.get_repo(new_path)
    end)
  end

  @tag :tmp_dir
  test "path update reports conflict when target legacy sessions directory exists", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    unique = System.unique_integer([:positive])
    old_path = Path.join(System.tmp_dir!(), "sigma-settings-old-#{unique}")
    new_path = Path.join(System.tmp_dir!(), "sigma-settings-new-#{unique}")

    File.mkdir_p!(old_path)
    File.mkdir_p!(new_path)

    on_exit(fn ->
      File.rm_rf!(old_path)
      File.rm_rf!(new_path)
    end)

    with_agent_dir(tmp_dir, fn ->
      {:ok, _repo} = RepoManager.add_repo(old_path, name: "Repo")

      old_dir = ConfigManager.sessions_dir(old_path)
      File.mkdir_p!(old_dir)
      File.write!(Path.join(old_dir, "session.jsonl"), "source")

      target_legacy_dir = ConfigManager.legacy_sessions_dir(new_path)
      File.mkdir_p!(target_legacy_dir)
      File.write!(Path.join(target_legacy_dir, "session.jsonl"), "target")

      encoded_repository = Base.url_encode64(old_path, padding: false)
      {:ok, view, _html} = live(conn, "/repository/#{encoded_repository}/settings")

      html =
        render_submit(view, "save", %{
          "name" => "Repo",
          "path" => new_path
        })

      assert html =~ "Could not save: :sessions_dir_conflict"
      assert File.read!(Path.join(old_dir, "session.jsonl")) == "source"
      assert File.read!(Path.join(target_legacy_dir, "session.jsonl")) == "target"
      refute File.exists?(ConfigManager.sessions_dir(new_path))
      assert %{"path" => ^old_path} = RepoManager.get_repo(old_path)
    end)
  end

  @tag :tmp_dir
  test "path update reports registered target conflict before moving source sessions", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    unique = System.unique_integer([:positive])
    old_path = Path.join(System.tmp_dir!(), "sigma-settings-old-#{unique}")
    new_path = Path.join(System.tmp_dir!(), "sigma-settings-new-#{unique}")

    File.mkdir_p!(old_path)
    File.mkdir_p!(new_path)

    on_exit(fn ->
      File.rm_rf!(old_path)
      File.rm_rf!(new_path)
    end)

    with_agent_dir(tmp_dir, fn ->
      {:ok, _repo} = RepoManager.add_repo(old_path, name: "Repo")
      {:ok, _repo} = RepoManager.add_repo(new_path, name: "Other Repo")

      old_dir = ConfigManager.sessions_dir(old_path)
      File.mkdir_p!(old_dir)
      File.write!(Path.join(old_dir, "session.jsonl"), "source")

      encoded_repository = Base.url_encode64(old_path, padding: false)
      {:ok, view, _html} = live(conn, "/repository/#{encoded_repository}/settings")

      html =
        render_submit(view, "save", %{
          "name" => "Repo",
          "path" => new_path
        })

      assert html =~ "Another repository already uses this directory."
      assert File.read!(Path.join(old_dir, "session.jsonl")) == "source"
      refute File.exists?(ConfigManager.sessions_dir(new_path))
      assert %{"path" => ^old_path} = RepoManager.get_repo(old_path)
    end)
  end

  @tag :tmp_dir
  test "path update rejects overlong target repository key before saving", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    unique = System.unique_integer([:positive])
    old_path = Path.join(System.tmp_dir!(), "sigma-settings-old-#{unique}")

    new_path =
      Path.join(
        [System.tmp_dir!(), "sigma-settings-long-#{unique}"] ++
          List.duplicate("segment", 40)
      )

    File.mkdir_p!(old_path)
    File.mkdir_p!(new_path)

    on_exit(fn ->
      File.rm_rf!(old_path)
      File.rm_rf!(Path.join(System.tmp_dir!(), "sigma-settings-long-#{unique}"))
    end)

    with_agent_dir(tmp_dir, fn ->
      {:ok, _repo} = RepoManager.add_repo(old_path, name: "Repo")

      encoded_repository = Base.url_encode64(old_path, padding: false)
      {:ok, view, _html} = live(conn, "/repository/#{encoded_repository}/settings")

      html =
        render_submit(view, "save", %{
          "name" => "Repo",
          "path" => new_path
        })

      assert html =~ "repository session key is too long"
      assert %{"path" => ^old_path} = RepoManager.get_repo(old_path)
      refute RepoManager.get_repo(new_path)
    end)
  end

  @tag :tmp_dir
  test "path update reports conflict when both source session directories exist", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    unique = System.unique_integer([:positive])
    old_path = Path.join(System.tmp_dir!(), "sigma-settings-old-#{unique}")
    new_path = Path.join(System.tmp_dir!(), "sigma-settings-new-#{unique}")

    File.mkdir_p!(old_path)
    File.mkdir_p!(new_path)

    on_exit(fn ->
      File.rm_rf!(old_path)
      File.rm_rf!(new_path)
    end)

    with_agent_dir(tmp_dir, fn ->
      {:ok, _repo} = RepoManager.add_repo(old_path, name: "Repo")

      old_dir = ConfigManager.sessions_dir(old_path)
      File.mkdir_p!(old_dir)
      File.write!(Path.join(old_dir, "new.jsonl"), "new")

      old_legacy_dir = ConfigManager.legacy_sessions_dir(old_path)
      File.mkdir_p!(old_legacy_dir)
      File.write!(Path.join(old_legacy_dir, "legacy.jsonl"), "legacy")

      encoded_repository = Base.url_encode64(old_path, padding: false)
      {:ok, view, _html} = live(conn, "/repository/#{encoded_repository}/settings")

      html =
        render_submit(view, "save", %{
          "name" => "Repo",
          "path" => new_path
        })

      assert html =~ "Could not save: :multiple_source_sessions_dirs"
      assert File.read!(Path.join(old_dir, "new.jsonl")) == "new"
      assert File.read!(Path.join(old_legacy_dir, "legacy.jsonl")) == "legacy"
      refute File.exists?(ConfigManager.sessions_dir(new_path))
      assert %{"path" => ^old_path} = RepoManager.get_repo(old_path)
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
end
