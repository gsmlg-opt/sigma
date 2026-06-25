defmodule Sigma.Web.RepositoryLiveTest do
  use Sigma.Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Sigma.Session.{ConfigManager, RepoManager}

  @tag :tmp_dir
  test "renders sessions without embedding repository skills", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    with_agent_dir(tmp_dir, fn ->
      {:ok, _repo} = RepoManager.add_repo(tmp_dir, name: "Repo")

      skill_dir = Path.join([tmp_dir, ".agents", "skills", "repo-only"])
      File.mkdir_p!(skill_dir)

      File.write!(
        Path.join(skill_dir, "SKILL.md"),
        """
        ---
        name: repo-only
        description: Repository scoped skill
        ---
        Use this skill.
        """
      )

      encoded_repository = Base.url_encode64(tmp_dir, padding: false)

      on_exit(fn ->
        File.rm_rf(ConfigManager.sessions_dir(tmp_dir))
      end)

      {:ok, _view, html} = live(conn, "/repository/#{encoded_repository}")

      assert html =~ "Settings"
      assert html =~ "Skills"
      assert html =~ "New Session"
      assert html =~ "Session List"
      refute html =~ "All Repositories"
      assert_sidebar_order(html)
      assert html =~ ~s(href="/repository/#{encoded_repository}/settings")
      assert html =~ ~s(href="/repository/#{encoded_repository}/skills")
      assert html =~ ~s(href="/repository/#{encoded_repository}/sessions/new")

      assert html =~ "Sessions"
      refute html =~ "Repository Skills"
      refute html =~ "repo-only"
      refute html =~ "Repository scoped skill"
    end)
  end

  @tag :tmp_dir
  test "rejects unregistered repository route", %{conn: conn, tmp_dir: tmp_dir} do
    with_agent_dir(tmp_dir, fn ->
      path = System.tmp_dir!()
      encoded = Base.url_encode64(path, padding: false)

      assert {:error,
              {:redirect, %{to: "/", flash: %{"error" => "Repository is not registered."}}}} =
               live(conn, "/repository/#{encoded}")
    end)
  end

  @tag :tmp_dir
  test "rejects invalid repository route", %{conn: conn, tmp_dir: tmp_dir} do
    with_agent_dir(tmp_dir, fn ->
      assert {:error,
              {:redirect, %{to: "/", flash: %{"error" => "Repository is not registered."}}}} =
               live(conn, "/repository/not-base64!")
    end)
  end

  @tag :tmp_dir
  test "deleting a session removes its log and metadata and refreshes the list", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    workdir = tmp_workdir!("repository-delete")
    on_exit(fn -> File.rm_rf!(workdir) end)

    with_agent_dir(tmp_dir, fn ->
      {:ok, _repo} = RepoManager.add_repo(workdir, name: "Repo")

      sessions_dir = ConfigManager.sessions_dir(workdir)
      write_session_files!(sessions_dir, "delete-me")
      write_session_files!(sessions_dir, "keep-me")

      encoded_repository = Base.url_encode64(workdir, padding: false)
      {:ok, view, html} = live(conn, "/repository/#{encoded_repository}")

      assert html =~ "delete-me"
      assert html =~ "keep-me"

      render_click(view, "delete_session", %{"id" => "delete-me"})
      assert render(view) =~ ~s(id="delete-session-modal")

      html = render_click(view, "confirm_delete")

      assert html =~ "Session deleted successfully."
      refute File.exists?(Path.join(sessions_dir, "delete-me.jsonl"))
      refute File.exists?(Path.join(sessions_dir, "delete-me.meta.json"))
      assert File.exists?(Path.join(sessions_dir, "keep-me.jsonl"))
      assert File.exists?(Path.join(sessions_dir, "keep-me.meta.json"))

      html = render(view)
      refute html =~ "delete-me"
      refute html =~ ~s(id="delete-session-modal")
      assert html =~ "keep-me"
    end)
  end

  @tag :tmp_dir
  test "forged traversal delete id does not remove outside files and clears modal", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    workdir = tmp_workdir!("repository-forged-delete")
    on_exit(fn -> File.rm_rf!(workdir) end)

    with_agent_dir(tmp_dir, fn ->
      {:ok, _repo} = RepoManager.add_repo(workdir, name: "Repo")

      sessions_dir = ConfigManager.sessions_dir(workdir)
      write_session_files!(sessions_dir, "safe-session")

      outside_path = Path.join(Path.dirname(sessions_dir), "outside.jsonl")
      File.write!(outside_path, "outside\n")

      encoded_repository = Base.url_encode64(workdir, padding: false)
      {:ok, view, _html} = live(conn, "/repository/#{encoded_repository}")

      render_click(view, "delete_session", %{"id" => "../outside"})
      assert render(view) =~ ~s(id="delete-session-modal")

      html = render_click(view, "confirm_delete")

      assert html =~ "Could not delete session"
      assert File.exists?(outside_path)
      assert File.exists?(Path.join(sessions_dir, "safe-session.jsonl"))
      assert File.exists?(Path.join(sessions_dir, "safe-session.meta.json"))

      html = render(view)
      refute html =~ ~s(id="delete-session-modal")
      assert html =~ "safe-session"
    end)
  end

  defp assert_sidebar_order(html) do
    assert :binary.match(html, "project-sidebar-settings") <
             :binary.match(html, "project-sidebar-skills")

    assert :binary.match(html, "project-sidebar-skills") <
             :binary.match(html, "project-sidebar-new-session")

    assert :binary.match(html, "project-sidebar-new-session") <
             :binary.match(html, "project-sidebar-session-list")
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

  defp write_session_files!(sessions_dir, id) do
    File.mkdir_p!(sessions_dir)
    File.write!(Path.join(sessions_dir, "#{id}.jsonl"), "{}\n")

    File.write!(
      Path.join(sessions_dir, "#{id}.meta.json"),
      Jason.encode!(%{"cwd" => "/tmp/repo"})
    )
  end

  defp tmp_workdir!(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end
end
