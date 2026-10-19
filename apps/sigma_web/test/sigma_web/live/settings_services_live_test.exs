defmodule Sigma.Web.SettingsServicesLiveTest do
  use Sigma.Web.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Sigma.Session.ConfigManager

  @moduletag :tmp_dir
  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:sigma_session, :agent_dir)
    previous_opts = Application.get_env(:sigma_session, :remote_skill_source_options)
    Application.put_env(:sigma_session, :agent_dir, Path.join(tmp_dir, "agent"))

    on_exit(fn ->
      restore(:agent_dir, previous)
      restore(:remote_skill_source_options, previous_opts)
    end)

    {:ok, config} = ConfigManager.add_credential("Shared service credential", "never-in-dom")
    [credential_id] = Map.keys(config["credentials"])

    {:ok, config} =
      ConfigManager.add_provider(%{
        "name" => "Shared Backplane",
        "api_type" => "openai",
        "kind" => "backplane",
        "service_origin" => "https://services.example",
        "base_url" => "https://llm.example/v1",
        "credential_id" => credential_id
      })

    [provider_id] = Map.keys(config["providers"])
    %{provider_id: provider_id}
  end

  test "MCP inherits provider service and saves only its own URL override", %{
    conn: conn,
    provider_id: pid
  } do
    {:ok, view, _} = live(conn, "/settings/mcp")
    render_async(view, 1000)
    render_click(view, "new_mcp_server")

    html =
      render_change(view, "change_mcp_form", %{
        "mcp" => %{"type" => "http", "source" => "provider", "provider_id" => pid}
      })

    assert html =~ "https://services.example/mcp"
    assert html =~ "Shared service credential"
    refute html =~ "never-in-dom"

    render_submit(view, "save_mcp_server", %{
      "mcp" => %{
        "id" => "shared",
        "override_enabled" => "true",
        "url_override" => "https://override.example/mcp"
      }
    })

    server = ConfigManager.list_mcp_servers()["shared"]
    assert server["providerId"] == pid
    assert server["urlOverride"] == "https://override.example/mcp"
    refute inspect(server) =~ "never-in-dom"
    assert ConfigManager.get_config()["providers"][pid]["base_url"] == "https://llm.example/v1"

    assert ConfigManager.get_config()["providers"][pid]["service_origin"] ==
             "https://services.example"

    render_async(view, 1000)
    render_click(view, "edit_mcp_server", %{"id" => "shared"})
    render_submit(view, "save_mcp_server", %{"mcp" => %{"override_enabled" => "false"}})
    refute Map.has_key?(ConfigManager.list_mcp_servers()["shared"], "urlOverride")
    render_async(view, 1000)
    render_click(view, "edit_mcp_server", %{"id" => "shared"})

    render_submit(view, "save_mcp_server", %{
      "mcp" => %{"source" => "standalone", "url" => "https://standalone.example/mcp"}
    })

    standalone = ConfigManager.list_mcp_servers()["shared"]
    refute Map.has_key?(standalone, "providerId")
    assert standalone["url"] == "https://standalone.example/mcp"
  end

  test "remote sources are explicit, stable, and browse the skill protocol", %{
    conn: conn,
    provider_id: pid
  } do
    owner = self()

    Application.put_env(:sigma_session, :remote_skill_source_options,
      max_attempts: 1,
      transport: fn request ->
        uri = URI.parse(request.url)
        send(owner, {:catalog_request, uri.path, URI.decode_query(uri.query || "")})

        {:ok,
         %{
           status: 200,
           body:
             Jason.encode!(%{
               "protocol_version" => "1",
               "data" => [
                 %{
                   "skill_id" => "review",
                   "name" => "Remote Review",
                   "description" => "Review code",
                   "revision" => "r1",
                   "artifact_digest" => "sha256:" <> String.duplicate("a", 64),
                   "publication_status" => "ready"
                 }
               ],
               "next_cursor" => "next-page"
             })
         }}
      end
    )

    {:ok, view, _} = live(conn, "/settings/skills")
    render_async(view, 2000)
    refute_receive {:catalog_request, _, _}
    view |> element("#remote-source-new") |> render_click()

    view
    |> form("#remote-source-form", %{
      "source" => %{
        "id" => "shared-skills",
        "name" => "Shared skills",
        "provider_id" => pid,
        "enabled" => "true",
        "offline" => "false"
      }
    })
    |> render_change()

    html = render(view)
    assert html =~ "https://services.example/skill-protocol/v1"
    assert html =~ "Shared service credential"
    refute html =~ "never-in-dom"
    view |> form("#remote-source-form") |> render_submit()
    assert [%{source_id: "shared-skills", name: "Shared skills"}] = ConfigManager.skill_sources()
    refute_receive {:catalog_request, _, _}
    view |> element("[phx-click='browse_remote_source']") |> render_click()
    html = render_async(view, 2000)
    assert_receive {:catalog_request, "/skill-protocol/v1/catalog", _}
    assert html =~ "shared-skills:review"
    view |> form("#remote-catalog-search", %{"query" => "review"}) |> render_submit()
    render_async(view, 2000)
    assert_receive {:catalog_request, _, %{"q" => "review"}}
    view |> element("#remote-catalog-next") |> render_click()
    render_async(view, 2000)
    assert_receive {:catalog_request, _, %{"cursor" => "next-page"}}
    view |> element("[phx-click='edit_remote_source']") |> render_click()

    view
    |> form("#remote-source-form", %{"source" => %{"name" => "Renamed source"}})
    |> render_submit()

    assert [%{source_id: "shared-skills", name: "Renamed source"}] = ConfigManager.skill_sources()
    view |> element("[phx-click='confirm_delete_remote_source']") |> render_click()
    assert length(ConfigManager.skill_sources()) == 1
    view |> element("#remote-source-confirm-delete") |> render_click()
    assert ConfigManager.skill_sources() == []
  end

  test "unavailable provider references do not fall back to saved standalone values", %{
    conn: conn
  } do
    {:ok, _} =
      ConfigManager.put_mcp_server("missing", %{
        "type" => "http",
        "providerId" => "removed",
        "url" => "https://old.example/mcp"
      })

    {:ok, view, _} = live(conn, "/settings/mcp")
    html = render_async(view, 1000)
    assert html =~ "Provider unavailable"
    refute html =~ "old.example"
    render_click(view, "edit_mcp_server", %{"id" => "missing"})
    render_submit(view, "save_mcp_server", %{"mcp" => %{"id" => "missing"}})
    assert render(view) =~ "Check its provider"
    assert ConfigManager.list_mcp_servers()["missing"]["providerId"] == "removed"
  end

  test "remote source catalog errors are safe and keep the source", %{
    conn: conn,
    provider_id: pid
  } do
    {:ok, _} =
      ConfigManager.put_skill_source("remote-error", %{
        "providerId" => pid,
        "name" => "Error source"
      })

    Application.put_env(:sigma_session, :remote_skill_source_options,
      max_attempts: 1,
      transport: fn _ -> {:ok, %{status: 403, body: "never-in-dom"}} end
    )

    {:ok, view, _} = live(conn, "/settings/skills")
    render_async(view, 2000)
    view |> element("[phx-click='browse_remote_source']") |> render_click()
    html = render_async(view, 2000)
    assert html =~ "authentication failed"
    refute html =~ "never-in-dom"
    assert length(ConfigManager.skill_sources()) == 1
  end

  test "switching remote sources hides the previous catalog while loading", %{
    conn: conn,
    provider_id: pid
  } do
    owner = self()

    {:ok, config} =
      ConfigManager.add_provider(%{
        "name" => "Second source",
        "api_type" => "openai",
        "kind" => "backplane",
        "service_origin" => "https://second.example",
        "credential_id" => ConfigManager.get_config()["providers"][pid]["credential_id"]
      })

    second_pid = config["providers"] |> Map.keys() |> Enum.find(&(&1 != pid))
    {:ok, _} = ConfigManager.put_skill_source("first-source", %{"providerId" => pid})
    {:ok, _} = ConfigManager.put_skill_source("second-source", %{"providerId" => second_pid})

    Application.put_env(:sigma_session, :remote_skill_source_options,
      max_attempts: 1,
      transport: fn request ->
        if URI.parse(request.url).host == "second.example" do
          send(owner, {:second_started, self()})

          receive do
            :finish -> :ok
          after
            2_000 -> :ok
          end
        end

        {:ok,
         %{
           status: 200,
           body:
             Jason.encode!(%{
               "protocol_version" => "1",
               "data" => [
                 %{
                   "skill_id" => "review",
                   "name" => "Remote Review",
                   "revision" => "r1",
                   "artifact_digest" => "sha256:" <> String.duplicate("a", 64),
                   "publication_status" => "ready"
                 }
               ],
               "next_cursor" => "next"
             })
         }}
      end
    )

    {:ok, view, _} = live(conn, "/settings/skills")
    render_async(view, 2000)

    view
    |> element("[phx-click='browse_remote_source'][phx-value-id='first-source']")
    |> render_click()

    assert render_async(view, 2000) =~ "first-source:review"

    view
    |> element("[phx-click='browse_remote_source'][phx-value-id='second-source']")
    |> render_click()

    assert_receive {:second_started, task}
    html = render(view)
    refute html =~ "first-source:review"
    refute has_element?(view, "#remote-catalog-next")
    send(task, :finish)
    assert render_async(view, 2000) =~ "second-source:review"
  end

  defp restore(key, nil), do: Application.delete_env(:sigma_session, key)
  defp restore(key, value), do: Application.put_env(:sigma_session, key, value)
end
