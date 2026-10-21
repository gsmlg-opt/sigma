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
      assert length(Floki.find(Floki.parse_document!(html), "[data-hook-event]")) == 14
      assert length(Floki.find(Floki.parse_document!(html), "[data-hook-help]")) == 14
      view |> element("#project-hooks-event-PermissionRequest > summary") |> render_click()
      view |> element("#project-hooks-help-PermissionRequest > summary") |> render_click()

      assert has_element?(
               view,
               "#project-hooks-help-PermissionRequest[open] [data-hook-input-example]"
             )

      assert has_element?(
               view,
               "#project-hooks-help-PermissionRequest [data-hook-output-example]"
             )

      refute File.exists?(ConfigManager.project_hooks_file(workdir))

      hooks_json = ~s({"hooks":{"SessionStart":[]}})
      view |> form("#project-hooks-form", hooks_json: hooks_json) |> render_submit()

      assert File.read!(ConfigManager.project_hooks_file(workdir)) == hooks_json
      refute File.exists?(ConfigManager.project_hooks_file(unregistered_workdir))
    end)
  end

  @tag :tmp_dir
  test "guided project command editing is isolated from global and other project hooks", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    with_agent_dir(tmp_dir, fn ->
      workdir = Path.join(tmp_dir, "registered")
      other_workdir = Path.join(tmp_dir, "other")
      File.mkdir_p!(workdir)
      {:ok, _repo} = RepoManager.add_repo(workdir, name: "Repo")
      global_json = ~s({"hooks":{"Stop":[]},"global":true})
      :ok = ConfigManager.save_hooks_json(ConfigManager.hooks_file(), global_json)
      encoded_repository = Base.url_encode64(workdir, padding: false)
      route = "/repository/#{encoded_repository}/hooks"
      path = ConfigManager.project_hooks_file(workdir)
      {:ok, view, _html} = live(conn, route)

      view |> element("#project-hooks-add-PreToolUse") |> render_click()

      view
      |> form("#project-hooks-command-form",
        command: %{
          command: "echo project",
          matcher: "Bash",
          timeout: "25"
        }
      )
      |> render_submit()

      assert Jason.decode!(File.read!(path))["hooks"]["PreToolUse"] == [
               %{
                 "matcher" => "Bash",
                 "hooks" => [%{"type" => "command", "command" => "echo project", "timeout" => 25}]
               }
             ]

      {:ok, reloaded, html} = live(conn, route)
      assert html =~ "echo project"
      reloaded |> element("#project-hooks-PreToolUse-0-0-remove") |> render_click()
      assert Jason.decode!(File.read!(path))["hooks"]["PreToolUse"] == []
      assert File.read!(ConfigManager.hooks_file()) == global_json
      refute File.exists?(ConfigManager.project_hooks_file(other_workdir))
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
