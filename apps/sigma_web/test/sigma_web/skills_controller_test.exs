defmodule Sigma.Web.SkillsControllerTest do
  use Sigma.Web.ConnCase, async: false

  alias Sigma.Session.RepoManager

  @tag :tmp_dir
  test "reports truthful skills capabilities", %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:sigma_session, :agent_dir)
    agent_dir = Path.join(tmp_dir, "agent")
    Application.put_env(:sigma_session, :agent_dir, agent_dir)
    File.mkdir_p!(agent_dir)

    try do
      conn = get(build_conn(), "/api/v1/capabilities")
      response = Jason.decode!(conn.resp_body)
      assert conn.status == 200
      assert response["skills"]["localCatalog"]
      assert response["skills"]["remoteRead"] == false
      assert response["skills"]["remoteSources"] == []
      assert response["skills"]["conditionalPublication"] == false

      File.write!(
        Path.join(agent_dir, "settings.json"),
        Jason.encode!(%{
          "skillSources" => %{
            "remote-one" => %{
              "kind" => "backplane",
              "baseUrl" => "https://skills.example.test",
              "credentialId" => "remote-token",
              "accessContextId" => "client:sigma"
            }
          }
        })
      )

      File.write!(
        Path.join(agent_dir, "auth.json"),
        Jason.encode!(%{"remote-token" => %{"type" => "api_key", "key" => "token"}})
      )

      conn = get(build_conn(), "/api/v1/capabilities")
      response = Jason.decode!(conn.resp_body)
      assert response["skills"]["remoteRead"]

      assert [%{"sourceId" => "remote-one", "status" => "configured"}] =
               response["skills"]["remoteSources"]
    after
      restore_env(:agent_dir, previous)
    end
  end

  @tag :tmp_dir
  test "performs explicit bounded remote metadata search without exposing credentials", %{
    conn: conn,
    tmp_dir: tmp_dir
  } do
    previous_agent = Application.get_env(:sigma_session, :agent_dir)
    previous_source_opts = Application.get_env(:sigma_session, :remote_skill_source_options)
    agent_dir = Path.join(tmp_dir, "agent")
    workdir = Path.join(tmp_dir, "repo")
    owner = self()
    File.mkdir_p!(agent_dir)
    File.mkdir_p!(workdir)
    Application.put_env(:sigma_session, :agent_dir, agent_dir)
    RepoManager.add_repo(workdir, name: "Repo")

    File.write!(
      Path.join(agent_dir, "settings.json"),
      Jason.encode!(%{
        "skillSources" => %{
          "remote-one" => %{
            "kind" => "backplane",
            "baseUrl" => "https://skills.example.test",
            "credentialId" => "remote-token",
            "accessContextId" => "client:sigma"
          }
        }
      })
    )

    File.write!(
      Path.join(agent_dir, "auth.json"),
      Jason.encode!(%{"remote-token" => %{"type" => "api_key", "key" => "hidden-token"}})
    )

    transport = fn request ->
      uri = URI.parse(request.url)
      send(owner, {:remote_search, URI.decode_query(uri.query || ""), request.headers})

      {:ok,
       %{
         status: 200,
         body:
           Jason.encode!(%{
             "protocol_version" => "1",
             "data" => [
               %{
                 "skill_id" => "deploy",
                 "name" => "deploy",
                 "description" => "Deploy service",
                 "revision" => "rev-1",
                 "artifact_digest" => "sha256:" <> String.duplicate("b", 64),
                 "publication_status" => "ready"
               }
             ],
             "next_cursor" => nil
           })
       }}
    end

    Application.put_env(:sigma_session, :remote_skill_source_options,
      transport: transport,
      max_attempts: 1
    )

    try do
      repository_id = Base.url_encode64(workdir, padding: false)

      conn =
        get(
          conn,
          "/api/v1/skills?repositoryId=#{repository_id}&view=remote&sourceId=remote-one&q=dep&limit=999"
        )

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert response["partial"]

      assert [%{"reference" => "remote-one:deploy", "artifactDigest" => digest}] =
               response["items"]

      assert digest == "sha256:" <> String.duplicate("b", 64)
      assert_receive {:remote_search, %{"limit" => "100", "q" => "dep"}, headers}
      assert headers["authorization"] == "Bearer hidden-token"
      refute conn.resp_body =~ "hidden-token"
      refute conn.resp_body =~ tmp_dir
    after
      restore_env(:agent_dir, previous_agent)
      restore_env(:remote_skill_source_options, previous_source_opts)
    end
  end

  @tag :tmp_dir
  test "lists source-aware skills for a registered repository", %{conn: conn, tmp_dir: tmp_dir} do
    previous = Application.get_env(:sigma_session, :agent_dir)
    previous_global = Application.get_env(:sigma_session, :global_skills_dir)
    Application.put_env(:sigma_session, :agent_dir, Path.join(tmp_dir, "agent"))
    Application.put_env(:sigma_session, :global_skills_dir, Path.join(tmp_dir, "global"))

    try do
      workdir = Path.join(tmp_dir, "repo")
      File.mkdir_p!(Path.join([workdir, ".agents", "skills", "review"]))
      File.mkdir_p!(Path.join([workdir, ".agents", "skills", "broken"]))
      File.mkdir_p!(Path.join(tmp_dir, "agent"))
      RepoManager.add_repo(workdir, name: "Repo")

      File.write!(
        Path.join([workdir, ".agents", "skills", "review", "SKILL.md"]),
        "---\nname: review\ndescription: Review code\n---\nBody"
      )

      File.write!(
        Path.join([workdir, ".agents", "skills", "broken", "SKILL.md"]),
        "---\nname: Broken\n---\nBody"
      )

      File.write!(
        Path.join([tmp_dir, "agent", "settings.json"]),
        Jason.encode!(%{
          "skillSources" => %{
            "remote-one" => %{
              "kind" => "backplane",
              "baseUrl" => "https://skills.example.test",
              "credentialId" => "private-credential",
              "accessContextId" => "client:sigma"
            }
          }
        })
      )

      File.write!(
        Path.join([tmp_dir, "agent", "auth.json"]),
        Jason.encode!(%{
          "private-credential" => %{"type" => "api_key", "key" => "private-token"}
        })
      )

      repository_id = Base.url_encode64(workdir, padding: false)
      conn = get(conn, "/api/v1/skills?repositoryId=#{repository_id}")
      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert [item] = response["items"]
      assert item["name"] == "review"
      assert item["description"] == "Review code"
      assert item["reference"] == "repo:review"
      assert item["status"] == "available"
      assert item["revision"] == nil
      assert item["artifactDigest"] == nil

      assert [%{"code" => "invalid_skill_metadata", "status" => "invalid"}] =
               response["diagnostics"]

      assert [%{"sourceId" => "remote-one", "status" => "configured"}] = response["remoteSources"]
      refute conn.resp_body =~ tmp_dir
      refute conn.resp_body =~ "private-credential"
      refute conn.resp_body =~ "skills.example.test"
    after
      if previous,
        do: Application.put_env(:sigma_session, :agent_dir, previous),
        else: Application.delete_env(:sigma_session, :agent_dir)

      if previous_global,
        do: Application.put_env(:sigma_session, :global_skills_dir, previous_global),
        else: Application.delete_env(:sigma_session, :global_skills_dir)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:sigma_session, key)
  defp restore_env(key, value), do: Application.put_env(:sigma_session, key, value)
end
