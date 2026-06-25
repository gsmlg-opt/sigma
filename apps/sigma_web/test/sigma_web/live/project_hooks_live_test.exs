defmodule Sigma.Web.ProjectHooksLiveTest do
  use Sigma.Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Sigma.Session.{ConfigManager, RepoManager}

  @old_file_time {{2000, 1, 1}, {0, 0, 0}}

  @tag :tmp_dir
  test "rejects invalid repository route", %{conn: conn, tmp_dir: tmp_dir} do
    with_agent_dir(tmp_dir, fn ->
      assert {:error,
              {:redirect, %{to: "/", flash: %{"error" => "Repository is not registered."}}}} =
               live(conn, "/repository/not-base64!/hooks")
    end)
  end

  @tag :tmp_dir
  test "rejects unregistered repository route without writing hooks file", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    with_agent_dir(tmp_dir, fn ->
      workdir = Path.join(tmp_dir, "unregistered")
      File.mkdir_p!(workdir)

      hooks_file = ConfigManager.project_hooks_file(workdir)
      hooks_marker = "UNREGISTERED_HOOKS_#{System.unique_integer([:positive])}"
      File.mkdir_p!(Path.dirname(hooks_file))
      File.write!(hooks_file, ~s({"hooks":{"#{hooks_marker}":[]}}))
      set_old_file_times!(hooks_file)
      old_hooks_atime = File.stat!(hooks_file).atime

      encoded_repository = Base.url_encode64(workdir, padding: false)

      result = live(conn, "/repository/#{encoded_repository}/hooks")

      assert {:error,
              {:redirect, %{to: "/", flash: %{"error" => "Repository is not registered."}}}} =
               result

      refute inspect(result) =~ hooks_marker
      assert File.stat!(hooks_file).atime == old_hooks_atime
    end)
  end

  @tag :tmp_dir
  test "saving project hooks writes under the registered repository path", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    with_agent_dir(tmp_dir, fn ->
      workdir = Path.join(tmp_dir, "registered")
      unregistered_workdir = Path.join(tmp_dir, "unregistered")
      File.mkdir_p!(workdir)
      File.mkdir_p!(unregistered_workdir)

      {:ok, _repo} = RepoManager.add_repo(workdir, name: "Repo")

      encoded_repository = Base.url_encode64(workdir, padding: false)
      {:ok, view, html} = live(conn, "/repository/#{encoded_repository}/hooks")

      assert html =~ "Project Hooks"
      assert html =~ ConfigManager.project_hooks_file(workdir)

      hooks_json = ~s({"hooks":{"SessionStart":[]}})
      render_submit(view, "save_hooks", %{"hooks_json" => hooks_json})

      assert File.read!(ConfigManager.project_hooks_file(workdir)) == hooks_json
      refute File.exists?(ConfigManager.project_hooks_file(unregistered_workdir))
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
