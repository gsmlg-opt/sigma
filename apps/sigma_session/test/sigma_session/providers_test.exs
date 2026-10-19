defmodule Sigma.Session.ProvidersTest do
  use ExUnit.Case, async: false
  alias Sigma.Session.{ConfigManager, Models, Providers}
  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    previous = Application.get_env(:sigma_session, :agent_dir)
    Application.put_env(:sigma_session, :agent_dir, dir)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:sigma_session, :agent_dir, previous),
        else: Application.delete_env(:sigma_session, :agent_dir)
    end)

    File.write!(
      Path.join(dir, "auth.json"),
      Jason.encode!(%{"key" => %{"type" => "api_key", "key" => "secret"}})
    )

    File.write!(
      Path.join(dir, "models.json"),
      Jason.encode!(%{
        "providers" => %{
          "bp" => %{
            "kind" => "backplane",
            "serviceOrigin" => "https://bp.test/",
            "baseUrl" => "https://llm.test/v1",
            "credential_id" => "key",
            "models" => []
          },
          "legacy" => %{"name" => "Backplane", "baseUrl" => "https://legacy.test/v1"}
        }
      })
    )

    :ok
  end

  test "explicit service origin resolves independently of models and provider name" do
    assert {:ok, service} = Providers.resolve_service("bp", :mcp)
    assert service.url == "https://bp.test/mcp"
    assert service.credential_id == "key"
    assert service.credential_supplier.() == "secret"
    assert {:ok, %{url: "https://bp.test"}} = Providers.resolve_service("bp", :skills)
    assert {:error, _} = Providers.resolve_service("legacy", :skills)
    assert {:error, _} = Providers.resolve_service("missing", :mcp)

    assert {:ok, _} =
             ConfigManager.update_provider("bp", %{"service_origin" => "https://bp.test/prefix"})

    assert {:error, _} = Providers.resolve_service("bp", :skills)
  end

  test "MCP provider resolution refreshes origin and rejects dangling references" do
    assert {:ok, _} =
             ConfigManager.put_mcp_server("remote", %{
               "type" => "http",
               "providerId" => "bp",
               "headers" => %{"Authorization" => "old", "x-api-key" => "old", "X-Keep" => "ok"}
             })

    assert %{"remote" => %{"url" => "https://bp.test/mcp", "headers" => headers}} =
             ConfigManager.mcp_servers_for(["remote"])

    assert headers["authorization"] == "Bearer secret"
    refute Map.has_key?(headers, "x-api-key")
    refute Map.has_key?(headers, "X-Keep")
    assert {:error, {:provider_in_use, _}} = ConfigManager.delete_provider("bp")

    assert {:ok, _} =
             ConfigManager.update_provider("bp", %{"service_origin" => "https://new.test"})

    assert ConfigManager.mcp_servers_for(["remote"])["remote"]["url"] == "https://new.test/mcp"

    assert {:ok, _} =
             ConfigManager.update_mcp_server("remote", %{
               "urlOverride" => "https://other.test/full"
             })

    assert ConfigManager.mcp_servers_for(["remote"])["remote"]["url"] == "https://other.test/full"

    assert {:ok, _} =
             ConfigManager.update_mcp_server("remote", %{
               "providerId" => "missing",
               "url" => "https://stale.test"
             })

    invalid = ConfigManager.mcp_servers_for(["remote"])["remote"]
    assert invalid["configuration_error"]
    refute invalid["url"] == "https://stale.test"
    refute File.read!(ConfigManager.mcp_file()) =~ "secret"
  end

  test "provider references cannot be coerced into stdio or stale stored URLs" do
    assert {:ok, _} =
             ConfigManager.put_mcp_server("invalid", %{
               "type" => "stdio",
               "providerId" => "missing",
               "command" => "must-not-run",
               "url" => "https://stale.test"
             })

    assert %{
             "invalid" =>
               %{"type" => "http", "configuration_error" => :provider_unavailable} = server
           } = ConfigManager.mcp_servers_for(["invalid"])

    refute Map.has_key?(server, "command")
    refute Map.has_key?(server, "url")
    refute File.read!(ConfigManager.mcp_file()) =~ "https://stale.test"
  end

  test "provider removal checks models and skill sources; source rename preserves identity" do
    assert {:ok, _} = Models.add("bp", [%{"id" => "m"}])
    assert {:error, {:provider_in_use, _}} = ConfigManager.delete_provider("bp")
    assert {:ok, _} = Models.remove("bp", "m")

    assert {:ok, _} =
             ConfigManager.put_skill_source("stable", %{
               "providerId" => "bp",
               "name" => "Old",
               "accessContextId" => "sigma"
             })

    assert {:error, {:provider_in_use, _}} = ConfigManager.delete_provider("bp")
    assert {:ok, _} = ConfigManager.put_skill_source("stable", %{"name" => "New"})

    assert [
             %{
               source_id: "stable",
               name: "New",
               base_url: "https://bp.test",
               credential_id: "key"
             }
           ] = ConfigManager.skill_sources()

    assert {:ok, _} = ConfigManager.delete_skill_source("stable")
    assert {:ok, _} = ConfigManager.delete_provider("bp")
  end
end
