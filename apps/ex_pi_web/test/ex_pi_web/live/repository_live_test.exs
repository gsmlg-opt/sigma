defmodule PiWeb.RepositoryLiveTest do
  use PiWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @tag :tmp_dir
  test "renders sessions without embedding repository skills", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
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
      File.rm_rf(PiSession.ConfigManager.sessions_dir(tmp_dir))
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
  end

  defp assert_sidebar_order(html) do
    assert :binary.match(html, "project-sidebar-settings") <
             :binary.match(html, "project-sidebar-skills")

    assert :binary.match(html, "project-sidebar-skills") <
             :binary.match(html, "project-sidebar-new-session")

    assert :binary.match(html, "project-sidebar-new-session") <
             :binary.match(html, "project-sidebar-session-list")
  end
end
