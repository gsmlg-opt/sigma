defmodule Sigma.Session.Skills.RemoteAdapterTest do
  use ExUnit.Case, async: false

  alias Backplane.SkillProtocol.{Bundle, Wire}
  alias Sigma.Session.SkillExpander
  alias Sigma.Session.Skills.{Facade, RemoteAdapter}

  setup %{tmp_dir: tmp_dir} do
    previous_agent_dir = Application.get_env(:sigma_session, :agent_dir)
    previous_global_dir = Application.get_env(:sigma_session, :global_skills_dir)
    previous_source_opts = Application.get_env(:sigma_session, :remote_skill_source_options)
    Application.put_env(:sigma_session, :agent_dir, Path.join(tmp_dir, "agent"))
    Application.put_env(:sigma_session, :global_skills_dir, Path.join(tmp_dir, "global"))
    write_config!(tmp_dir)

    on_exit(fn ->
      restore_env(:agent_dir, previous_agent_dir)
      restore_env(:global_skills_dir, previous_global_dir)
      restore_env(:remote_skill_source_options, previous_source_opts)
    end)

    :ok
  end

  @tag :tmp_dir
  test "explicit remote catalog is metadata-only, bounded, and credential-safe", %{
    tmp_dir: tmp_dir
  } do
    owner = self()

    transport = fn request ->
      uri = URI.parse(request.url)
      send(owner, {:request, uri.path, URI.decode_query(uri.query || ""), request.headers})

      {:ok,
       %{
         status: 200,
         body:
           Jason.encode!(%{
             "protocol_version" => "1",
             "data" => [
               %{
                 "skill_id" => "review",
                 "name" => "remote-review",
                 "description" => "Review remotely",
                 "argument_hint" => "[scope]",
                 "revision" => "rev-1",
                 "artifact_digest" => "sha256:" <> String.duplicate("a", 64),
                 "publication_status" => "ready"
               }
             ],
             "next_cursor" => "next"
           })
       }}
    end

    assert {:ok, result} =
             RemoteAdapter.catalog(
               %{"source_id" => "remote-one", "q" => "review", "limit" => "500"},
               source_options: [transport: transport, max_attempts: 1]
             )

    assert result.partial
    assert result.next_cursor == "next"

    assert [
             %{
               reference: "remote-one:review",
               revision: "rev-1",
               status: "ready",
               argument_hint: "[scope]"
             }
           ] =
             result.items

    assert_receive {:request, "/skill-protocol/v1/catalog", query, headers}
    assert query == %{"fields" => "argument_hint", "limit" => "100", "q" => "review"}
    assert headers["authorization"] == "Bearer test-secret"
    refute inspect(result) =~ "test-secret"
    refute inspect(result) =~ tmp_dir
  end

  @tag :tmp_dir
  test "ordinary local catalog does not construct or call a remote source", %{tmp_dir: tmp_dir} do
    Application.put_env(:sigma_session, :remote_skill_source_options,
      transport: fn _request -> flunk("local catalog must not perform remote I/O") end
    )

    assert %{items: [], remote_sources: [%{source_id: "remote-one", status: "configured"}]} =
             Facade.catalog(Path.join(tmp_dir, "repo"))
  end

  @tag :tmp_dir
  test "unified expander prepares an exact remote ref only on explicit submission", %{
    tmp_dir: tmp_dir
  } do
    fixture = bundle_fixture(tmp_dir)
    owner = self()

    transport = fn request ->
      uri = URI.parse(request.url)
      send(owner, {:request, uri.path})

      case uri.path do
        "/skill-protocol/v1/resolve" ->
          {:ok, %{status: 200, body: Jason.encode!(fixture.manifest)}}

        "/skill-protocol/v1/artifact" ->
          {:ok, %{status: 200, body: fixture.archive}}
      end
    end

    Application.put_env(:sigma_session, :remote_skill_source_options,
      transport: transport,
      max_attempts: 1,
      cache_root: Path.join(tmp_dir, "cache"),
      binding_path: Path.join(tmp_dir, "bindings.json")
    )

    assert {:ok, expansion} =
             SkillExpander.expand("/skill remote-one:review inspect lib", cwd: tmp_dir)

    assert expansion.content == "Remote inspect lib"

    assert expansion.skill.ref == %{
             source_id: "remote-one",
             skill_id: "review",
             revision: fixture.revision,
             artifact_digest: fixture.digest
           }

    assert expansion.skill.digest == fixture.digest
    assert [%{root: root, digest: digest, release: release}] = expansion.prepared_resources
    assert File.regular?(Path.join(root, "SKILL.md"))
    assert digest == fixture.digest
    assert :ok = release.()
    assert_receive {:request, "/skill-protocol/v1/resolve"}
    assert_receive {:request, "/skill-protocol/v1/artifact"}

    settings_path = Path.join([tmp_dir, "agent", "settings.json"])
    settings = settings_path |> File.read!() |> Jason.decode!()
    offline = put_in(settings, ["skillSources", "remote-one", "offline"], true)
    File.write!(settings_path, Jason.encode!(offline))

    Application.put_env(:sigma_session, :remote_skill_source_options,
      transport: fn _request -> flunk("explicit offline preparation must not use network") end,
      cache_root: Path.join(tmp_dir, "cache"),
      binding_path: Path.join(tmp_dir, "bindings.json")
    )

    assert {:ok, offline_expansion} =
             SkillExpander.expand("/skill remote-one:review offline", cwd: tmp_dir)

    assert offline_expansion.skill.ref == expansion.skill.ref
    assert offline_expansion.skill.digest == expansion.skill.digest
  end

  defp write_config!(tmp_dir) do
    agent_dir = Path.join(tmp_dir, "agent")
    File.mkdir_p!(agent_dir)

    File.write!(
      Path.join(agent_dir, "settings.json"),
      Jason.encode!(%{
        "skillSources" => %{
          "remote-one" => %{
            "kind" => "backplane",
            "name" => "Remote One",
            "baseUrl" => "https://skills.example.test",
            "credentialId" => "remote-token",
            "accessContextId" => "client:sigma"
          }
        }
      })
    )

    File.write!(
      Path.join(agent_dir, "auth.json"),
      Jason.encode!(%{
        "remote-token" => %{"type" => "api_key", "key" => "test-secret"}
      })
    )
  end

  defp bundle_fixture(tmp_dir) do
    root = Path.join(tmp_dir, "review")
    archive = Path.join(tmp_dir, "bundle.tar.gz")
    File.mkdir_p!(root)

    File.write!(
      Path.join(root, "SKILL.md"),
      "---\nname: review\ndescription: Remote\n---\nRemote $ARGUMENTS"
    )

    assert {:ok, bundle} =
             Bundle.pack(root, archive,
               ref: %Backplane.SkillProtocol.SkillRef{
                 source_id: "remote-one",
                 skill_id: "review",
                 revision: "rev-1"
               }
             )

    %{
      archive: File.read!(archive),
      manifest: Wire.manifest_map(bundle.manifest),
      revision: bundle.manifest.ref.revision,
      digest: bundle.manifest.artifact_digest
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:sigma_session, key)
  defp restore_env(key, value), do: Application.put_env(:sigma_session, key, value)
end
