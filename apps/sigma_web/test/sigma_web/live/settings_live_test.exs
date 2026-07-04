defmodule Sigma.Web.SettingsLiveTest do
  use Sigma.Web.ConnCase, async: false
  import Phoenix.LiveViewTest

  @app_css Path.expand("../../../assets/css/app.css", __DIR__)

  test "context page edits AGENTS.md and shows readonly system prompt", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/settings/system_prompt")

    assert html =~ "Context"
    assert html =~ "AGENTS.md"
    assert html =~ ~s(<h3 class="text-lg font-bold">AGENTS.md</h3>)
    assert html =~ ~s(id="system-prompt-editor")
    assert html =~ ~s(phx-update="ignore")
    assert html =~ ~s(id="system-prompt-preview")
    assert html =~ "el-dm-markdown"
    assert html =~ "You are Sigma, an Elixir-based AI coding agent."
    assert html =~ "{{inject_memory}}"
    assert html =~ "{{inject_git_context}}"
  end

  test "settings sidebar uses readable active and hover colors", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/settings/mcp")

    tree = Floki.parse_document!(html)
    [active_link] = Floki.find(tree, ~s(a[href="/settings/mcp"]))
    [inactive_link] = Floki.find(tree, ~s(a[href="/settings/skills"]))

    assert class_values(active_link) =~ "bg-primary"
    assert class_values(active_link) =~ "text-primary-content"
    assert class_values(active_link) =~ "hover:!opacity-100"

    assert class_values(inactive_link) =~ "text-secondary-content"
    assert class_values(inactive_link) =~ "hover:bg-secondary-content/10"
    assert class_values(inactive_link) =~ "hover:text-secondary-content"
    refute class_values(inactive_link) =~ "text-primary-content"
  end

  @tag :tmp_dir
  test "hooks settings form has a recovery id", %{conn: conn, tmp_dir: tmp_dir} do
    with_agent_dir(tmp_dir, fn ->
      {:ok, _view, html} = live(conn, "/settings/hooks")

      assert html =~ "Hooks"
      assert html =~ ~s(id="settings-hooks-form")
    end)
  end

  @tag :tmp_dir
  test "manages providers with modal forms and delete confirmation", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    with_agent_dir(tmp_dir, fn ->
      {:ok, _} = Sigma.Session.ConfigManager.add_credential("OpenAI Key", "secret-token")
      [credential_id] = Sigma.Session.ConfigManager.get_config()["credentials"] |> Map.keys()

      {:ok, config} =
        Sigma.Session.ConfigManager.add_provider(%{
          "name" => "Test OpenAI",
          "api_type" => "openai",
          "credential_id" => credential_id,
          "model" => "gpt-4o-mini",
          "base_url" => "https://api.openai.com/v1"
        })

      [provider_id] = config["providers"] |> Map.keys()
      {:ok, _} = Sigma.Session.ConfigManager.set_active_provider(provider_id)

      {:ok, view, html} = live(conn, "/settings/providers")

      assert html =~ "Loading settings data"

      html = render_async(view)

      assert html =~ ~s(id="providers-table")
      assert html =~ "Test OpenAI"
      assert html =~ "gpt-4o-mini"
      assert html =~ "OpenAI Key"
      assert html =~ "ACTIVE"
      assert_settings_table(html, "providers-table")
      assert_icon_tooltip_action(html, "provider-edit-#{provider_id}", "Edit")
      assert_icon_tooltip_action(html, "provider-delete-#{provider_id}", "Delete")

      render_click(view, "add_provider")

      new_provider_html = render(view)

      assert new_provider_html =~ "New Provider"
      assert new_provider_html =~ ~s(id="provider-settings-modal")
      assert new_provider_html =~ ~s(id="provider-settings-form")
      assert new_provider_html =~ "Auth Type"
      assert new_provider_html =~ ~s(name="provider[auth_type]")
      refute new_provider_html =~ ~s(name="provider[auth_header_name]")

      render_change(view, "change_provider_form", %{
        "provider" => %{
          "mode" => "new",
          "id" => "",
          "name" => "Default OpenAI",
          "api_type" => "openai",
          "credential_id" => credential_id,
          "auth_type" => "x-api-key",
          "auth_header_name" => "",
          "model" => "gpt-4.1-mini",
          "base_url" => "https://api.openai.com/v1"
        }
      })

      render_submit(view, "save_provider", %{
        "provider" => %{
          "mode" => "new",
          "id" => "",
          "name" => "Default OpenAI",
          "api_type" => "openai",
          "credential_id" => credential_id,
          "model" => "gpt-4.1-mini",
          "base_url" => "https://api.openai.com/v1"
        }
      })

      config = Sigma.Session.ConfigManager.get_config()
      default_provider_id = provider_id_by_name(config["providers"], "Default OpenAI")
      assert config["providers"][default_provider_id]["auth_type"] == "bearer"

      render_click(view, "add_provider")

      custom_auth_html =
        render_change(view, "change_provider_form", %{
          "provider" => %{
            "mode" => "new",
            "id" => "",
            "name" => "Modal OpenAI",
            "api_type" => "openai",
            "credential_id" => credential_id,
            "auth_type" => "custom_header",
            "auth_header_name" => "X-API-Key",
            "model" => "gpt-4.1-mini",
            "base_url" => "https://api.openai.com/v1"
          }
        })

      assert custom_auth_html =~ "Header Name"
      assert custom_auth_html =~ ~s(name="provider[auth_header_name]")

      render_submit(view, "save_provider", %{
        "provider" => %{
          "mode" => "new",
          "id" => "",
          "name" => "Modal OpenAI",
          "api_type" => "openai",
          "credential_id" => credential_id,
          "auth_type" => "custom_header",
          "auth_header_name" => "X-API-Key",
          "model" => "gpt-4.1-mini",
          "base_url" => "https://api.openai.com/v1"
        }
      })

      html = render_async(view)

      assert html =~ "Modal OpenAI"
      assert html =~ "gpt-4.1-mini"

      config = Sigma.Session.ConfigManager.get_config()
      provider_id = provider_id_by_name(config["providers"], "Modal OpenAI")
      assert config["providers"][provider_id]["auth_type"] == "custom_header"
      assert config["providers"][provider_id]["auth_header_name"] == "X-API-Key"

      view
      |> element("el-dm-button[phx-click='edit_provider'][phx-value-id='#{provider_id}']")
      |> render_click()

      edit_provider_html = render(view)

      assert edit_provider_html =~ "Edit Provider"
      assert edit_provider_html =~ "Modal OpenAI"

      render_submit(view, "save_provider", %{
        "provider" => %{
          "mode" => "edit",
          "id" => provider_id,
          "name" => "Modal Anthropic",
          "api_type" => "anthropic",
          "credential_id" => credential_id,
          "auth_type" => "bearer",
          "auth_header_name" => "X-Ignored",
          "model" => "claude-3-5-sonnet-latest",
          "base_url" => "https://api.anthropic.com"
        }
      })

      html = render_async(view)

      assert html =~ "Modal Anthropic"
      refute html =~ "Modal OpenAI"
      config = Sigma.Session.ConfigManager.get_config()
      assert config["providers"][provider_id]["auth_type"] == "bearer"
      assert config["providers"][provider_id]["auth_header_name"] == ""

      view
      |> element(
        "el-dm-button[phx-click='confirm_delete_provider'][phx-value-id='#{provider_id}']"
      )
      |> render_click()

      delete_provider_html = render(view)

      assert delete_provider_html =~ "Delete Provider"
      assert delete_provider_html =~ "Modal Anthropic"

      view
      |> element("el-dm-button[phx-click='delete_provider'][phx-value-id='#{provider_id}']")
      |> render_click()

      html = render_async(view)

      refute html =~ "Modal Anthropic"
      refute Map.has_key?(Sigma.Session.ConfigManager.get_config()["providers"], provider_id)
    end)
  end

  @tag :tmp_dir
  test "manages credentials with modal forms and delete confirmation", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    with_agent_dir(tmp_dir, fn ->
      {:ok, _} = Sigma.Session.ConfigManager.add_credential("GitHub Token", "secret-token")

      {:ok, view, html} = live(conn, "/settings/credentials")

      assert html =~ "Loading settings data"

      html = render_async(view)

      assert html =~ ~s(id="credentials-table")
      assert html =~ "GitHub Token"
      assert html =~ "********oken"
      refute html =~ "secret-token"
      [credential_id] = Sigma.Session.ConfigManager.get_config()["credentials"] |> Map.keys()
      assert_settings_table(html, "credentials-table")
      assert_icon_tooltip_action(html, "credential-edit-#{credential_id}", "Edit")
      assert_icon_tooltip_action(html, "credential-delete-#{credential_id}", "Delete")

      render_click(view, "add_credential")

      new_credential_html = render(view)

      assert new_credential_html =~ "New Credential"
      assert new_credential_html =~ ~s(id="credential-settings-modal")
      assert new_credential_html =~ ~s(id="credential-settings-form")

      render_submit(view, "save_credential", %{
        "credential" => %{
          "mode" => "new",
          "id" => "",
          "name" => "OpenAI Token",
          "key" => "openai-secret"
        }
      })

      html = render_async(view)

      assert html =~ "OpenAI Token"
      assert html =~ "********cret"

      config = Sigma.Session.ConfigManager.get_config()
      credential_id = credential_id_by_name(config["credentials"], "OpenAI Token")

      view
      |> element("el-dm-button[phx-click='edit_credential'][phx-value-id='#{credential_id}']")
      |> render_click()

      edit_credential_html = render(view)

      assert edit_credential_html =~ "Edit Credential"
      assert edit_credential_html =~ "OpenAI Token"
      assert edit_credential_html =~ "openai-secret"

      render_submit(view, "save_credential", %{
        "credential" => %{
          "mode" => "edit",
          "id" => credential_id,
          "name" => "Anthropic Token",
          "key" => "anthropic-secret"
        }
      })

      html = render_async(view)

      assert html =~ "Anthropic Token"
      assert html =~ "********cret"
      refute html =~ "OpenAI Token"

      view
      |> element(
        "el-dm-button[phx-click='confirm_delete_credential'][phx-value-id='#{credential_id}']"
      )
      |> render_click()

      delete_credential_html = render(view)

      assert delete_credential_html =~ "Delete Credential"
      assert delete_credential_html =~ "Anthropic Token"

      view
      |> element("el-dm-button[phx-click='delete_credential'][phx-value-id='#{credential_id}']")
      |> render_click()

      html = render_async(view)

      refute html =~ "Anthropic Token"
      refute Map.has_key?(Sigma.Session.ConfigManager.get_config()["credentials"], credential_id)
    end)
  end

  @tag :tmp_dir
  test "shows globally discovered skills", %{conn: conn, tmp_dir: tmp_dir} do
    global_skills_dir = Path.join([tmp_dir, ".agents", "skills"])
    write_skill(global_skills_dir, "global-skill", "Global skill description")
    write_skill(global_skills_dir, "other-skill", "Another capability")

    previous = Application.get_env(:sigma_session, :global_skills_dir)
    Application.put_env(:sigma_session, :global_skills_dir, global_skills_dir)

    on_exit(fn ->
      if previous do
        Application.put_env(:sigma_session, :global_skills_dir, previous)
      else
        Application.delete_env(:sigma_session, :global_skills_dir)
      end
    end)

    with_agent_dir(tmp_dir, fn ->
      {:ok, view, html} = live(conn, "/settings/skills")

      assert html =~ "Loading settings data"

      html = render_async(view)

      assert html =~ "Skills"
      assert html =~ ~s(id="skills-table")
      assert html =~ ~s(id="skills-search")
      assert html =~ ~s(id="skills-select-all")
      assert html =~ ~s(id="skills-clear-selection")
      assert html =~ ~s(id="skills-enable-selected")
      assert html =~ ~s(id="skills-disable-selected")
      assert html =~ "global-skill"
      assert html =~ "Global skill description"
      assert html =~ "other-skill"
      assert html =~ global_skills_dir
      assert_settings_table(html, "skills-table")
      assert_skill_enabled(html, "global-skill", true)
      assert_skill_selected(html, "global-skill", false)
      assert_select_all_checked(html, false)
      assert_skill_description_popover(html, "global-skill")

      view
      |> element("#skill-enabled-global-skill")
      |> render_click()

      html = render_async(view)

      assert Sigma.Session.ConfigManager.disabled_global_skills() == ["global-skill"]
      assert_skill_enabled(html, "global-skill", false)

      view
      |> form("#skills-filter-form", %{"skills" => %{"query" => "other"}})
      |> render_change()

      html = render(view)

      assert html =~ "other-skill"
      refute html_has_id?(html, "skill-enabled-global-skill")
      assert_select_all_checked(html, false)

      view
      |> element("#skills-select-all")
      |> render_click()

      html = render(view)

      assert_skill_selected(html, "other-skill", true)
      assert_select_all_checked(html, true)

      view
      |> element("#skills-disable-selected")
      |> render_click()

      html = render_async(view)

      assert Sigma.Session.ConfigManager.disabled_global_skills() == ["global-skill", "other-skill"]
      assert html =~ "other-skill"
      refute html_has_id?(html, "skill-enabled-global-skill")
      assert_skill_enabled(html, "other-skill", false)
      assert_skill_selected(html, "other-skill", false)
      assert_select_all_checked(html, false)

      view
      |> element("#skills-select-all")
      |> render_click()

      html = render(view)

      assert_skill_selected(html, "other-skill", true)
      assert_select_all_checked(html, true)

      view
      |> element("#skills-enable-selected")
      |> render_click()

      html = render_async(view)

      assert Sigma.Session.ConfigManager.disabled_global_skills() == ["global-skill"]
      assert html =~ "other-skill"
      assert_skill_enabled(html, "other-skill", true)
    end)
  end

  @tag :tmp_dir
  test "configures global MCP servers in mcp.json", %{conn: conn, tmp_dir: tmp_dir} do
    with_agent_dir(tmp_dir, fn ->
      {:ok, _} = Sigma.Session.ConfigManager.add_credential("GitHub Token", "secret-token")
      [credential_id] = Sigma.Session.ConfigManager.get_config()["credentials"] |> Map.keys()

      {:ok, view, html} = live(conn, "/settings/mcp")

      assert html =~ "Loading settings data"

      html = render_async(view)

      assert html =~ "MCP Servers"
      assert html =~ Sigma.Session.ConfigManager.mcp_file()

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

      saved = Sigma.Session.ConfigManager.mcp_file() |> File.read!() |> Jason.decode!()
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

      html = render_async(view)
      assert html =~ ~s(id="mcp-servers-table")
      assert_settings_table(html, "mcp-servers-table")
      assert_icon_tooltip_action(html, "mcp-edit-server-github", "Edit")
      assert_icon_tooltip_action(html, "mcp-delete-server-github", "Delete")

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
      assert http_form_html =~ "Auth Type"
      assert http_form_html =~ ~s(name="mcp[auth_type]")
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
          "auth_type" => "custom_header",
          "auth_header_name" => "X-API-Key",
          "auth_value" => "",
          "auth_credential_id" => credential_id,
          "headers" => %{
            "key" => ["X-Trace"],
            "value" => ["trace-id"],
            "credential_id" => [""]
          }
        }
      })

      saved = Sigma.Session.ConfigManager.mcp_file() |> File.read!() |> Jason.decode!()

      assert %{
               "mcpServers" => %{
                 "github" => %{
                   "type" => "http",
                   "url" => "https://api.githubcopilot.com/mcp",
                   "authType" => "custom_header",
                   "authHeaderName" => "X-API-Key",
                   "headers" => %{
                     "X-API-Key" => ^credential_ref,
                     "X-Trace" => "trace-id"
                   }
                 }
               }
             } = saved

      refute Map.has_key?(saved["mcpServers"]["github"], "command")
      refute Map.has_key?(saved["mcpServers"]["github"], "args")
      refute Map.has_key?(saved["mcpServers"]["github"], "env")

      render_async(view)

      view
      |> element("el-dm-button[phx-click='confirm_delete_mcp_server'][phx-value-id='github']")
      |> render_click()

      delete_modal_html = render(view)

      assert delete_modal_html =~ "Delete MCP Server"
      assert delete_modal_html =~ "github"

      view
      |> element("el-dm-button[phx-click='delete_mcp_server'][phx-value-id='github']")
      |> render_click()

      saved = Sigma.Session.ConfigManager.mcp_file() |> File.read!() |> Jason.decode!()
      assert saved["mcpServers"] == %{}
    end)
  end

  defp write_skill(global_skills_dir, name, description) do
    skill_dir = Path.join(global_skills_dir, name)
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: #{name}
      description: #{description}
      ---
      Use this skill.
      """
    )
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

  defp attr?({_tag, attrs, _children}, name, value), do: {name, value} in attrs

  defp assert_settings_table(html, id) do
    tree = Floki.parse_document!(html)
    [table] = Floki.find(tree, "##{id}")
    assert class_values(table) =~ "settings-table"

    css = File.read!(@app_css)
    assert css =~ ".settings-table thead"
    assert css =~ "display: table-header-group !important;"
  end

  defp assert_icon_tooltip_action(html, id, label) do
    tree = Floki.parse_document!(html)
    [button] = Floki.find(tree, "##{id}")

    assert attr?(button, "aria-label", label)
    assert Floki.text(button) |> String.trim() == ""

    assert html =~ ~s(role="tooltip">#{label}</span>)
  end

  defp assert_skill_enabled(html, id, expected) do
    tree = Floki.parse_document!(html)
    [input] = Floki.find(tree, "#skill-enabled-#{id}")
    assert checked?(input) == expected
  end

  defp assert_skill_selected(html, id, expected) do
    tree = Floki.parse_document!(html)
    [input] = Floki.find(tree, "#skill-select-#{id}")
    assert checked?(input) == expected
  end

  defp assert_select_all_checked(html, expected) do
    tree = Floki.parse_document!(html)
    [input] = Floki.find(tree, "#skills-select-all")
    assert checked?(input) == expected
  end

  defp assert_skill_description_popover(html, id) do
    tree = Floki.parse_document!(html)
    [popover] = Floki.find(tree, "#skill-description-#{id}")
    assert Floki.find(popover, "p.settings-skills-description-trigger") != []
    assert Floki.text(popover) =~ "Global skill description"
    assert html =~ "settings-skills-description-cell"

    css = File.read!(@app_css)
    assert css =~ ".settings-skills-description-cell"
    assert css =~ "width: 25%;"
    assert css =~ "max-width: 25%;"
    assert css =~ "overflow: hidden;"
    assert css =~ "text-overflow: ellipsis;"
  end

  defp class_values({_tag, attrs, _children}) do
    attrs
    |> List.keyfind("class", 0, {"class", ""})
    |> elem(1)
  end

  defp checked?({_tag, attrs, _children}) do
    Enum.any?(attrs, fn
      {"checked", _value} -> true
      _ -> false
    end)
  end

  defp html_has_id?(html, id) do
    html
    |> Floki.parse_document!()
    |> Floki.find("##{id}")
    |> Enum.any?()
  end

  defp provider_id_by_name(providers, name) do
    providers
    |> Enum.find_value(fn
      {id, %{"name" => ^name}} -> id
      _ -> nil
    end)
  end

  defp credential_id_by_name(credentials, name) do
    credentials
    |> Enum.find_value(fn
      {id, %{"name" => ^name}} -> id
      _ -> nil
    end)
  end

  defp disabled?({_tag, attrs, _children}) do
    Enum.any?(attrs, fn
      {"disabled", value} -> value in ["", "true", "disabled"]
      _ -> false
    end)
  end
end
