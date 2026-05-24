defmodule PiWeb.RepositoryLiveTest do
  use PiWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @tag :tmp_dir
  test "shows only repository skills with a link to global skills", %{
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

    assert html =~ "Repository Skills"
    assert html =~ "repo-only"
    assert html =~ "Repository scoped skill"
    assert html =~ ~s(href="/settings/skills")
  end
end
