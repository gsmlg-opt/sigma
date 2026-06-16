defmodule PiSession.ConfigManagerTest do
  use ExUnit.Case, async: false

  alias PiSession.ConfigManager

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:ex_pi_session, :agent_dir)
    agent_dir = Path.join(tmp_dir, "agent")
    Application.put_env(:ex_pi_session, :agent_dir, agent_dir)

    on_exit(fn ->
      if previous do
        Application.put_env(:ex_pi_session, :agent_dir, previous)
      else
        Application.delete_env(:ex_pi_session, :agent_dir)
      end
    end)

    :ok
  end

  @tag :tmp_dir
  test "uses default model as active selection while preserving configured models" do
    File.mkdir_p!(ConfigManager.agent_dir())

    File.write!(
      Path.join(ConfigManager.agent_dir(), "settings.json"),
      Jason.encode!(%{"defaultProvider" => "openai", "defaultModel" => "smart"})
    )

    File.write!(
      Path.join(ConfigManager.agent_dir(), "models.json"),
      Jason.encode!(%{
        "providers" => %{
          "openai" => %{
            "name" => "OpenAI",
            "api" => "openai-completions",
            "models" => [
              %{"id" => "fast"},
              %{"id" => "smart", "contextWindow" => 1_000_000},
              %{"id" => "expert"}
            ]
          }
        }
      })
    )

    assert %{
             "active_provider_id" => "openai",
             "providers" => %{
               "openai" => %{
                 "model" => "smart",
                 "models" => [
                   %{"id" => "fast"},
                   %{"id" => "smart", "contextWindow" => 1_000_000},
                   %{"id" => "expert"}
                 ]
               }
             }
           } = ConfigManager.get_config()

    assert {:ok, _} = ConfigManager.update_provider("openai", %{"model" => "expert"})

    saved_settings =
      ConfigManager.agent_dir()
      |> Path.join("settings.json")
      |> File.read!()
      |> Jason.decode!()

    saved_models =
      ConfigManager.agent_dir()
      |> Path.join("models.json")
      |> File.read!()
      |> Jason.decode!()

    assert saved_settings["defaultModel"] == "expert"

    assert Enum.map(saved_models["providers"]["openai"]["models"], & &1["id"]) == [
             "expert",
             "fast",
             "smart"
           ]

    assert %{"contextWindow" => 1_000_000} =
             Enum.find(saved_models["providers"]["openai"]["models"], &(&1["id"] == "smart"))
  end

  @tag :tmp_dir
  test "enriches known bare model ids with output token metadata" do
    File.mkdir_p!(ConfigManager.agent_dir())

    File.write!(
      Path.join(ConfigManager.agent_dir(), "settings.json"),
      Jason.encode!(%{"defaultProvider" => "minimax", "defaultModel" => "MiniMax-M3"})
    )

    File.write!(
      Path.join(ConfigManager.agent_dir(), "models.json"),
      Jason.encode!(%{
        "providers" => %{
          "minimax" => %{
            "name" => "MiniMax",
            "api" => "anthropic-messages",
            "models" => [
              %{"id" => "MiniMax-M3"},
              %{"id" => "MiniMax-M2.7", "maxTokens" => 64_000}
            ]
          }
        }
      })
    )

    %{
      "providers" => %{
        "minimax" => %{"models" => models}
      }
    } = ConfigManager.get_config()

    assert %{"contextWindow" => 512_000, "maxTokens" => 128_000} =
             Enum.find(models, &(&1["id"] == "MiniMax-M3"))

    assert %{"contextWindow" => 204_800, "maxTokens" => 64_000} =
             Enum.find(models, &(&1["id"] == "MiniMax-M2.7"))
  end

  @tag :tmp_dir
  test "persists inactive provider current model as first configured model" do
    File.mkdir_p!(ConfigManager.agent_dir())

    File.write!(
      Path.join(ConfigManager.agent_dir(), "settings.json"),
      Jason.encode!(%{"defaultProvider" => "openai", "defaultModel" => "fast"})
    )

    File.write!(
      Path.join(ConfigManager.agent_dir(), "models.json"),
      Jason.encode!(%{
        "providers" => %{
          "openai" => %{
            "name" => "OpenAI",
            "api" => "openai-completions",
            "models" => [%{"id" => "fast"}]
          },
          "anthropic" => %{
            "name" => "Anthropic",
            "api" => "anthropic-messages",
            "models" => [
              %{"id" => "claude"},
              %{"id" => "opus"}
            ]
          }
        }
      })
    )

    assert {:ok, _} = ConfigManager.update_provider("anthropic", %{"model" => "opus"})

    saved_models =
      ConfigManager.agent_dir()
      |> Path.join("models.json")
      |> File.read!()
      |> Jason.decode!()

    assert Enum.map(saved_models["providers"]["anthropic"]["models"], & &1["id"]) == [
             "opus",
             "claude"
           ]

    assert %{
             "active_provider_id" => "openai",
             "providers" => %{
               "anthropic" => %{"model" => "opus"},
               "openai" => %{"model" => "fast"}
             }
           } = ConfigManager.get_config()
  end

  @tag :tmp_dir
  test "defaults global skills to enabled and persists disabled global skills" do
    assert ConfigManager.disabled_global_skills() == []
    assert ConfigManager.get_config()["disabled_global_skills"] == []

    assert :ok = ConfigManager.set_global_skill_enabled("beta", false)
    assert ConfigManager.disabled_global_skills() == ["beta"]

    assert :ok = ConfigManager.set_global_skills_enabled(["alpha", "beta"], false)
    assert ConfigManager.disabled_global_skills() == ["alpha", "beta"]

    assert :ok = ConfigManager.set_global_skill_enabled("beta", true)
    assert ConfigManager.disabled_global_skills() == ["alpha"]
    assert ConfigManager.get_config()["disabled_global_skills"] == ["alpha"]

    saved_settings =
      ConfigManager.agent_dir()
      |> Path.join("settings.json")
      |> File.read!()
      |> Jason.decode!()

    assert saved_settings["disabledSkills"] == %{"global" => ["alpha"]}
  end

  @tag :tmp_dir
  test "loads VS Code-style mcp.json and saves Claude-style mcpServers" do
    File.mkdir_p!(ConfigManager.agent_dir())

    File.write!(
      ConfigManager.mcp_file(),
      Jason.encode!(%{
        "servers" => %{
          "github" => %{
            "type" => "http",
            "url" => "https://api.githubcopilot.com/mcp"
          },
          "playwright" => %{
            "command" => "npx",
            "args" => ["-y", "@microsoft/mcp-server-playwright"]
          }
        }
      })
    )

    assert %{
             "servers" => %{
               "github" => %{"type" => "http", "url" => "https://api.githubcopilot.com/mcp"},
               "playwright" => %{"type" => "stdio", "command" => "npx"}
             }
           } = ConfigManager.get_mcp_config()

    assert {:ok, _} =
             ConfigManager.put_mcp_server("local-weather", %{
               "type" => "stdio",
               "command" => "/path/to/weather-cli",
               "args" => ["--api-key", "abc123"],
               "env" => %{"CACHE_DIR" => "/tmp"}
             })

    saved = ConfigManager.mcp_file() |> File.read!() |> Jason.decode!()

    assert %{"mcpServers" => %{"local-weather" => %{"type" => "stdio"}}} = saved
    refute Map.has_key?(saved, "servers")
  end

  @tag :tmp_dir
  test "resolves MCP credential references for selected servers" do
    {:ok, _} = ConfigManager.add_credential("GitHub Token", "secret-token")
    [credential_id] = ConfigManager.get_config()["credentials"] |> Map.keys()

    assert {:ok, _} =
             ConfigManager.put_mcp_server("secure", %{
               "type" => "stdio",
               "command" => "npx",
               "args" => ["--token", "{{credential:#{credential_id}}}"],
               "env" => %{"GITHUB_PERSONAL_ACCESS_TOKEN" => "{{credential:#{credential_id}}}"}
             })

    assert %{
             "secure" => %{
               "args" => ["--token", "secret-token"],
               "env" => %{"GITHUB_PERSONAL_ACCESS_TOKEN" => "secret-token"}
             }
           } = ConfigManager.mcp_servers_for(["secure"])
  end
end
