defmodule PiWeb.NewSessionLiveTest do
  use PiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PiSession.{ConfigManager, RepoManager}
  alias PiSession.Storage.JsonlFile

  @tag :tmp_dir
  test "defaults new sessions to project MCP servers and allows disabling", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    with_agent_dir(tmp_dir, fn ->
      ConfigManager.put_mcp_server("github", %{"type" => "stdio", "command" => "npx"})
      {:ok, _repo} = RepoManager.add_repo(tmp_dir, name: "Repo")
      {:ok, _repo} = RepoManager.set_mcp_server_ids(tmp_dir, ["github"])

      encoded_repository = Base.url_encode64(tmp_dir, padding: false)
      {:ok, view, html} = live(conn, "/repository/#{encoded_repository}/sessions/new")

      assert html =~ "New Session"
      assert html =~ "Skills"
      assert html =~ "Session List"
      assert html =~ "Settings"
      refute html =~ "All Repositories"
      assert html =~ ~s(href="/repository/#{encoded_repository}")
      assert html =~ ~s(href="/repository/#{encoded_repository}/settings")
      assert html =~ ~s(href="/repository/#{encoded_repository}/skills")

      assert html =~ "MCP Servers"
      assert html =~ "github"
      assert html =~ ~s(value="github" checked)

      render_change(view, "select_mcp_servers", %{})
      render_click(view, "create_session")

      [meta_path] = Path.wildcard(Path.join(ConfigManager.sessions_dir(tmp_dir), "*.meta.json"))
      session_id = Path.basename(meta_path, ".meta.json")
      log_path = Path.join(ConfigManager.sessions_dir(tmp_dir), "#{session_id}.jsonl")

      assert %{"mcp_server_ids" => []} = meta_path |> File.read!() |> Jason.decode!()
      assert {:ok, [%{"type" => "session", "cwd" => ^tmp_dir}]} = JsonlFile.read(log_path)

      {:ok, _session_view, session_html} =
        live(conn, "/repository/#{encoded_repository}/sessions/#{session_id}")

      assert session_html =~ ~s(id="session-menu-btn-#{session_id}")
    end)
  end

  defp with_agent_dir(tmp_dir, fun) do
    previous = Application.get_env(:ex_pi_session, :agent_dir)
    Application.put_env(:ex_pi_session, :agent_dir, Path.join(tmp_dir, "agent"))

    try do
      fun.()
    after
      if previous do
        Application.put_env(:ex_pi_session, :agent_dir, previous)
      else
        Application.delete_env(:ex_pi_session, :agent_dir)
      end
    end
  end
end
