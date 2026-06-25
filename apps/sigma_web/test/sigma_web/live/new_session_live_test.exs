defmodule Sigma.Web.NewSessionLiveTest do
  use Sigma.Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Sigma.Session.{ConfigManager, RepoManager}
  alias Sigma.Session.Storage.JsonlFile

  @tag :tmp_dir
  test "defaults new sessions to project MCP servers and allows disabling", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    workdir = Path.join(System.tmp_dir!(), "sigma-new-session-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workdir)

    on_exit(fn -> File.rm_rf!(workdir) end)

    with_agent_dir(tmp_dir, fn ->
      ConfigManager.put_mcp_server("github", %{"type" => "stdio", "command" => "npx"})
      {:ok, _repo} = RepoManager.add_repo(workdir, name: "Repo")
      {:ok, _repo} = RepoManager.set_mcp_server_ids(workdir, ["github"])

      encoded_repository = Base.url_encode64(workdir, padding: false)
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

      [meta_path] = Path.wildcard(Path.join(ConfigManager.sessions_dir(workdir), "*.meta.json"))
      session_id = Path.basename(meta_path, ".meta.json")
      log_path = Path.join(ConfigManager.sessions_dir(workdir), "#{session_id}.jsonl")

      assert %{"mcp_server_ids" => []} = meta_path |> File.read!() |> Jason.decode!()
      assert {:ok, [%{"type" => "session", "cwd" => ^workdir}]} = JsonlFile.read(log_path)

      {:ok, _session_view, session_html} =
        live(conn, "/repository/#{encoded_repository}/sessions/#{session_id}")

      menu_token = Base.url_encode64(session_id, padding: false)
      assert session_html =~ ~s(id="session-menu-btn-#{menu_token}")
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
