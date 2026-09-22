defmodule Sigma.Session.Skills.FacadeTest do
  use ExUnit.Case, async: false

  alias Sigma.Session.Skills.Facade

  setup %{tmp_dir: tmp_dir} do
    previous_agent_dir = Application.get_env(:sigma_session, :agent_dir)
    previous_global_dir = Application.get_env(:sigma_session, :global_skills_dir)
    Application.put_env(:sigma_session, :agent_dir, Path.join(tmp_dir, "agent"))
    Application.put_env(:sigma_session, :global_skills_dir, Path.join(tmp_dir, "global"))

    on_exit(fn ->
      restore_env(:agent_dir, previous_agent_dir)
      restore_env(:global_skills_dir, previous_global_dir)
    end)

    :ok
  end

  @tag :tmp_dir
  test "projects safe local descriptors and diagnostics without filesystem paths", %{
    tmp_dir: tmp_dir
  } do
    workdir = Path.join(tmp_dir, "repo")
    valid_dir = Path.join([workdir, ".agents", "skills", "review"])
    invalid_dir = Path.join([workdir, ".agents", "skills", "broken"])
    File.mkdir_p!(valid_dir)
    File.mkdir_p!(invalid_dir)

    File.write!(
      Path.join(valid_dir, "SKILL.md"),
      "---\nname: review\ndescription: Review code\n---\nBody"
    )

    File.write!(Path.join(invalid_dir, "SKILL.md"), "---\nname: Broken\n---\nBody")

    assert %{
             catalog_revision: revision,
             items: [%{name: "review", status: "available"} = descriptor],
             diagnostics: [%{code: "invalid_skill_metadata", status: "invalid"} = diagnostic],
             remote_sources: []
           } = Facade.catalog(workdir)

    assert is_binary(revision)
    assert descriptor.source_id =~ "repo-"
    assert descriptor.reference == "repo:review"
    assert descriptor.revision == nil
    assert descriptor.artifact_digest == nil
    refute inspect(descriptor) =~ tmp_dir
    refute inspect(diagnostic) =~ tmp_dir
    refute Map.has_key?(diagnostic, :path)
  end

  @tag :tmp_dir
  test "reports configured remote source state without credentials or readiness claims", %{
    tmp_dir: tmp_dir
  } do
    File.mkdir_p!(Path.join(tmp_dir, "agent"))

    File.write!(
      Path.join([tmp_dir, "agent", "settings.json"]),
      Jason.encode!(%{
        "skillSources" => %{
          "online" => %{
            "kind" => "backplane",
            "baseUrl" => "https://skills.example.test",
            "credentialId" => "secret-ref",
            "accessContextId" => "client:sigma"
          },
          "invalid" => %{"kind" => "backplane", "credentialId" => "secret-ref"}
        }
      })
    )

    File.write!(
      Path.join([tmp_dir, "agent", "auth.json"]),
      Jason.encode!(%{"secret-ref" => %{"type" => "api_key", "key" => "secret-value"}})
    )

    assert [invalid, online] = Facade.remote_sources()
    assert invalid.status == "invalid_configuration"
    assert online.status == "configured"
    refute inspect([invalid, online]) =~ "secret-ref"
    refute inspect([invalid, online]) =~ "skills.example.test"
  end

  defp restore_env(key, nil), do: Application.delete_env(:sigma_session, key)
  defp restore_env(key, value), do: Application.put_env(:sigma_session, key, value)
end
