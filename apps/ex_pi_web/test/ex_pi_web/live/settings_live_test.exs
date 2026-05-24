defmodule PiWeb.SettingsLiveTest do
  use PiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  test "system prompt markdown editor ignores LiveView patches", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/settings/system_prompt")

    assert html =~ ~s(id="system-prompt-editor")
    assert html =~ ~s(phx-update="ignore")
  end

  @tag :tmp_dir
  test "shows globally discovered skills", %{conn: conn, tmp_dir: tmp_dir} do
    global_skills_dir = Path.join([tmp_dir, ".agents", "skills"])
    skill_dir = Path.join(global_skills_dir, "global-skill")
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: global-skill
      description: Global skill description
      ---
      Use this skill.
      """
    )

    previous = Application.get_env(:ex_pi_session, :global_skills_dir)
    Application.put_env(:ex_pi_session, :global_skills_dir, global_skills_dir)

    on_exit(fn ->
      if previous do
        Application.put_env(:ex_pi_session, :global_skills_dir, previous)
      else
        Application.delete_env(:ex_pi_session, :global_skills_dir)
      end
    end)

    {:ok, _view, html} = live(conn, "/settings/skills")

    assert html =~ "Skills"
    assert html =~ "global-skill"
    assert html =~ "Global skill description"
    assert html =~ global_skills_dir
  end
end
