defmodule Sigma.Web.ProtocolSessionOptionsTest do
  use ExUnit.Case, async: false

  alias Sigma.Web.ProtocolSessionOptions

  @tag :tmp_dir
  test "protocol creation and restore use remote defaults with the global directory disabled", %{
    tmp_dir: dir
  } do
    previous =
      Map.new(
        [:global_skills_dir, :remote_skill_source_options],
        &{&1, Application.fetch_env(:sigma_session, &1)}
      )

    on_exit(fn ->
      for {key, original} <- previous do
        case original do
          {:ok, value} -> Application.put_env(:sigma_session, key, value)
          :error -> Application.delete_env(:sigma_session, key)
        end
      end
    end)

    global = Path.join(dir, "global")
    Application.put_env(:sigma_session, :global_skills_dir, global)

    with_config(dir, fn ->
      for {root, name} <- [
            {global, "hidden-global"},
            {Path.join(dir, ".agents/skills"), "visible-repository"}
          ] do
        path = Path.join(root, name)
        File.mkdir_p!(path)

        File.write!(
          Path.join(path, "SKILL.md"),
          "---\nname: #{name}\ndescription: Marker\n---\nBody"
        )
      end

      File.write!(
        Path.join([dir, "agent", "auth.json"]),
        Formata.JSON.encode!(%{"p" => %{"type" => "api_key", "key" => "fixture-only"}})
      )

      :ok = Sigma.Session.ConfigManager.set_load_global_skills(false)

      {:ok, _} =
        Sigma.Session.ConfigManager.put_skill_source("remote-one", %{
          "baseUrl" => "https://skills.test",
          "credentialId" => "p",
          "discovery" => true
        })

      Application.put_env(:sigma_session, :remote_skill_source_options,
        transport: fn request ->
          assert URI.parse(request.url).path == "/skill-protocol/v1/catalog"
          assert URI.decode_query(URI.parse(request.url).query)["view"] == "always"

          {:ok,
           %{
             status: 200,
             body:
               Formata.JSON.encode!(%{
                 "protocol_version" => "1",
                 "view" => "always",
                 "next_cursor" => nil,
                 "data" => [
                   %{
                     "skill_id" => "remote-skill",
                     "name" => "remote-default",
                     "description" => "Remote marker",
                     "revision" => "rev-1",
                     "artifact_digest" => "sha256:" <> String.duplicate("a", 64),
                     "publication_status" => "ready",
                     "disable_model_invocation" => false
                   }
                 ]
               })
           }}
        end
      )

      snapshot = %{cwd: dir, mcp_server_ids: [], provider_id: "p", model_id: "kept"}

      for _attempt <- 1..2 do
        opts = ProtocolSessionOptions.resolve(snapshot, dir, dir, "skills-restore")
        text = Sigma.Agent.SessionContext.to_text(opts[:session_context])

        if Sigma.Session.Skills.RemoteSource.discovery_available?() do
          assert text =~ "<name>remote-default</name>"
          assert text =~ "remote-one:remote-skill"
        else
          refute text =~ "<name>remote-default</name>"
        end

        assert text =~ "visible-repository"
        refute text =~ "hidden-global"
      end
    end)
  end

  @tag :tmp_dir
  test "protocol sessions select native tools through the session host", %{tmp_dir: tmp} do
    with_config(tmp, fn ->
      snapshot = %{
        cwd: tmp,
        mcp_server_ids: [],
        provider_id: "p",
        model_id: "kept",
        model_source: :journal,
        reasoning_level: "high"
      }

      opts = ProtocolSessionOptions.resolve(snapshot, tmp, tmp, "retired-tools")
      assert opts[:options][:reasoning_effort] == "high"
      assert opts[:provider] == Sigma.Ai.Providers.OpenAIResponses
      assert opts[:tools] == []
      assert opts[:native_tools]
      assert opts[:mcp_servers] == %{}
    end)
  end

  @tag :tmp_dir
  test "protocol sessions use the selected model's complete hosted configuration", %{tmp_dir: tmp} do
    with_config(tmp, fn ->
      path = Path.join([tmp, "agent", "models.json"])
      config = Formata.JSON.decode!(File.read!(path))
      enabled = %{"webSearch" => %{"supported" => true, "enabled" => true, "mode" => "cached"}}
      config = put_in(config, ["providers", "p", "hostedTools"], enabled)
      File.write!(path, Formata.JSON.encode!(config))
      snapshot = %{cwd: tmp, mcp_server_ids: [], provider_id: "p", model_id: "kept"}

      opts = ProtocolSessionOptions.resolve(snapshot, tmp, tmp, "hosted")

      assert opts[:options][:hosted_web_search] == %{
               supported: true,
               enabled: true,
               mode: :cached
             }

      config =
        put_in(config, ["providers", "p", "models"], [%{"id" => "kept", "hostedTools" => %{}}])

      File.write!(path, Formata.JSON.encode!(config))
      opts = ProtocolSessionOptions.resolve(snapshot, tmp, tmp, "hosted")
      assert is_nil(opts[:options][:hosted_web_search])
    end)
  end

  @tag :tmp_dir
  test "saved remote archive options do not override local History and Notes", %{tmp_dir: tmp} do
    with_config(tmp, fn ->
      agent_dir = Path.join(tmp, "agent")
      path = Path.join(agent_dir, "models.json")
      config = Formata.JSON.decode!(File.read!(path))

      provider =
        Map.merge(config["providers"]["p"], %{
          "kind" => "backplane",
          "baseUrl" => "https://gateway.example/v1/providers/openai-codex",
          "codexHistoryNotes" => true
        })

      File.write!(path, Formata.JSON.encode!(put_in(config, ["providers", "p"], provider)))

      File.write!(
        Path.join(agent_dir, "auth.json"),
        Formata.JSON.encode!(%{"p" => %{"type" => "api_key", "key" => "fixture-token"}})
      )

      settings = Path.join(agent_dir, "settings.json")
      current_settings = Formata.JSON.decode!(File.read!(settings))

      File.write!(
        settings,
        Formata.JSON.encode!(Map.put(current_settings, "remoteHistoryNotesProvider", "p"))
      )

      snapshot = %{cwd: tmp, mcp_server_ids: [], provider_id: "p", model_id: "kept"}
      opts = ProtocolSessionOptions.resolve(snapshot, tmp, tmp, "archive")
      assert opts[:native_tools]
      refute Keyword.has_key?(opts[:options], :codex_history_notes)
    end)
  end

  @tag :tmp_dir
  test "new protocol sessions validate model membership and freeze the resolved default budget",
       %{tmp_dir: tmp} do
    with_config(tmp, fn ->
      assert {:ok, payload} = ProtocolSessionOptions.prepare_create(%{})
      assert payload["providerId"] == "p"
      assert payload["modelId"] == "kept"
      assert payload["metadata"]["context_limit"] == 128_000

      assert {:ok, payload} =
               ProtocolSessionOptions.prepare_create(%{
                 "metadata" => %{"context_limit" => "65536"}
               })

      assert payload["metadata"]["context_limit"] == 65_536

      assert {:error, :model_unavailable} =
               ProtocolSessionOptions.prepare_create(%{
                 "providerId" => "p",
                 "modelId" => "removed"
               })

      assert {:error, :invalid_context_limit} =
               ProtocolSessionOptions.prepare_create(%{"metadata" => %{"context_limit" => 0}})

      assert {:error, :invalid_session_metadata} =
               ProtocolSessionOptions.prepare_create(%{"metadata" => []})
    end)
  end

  @tag :tmp_dir
  test "journal and metadata models require configured membership, even with a valid global default",
       %{tmp_dir: tmp} do
    with_config(tmp, fn ->
      snapshot = %{
        cwd: tmp,
        mcp_server_ids: [],
        provider_id: "p",
        model_id: "removed",
        model_source: :journal
      }

      assert [] == ProtocolSessionOptions.resolve(snapshot, tmp, tmp, "removed")

      File.write!(
        Path.join(tmp, "legacy.meta.json"),
        Formata.JSON.encode!(%{"provider_id" => "p", "model_id" => "removed"})
      )

      assert [] ==
               ProtocolSessionOptions.resolve(%{cwd: tmp, mcp_server_ids: []}, tmp, tmp, "legacy")
    end)
  end

  @tag :tmp_dir
  test "protocol budgets preserve existing custom values and legacy default", %{tmp_dir: tmp} do
    with_config(tmp, fn ->
      snapshot = %{
        cwd: tmp,
        mcp_server_ids: [],
        provider_id: "p",
        model_id: "kept",
        model_source: :journal
      }

      opts = ProtocolSessionOptions.resolve(snapshot, tmp, tmp, "legacy")
      assert opts[:context_limit] == 256_000

      File.write!(
        Path.join(tmp, "custom.meta.json"),
        Formata.JSON.encode!(%{"context_limit" => 65_536})
      )

      opts = ProtocolSessionOptions.resolve(snapshot, tmp, tmp, "custom")
      assert opts[:context_limit] == 65_536
    end)
  end

  defp with_config(tmp, fun) do
    previous = Application.get_env(:sigma_session, :agent_dir)
    dir = Path.join(tmp, "agent")
    File.mkdir_p!(dir)
    Application.put_env(:sigma_session, :agent_dir, dir)

    File.write!(
      Path.join(dir, "models.json"),
      Formata.JSON.encode!(%{
        "providers" => %{
          "p" => %{
            "api" => "openai",
            "baseUrl" => "https://example.com/v1",
            "models" => [%{"id" => "kept", "defaultContextLimit" => 128_000}]
          }
        }
      })
    )

    File.write!(
      Path.join(dir, "settings.json"),
      Formata.JSON.encode!(%{"defaultProvider" => "p", "defaultModel" => "kept"})
    )

    try do
      fun.()
    after
      if previous,
        do: Application.put_env(:sigma_session, :agent_dir, previous),
        else: Application.delete_env(:sigma_session, :agent_dir)
    end
  end
end
