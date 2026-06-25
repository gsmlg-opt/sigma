defmodule Sigma.Web.ProjectSkillsLiveTest do
  use Sigma.Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Sigma.Session.RepoManager

  @old_file_time {{2000, 1, 1}, {0, 0, 0}}

  @tag :tmp_dir
  test "rejects invalid repository route", %{conn: conn, tmp_dir: tmp_dir} do
    with_agent_dir(tmp_dir, fn ->
      assert {:error,
              {:redirect, %{to: "/", flash: %{"error" => "Repository is not registered."}}}} =
               live(conn, "/repository/not-base64!/skills")
    end)
  end

  @tag :tmp_dir
  test "rejects unregistered repository route", %{conn: conn, tmp_dir: tmp_dir} do
    with_agent_dir(tmp_dir, fn ->
      workdir = Path.join(tmp_dir, "unregistered")
      File.mkdir_p!(workdir)

      skill_dir = Path.join([workdir, ".agents", "skills", "unregistered-only"])
      File.mkdir_p!(skill_dir)
      skill_marker = "UNREGISTERED_SKILL_#{System.unique_integer([:positive])}"
      skill_file = Path.join(skill_dir, "SKILL.md")

      File.write!(
        skill_file,
        """
        ---
        name: unregistered-only
        description: #{skill_marker}
        ---
        Use this skill.
        """
      )

      set_old_file_times!(skill_file)
      old_skill_atime = File.stat!(skill_file).atime
      encoded_repository = Base.url_encode64(workdir, padding: false)
      result = live(conn, "/repository/#{encoded_repository}/skills")

      assert {:error,
              {:redirect, %{to: "/", flash: %{"error" => "Repository is not registered."}}}} =
               result

      refute inspect(result) =~ skill_marker
      assert File.stat!(skill_file).atime == old_skill_atime
    end)
  end

  @tag :tmp_dir
  test "shows repository skills on the project skills page", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    with_agent_dir(tmp_dir, fn ->
      workdir = Path.join(tmp_dir, "registered")
      File.mkdir_p!(workdir)

      {:ok, _repo} = RepoManager.add_repo(workdir, name: "Repo")

      skill_dir = Path.join([workdir, ".agents", "skills", "repo-only"])
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

      encoded_repository = Base.url_encode64(workdir, padding: false)
      {:ok, _view, html} = live(conn, "/repository/#{encoded_repository}/skills")

      assert html =~ "Settings"
      assert html =~ "Skills"
      assert html =~ "New Session"
      assert html =~ "Session List"
      refute html =~ "All Repositories"
      assert html =~ ~s(href="/repository/#{encoded_repository}/settings")
      assert html =~ ~s(href="/repository/#{encoded_repository}/sessions/new")
      assert html =~ ~s(href="/repository/#{encoded_repository}")

      assert html =~ "Repository Skills"
      assert html =~ "repo-only"
      assert html =~ "Repository scoped skill"
      assert html =~ ~s(href="/settings/skills")
    end)
  end

  defp set_old_file_times!(path) do
    :ok = :file.change_time(String.to_charlist(path), @old_file_time, @old_file_time)
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
