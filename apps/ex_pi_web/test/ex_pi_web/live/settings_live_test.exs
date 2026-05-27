defmodule PiWeb.SettingsLiveTest do
  use PiWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  test "context page edits AGENTS.md and shows readonly system prompt", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/settings/system_prompt")

    assert html =~ "Context"
    assert html =~ "AGENTS.md"
    assert html =~ ~s(<h3 class="text-lg font-bold">AGENTS.md</h3>)
    assert html =~ ~s(id="system-prompt-editor")
    assert html =~ ~s(phx-update="ignore")
    assert html =~ ~s(id="system-prompt-preview")
    assert html =~ "el-dm-markdown"
    assert html =~ "You are Pi, an Elixir-based AI coding agent."
    assert html =~ "{{inject_memory}}"
    assert html =~ "{{inject_git_context}}"
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

  @tag :tmp_dir
  test "configures global MCP servers in mcp.json", %{conn: conn, tmp_dir: tmp_dir} do
    with_agent_dir(tmp_dir, fn ->
      {:ok, _} = PiSession.ConfigManager.add_credential("GitHub Token", "secret-token")
      [credential_id] = PiSession.ConfigManager.get_config()["credentials"] |> Map.keys()

      {:ok, view, html} = live(conn, "/settings/mcp")

      assert html =~ "MCP Servers"
      assert html =~ PiSession.ConfigManager.mcp_file()

      render_click(view, "new_mcp_server")

      new_server_html = render(view)

      assert new_server_html =~ "New MCP Server"
      assert new_server_html =~ "Args"
      assert new_server_html =~ "Env"
      refute new_server_html =~ "Headers"

      render_submit(view, "save_mcp_server", %{
        "mcp" => %{
          "mode" => "new",
          "original_id" => "",
          "id" => "github",
          "type" => "stdio",
          "command" => "npx",
          "args" => %{
            "key" => ["-y", "--token"],
            "value" => ["@modelcontextprotocol/server-github", ""],
            "credential_id" => ["", credential_id]
          },
          "env" => %{
            "key" => ["GITHUB_PERSONAL_ACCESS_TOKEN"],
            "value" => [""],
            "credential_id" => [credential_id]
          }
        }
      })

      saved = PiSession.ConfigManager.mcp_file() |> File.read!() |> Jason.decode!()
      credential_ref = "{{credential:#{credential_id}}}"

      assert %{
               "mcpServers" => %{
                 "github" => %{
                   "type" => "stdio",
                   "command" => "npx",
                   "args" => [
                     "-y",
                     "@modelcontextprotocol/server-github",
                     "--token",
                     ^credential_ref
                   ],
                   "env" => %{
                     "GITHUB_PERSONAL_ACCESS_TOKEN" => ^credential_ref
                   }
                 }
               }
             } = saved

      refute Map.has_key?(saved["mcpServers"]["github"], "headers")

      view
      |> element("el-dm-button[phx-click='edit_mcp_server'][phx-value-id='github']")
      |> render_click()

      render_change(view, "change_mcp_form", %{
        "mcp" => %{
          "type" => "http",
          "headers" => %{
            "key" => ["Authorization"],
            "value" => [""],
            "credential_id" => [credential_id]
          }
        }
      })

      http_form_html = render(view)

      assert http_form_html =~ "Headers"
      refute http_form_html =~ "Args"
      assert http_form_html =~ "Using credential"

      http_form_tree = Floki.parse_document!(http_form_html)

      hidden_values =
        http_form_tree
        |> Floki.find(~s(input[type="hidden"]))
        |> Enum.filter(&attr?(&1, "name", "mcp[headers][value][]"))

      assert Enum.any?(hidden_values, &attr?(&1, "value", ""))

      disabled_values =
        http_form_tree
        |> Floki.find("input")
        |> Enum.filter(&attr?(&1, "name", "mcp[headers][value][]"))

      assert Enum.any?(disabled_values, &disabled?/1)

      render_submit(view, "save_mcp_server", %{
        "mcp" => %{
          "mode" => "edit",
          "original_id" => "github",
          "id" => "github",
          "type" => "http",
          "url" => "https://api.githubcopilot.com/mcp",
          "headers" => %{
            "key" => ["Authorization"],
            "value" => [""],
            "credential_id" => [credential_id]
          }
        }
      })

      saved = PiSession.ConfigManager.mcp_file() |> File.read!() |> Jason.decode!()

      assert %{
               "mcpServers" => %{
                 "github" => %{
                   "type" => "http",
                   "url" => "https://api.githubcopilot.com/mcp",
                   "headers" => %{"Authorization" => ^credential_ref}
                 }
               }
             } = saved

      refute Map.has_key?(saved["mcpServers"]["github"], "command")
      refute Map.has_key?(saved["mcpServers"]["github"], "args")
      refute Map.has_key?(saved["mcpServers"]["github"], "env")

      view
      |> element("el-dm-button[phx-click='confirm_delete_mcp_server'][phx-value-id='github']")
      |> render_click()

      delete_modal_html = render(view)

      assert delete_modal_html =~ "Delete MCP Server"
      assert delete_modal_html =~ "github"

      view
      |> element("el-dm-button[phx-click='delete_mcp_server'][phx-value-id='github']")
      |> render_click()

      saved = PiSession.ConfigManager.mcp_file() |> File.read!() |> Jason.decode!()
      assert saved["mcpServers"] == %{}
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

  defp attr?({_tag, attrs, _children}, name, value), do: {name, value} in attrs

  defp disabled?({_tag, attrs, _children}) do
    Enum.any?(attrs, fn
      {"disabled", value} -> value in ["", "true", "disabled"]
      _ -> false
    end)
  end
end
