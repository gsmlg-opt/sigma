defmodule PiWeb.ProjectSettingsLiveTest do
  use PiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PiSession.{ConfigManager, RepoManager}

  @tag :tmp_dir
  test "saves project MCP server defaults", %{conn: conn, tmp_dir: tmp_dir} do
    with_agent_dir(tmp_dir, fn ->
      ConfigManager.put_mcp_server("github", %{
        "type" => "stdio",
        "command" => "npx",
        "args" => ["-y", "@modelcontextprotocol/server-github"]
      })

      {:ok, _repo} = RepoManager.add_repo(tmp_dir, name: "Repo")
      encoded_repository = Base.url_encode64(tmp_dir, padding: false)

      {:ok, view, html} = live(conn, "/repository/#{encoded_repository}/settings")
      assert html =~ "New Session"
      assert html =~ "Skills"
      assert html =~ "Session List"
      assert html =~ "Settings"
      refute html =~ "All Repositories"
      assert html =~ ~s(href="/repository/#{encoded_repository}/sessions/new")
      assert html =~ ~s(href="/repository/#{encoded_repository}/skills")
      assert html =~ ~s(href="/repository/#{encoded_repository}")

      assert html =~ "MCP Servers"
      assert html =~ "github"

      render_submit(view, "save", %{
        "name" => "Repo",
        "path" => tmp_dir,
        "mcp_server_ids" => ["github"]
      })

      assert %{"mcp_server_ids" => ["github"]} = RepoManager.get_repo(tmp_dir)
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
