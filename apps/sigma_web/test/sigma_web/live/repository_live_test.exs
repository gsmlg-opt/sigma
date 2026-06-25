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
              {:redirect,
               %{to: "/", flash: %{"error" => "Repository is not registered."}}}} =
               live(conn, "/repository/#{encoded}")
    end)
  end

  @tag :tmp_dir
  test "rejects invalid repository route", %{conn: conn, tmp_dir: tmp_dir} do
    with_agent_dir(tmp_dir, fn ->
      assert {:error,
              {:redirect,
               %{to: "/", flash: %{"error" => "Repository is not registered."}}}} =
               live(conn, "/repository/not-base64!")
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
end
