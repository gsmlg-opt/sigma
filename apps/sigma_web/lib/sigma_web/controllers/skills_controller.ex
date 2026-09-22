defmodule Sigma.Web.SkillsController do
  use Sigma.Web, :controller

  alias Sigma.Agent.SkillInvocationService
  alias Sigma.Session.{ConfigManager, RepoManager, SkillExpander, SkillInvocationStore}
  alias Sigma.Session.Skills.Facade

  def capabilities(conn, _params) do
    remote_sources = Facade.remote_sources()

    json(conn, %{
      "skills" => %{
        "localCatalog" => true,
        "manualInvocation" => true,
        "modelActivation" => true,
        "remoteRead" =>
          Enum.any?(remote_sources, &(&1.enabled? and &1.status in ["configured", "offline"])),
        "remoteSources" => Enum.map(remote_sources, &json_remote_source/1),
        "conditionalPublication" => false
      }
    })
  end

  def index(conn, %{"view" => "remote"} = params) do
    with {:ok, _workdir} <- repository_workdir(params["repositoryId"]),
         {:ok, catalog} <- Facade.remote_catalog(params) do
      json(conn, json_catalog(catalog))
    else
      {:error, :invalid_repository} ->
        json(conn |> put_status(:bad_request), %{error: "invalid repositoryId"})

      {:error, error} ->
        json(conn |> put_status(:unprocessable_entity), %{
          error: Atom.to_string(error.code),
          message: error.message,
          retryable: Map.get(error, :retryable?, false)
        })
    end
  end

  def index(conn, params) do
    with {:ok, workdir} <- repository_workdir(params["repositoryId"]),
         catalog <- Facade.catalog(workdir) do
      json(conn, json_catalog(%{catalog | items: Enum.filter(catalog.items, & &1.enabled?)}))
    else
      {:error, :invalid_repository} ->
        json(conn |> put_status(:bad_request), %{error: "invalid repositoryId"})
    end
  end

  def show(conn, %{"id" => skill_id} = params) do
    with {:ok, workdir} <- repository_workdir(params["repositoryId"]),
         catalog <- Facade.catalog(workdir),
         skill when is_map(skill) <- Enum.find(catalog.items, &(&1.skill_id == skill_id)) do
      json(conn, %{
        "catalogRevision" => catalog.catalog_revision,
        "item" => json_descriptor(skill)
      })
    else
      nil ->
        json(conn |> put_status(:not_found), %{error: "skill_not_found"})

      {:error, :invalid_repository} ->
        json(conn |> put_status(:bad_request), %{error: "invalid repositoryId"})
    end
  end

  def create_invocation(conn, %{"session_id" => session_id} = params) do
    request_key = List.first(get_req_header(conn, "idempotency-key"))
    repository_id = params["repositoryId"]

    with true <- is_binary(request_key) and request_key != "",
         {:ok, workdir} <- repository_workdir(repository_id),
         sessions_dir <- ConfigManager.ensure_sessions_dir(workdir),
         {:ok, event} <-
           SkillInvocationService.invoke(
             Map.merge(params, %{"sessionId" => session_id, "requestKey" => request_key}),
             invocation_context(workdir, sessions_dir)
           ) do
      json(conn |> put_status(:accepted), event.payload)
    else
      false ->
        json(conn |> put_status(:bad_request), %{error: "idempotency_key_required"})

      {:error, :invalid_repository} ->
        json(conn |> put_status(:bad_request), %{error: "invalid repositoryId"})

      {:error, :idempotency_conflict} ->
        json(conn |> put_status(:conflict), %{error: "idempotency_conflict"})

      {:error, reason} ->
        json(conn |> put_status(:unprocessable_entity), %{error: to_string(reason)})
    end
  end

  def show_invocation(
        conn,
        %{"session_id" => session_id, "invocation_id" => invocation_id} = params
      ) do
    with {:ok, workdir} <- repository_workdir(params["repositoryId"]),
         sessions_dir <- ConfigManager.ensure_sessions_dir(workdir),
         {:ok, records} <- SkillInvocationStore.list(sessions_dir, session_id),
         record when is_map(record) <- Enum.find(records, &(&1["invocationId"] == invocation_id)) do
      json(conn, record)
    else
      nil ->
        json(conn |> put_status(:not_found), %{error: "invocation_not_found"})

      {:error, :invalid_repository} ->
        json(conn |> put_status(:bad_request), %{error: "invalid repositoryId"})

      {:error, reason} ->
        json(conn |> put_status(:internal_server_error), %{error: to_string(reason)})
    end
  end

  defp invocation_context(workdir, sessions_dir) do
    %{
      repo_path: workdir,
      sessions_dir: sessions_dir,
      skill_invocation_store: %{
        find: fn session_id, request_key ->
          SkillInvocationStore.find(sessions_dir, session_id, request_key)
        end,
        list: fn session_id -> SkillInvocationStore.list(sessions_dir, session_id) end,
        reserve: fn session_id, record ->
          SkillInvocationStore.reserve(sessions_dir, session_id, record)
        end,
        update: fn session_id, invocation_id, changes ->
          SkillInvocationStore.update(sessions_dir, session_id, invocation_id, changes)
        end
      },
      skill_expander: &SkillExpander.expand/2
    }
  end

  defp repository_workdir(encoded) when is_binary(encoded) do
    with {:ok, workdir} <- Base.url_decode64(encoded, padding: false),
         %{} = repo <- RepoManager.get_repo(workdir) do
      {:ok, Path.expand(repo["path"])}
    else
      _ -> {:error, :invalid_repository}
    end
  end

  defp repository_workdir(_encoded), do: {:error, :invalid_repository}

  defp json_descriptor(skill) do
    %{
      "skillId" => skill.skill_id,
      "sourceId" => skill.source_id,
      "sourceKey" => skill.source_key,
      "name" => skill.name,
      "description" => skill.description,
      "manualOnly" => skill.manual_only?,
      "argumentHint" => skill.argument_hint,
      "enabled" => skill.enabled?,
      "reference" => skill.reference,
      "sourceKind" => skill.source_kind,
      "revision" => skill.revision,
      "artifactDigest" => skill.artifact_digest,
      "status" => skill.status
    }
  end

  defp json_diagnostic(diagnostic) do
    %{"code" => diagnostic.code, "message" => diagnostic.message, "status" => diagnostic.status}
  end

  defp json_remote_source(source) do
    %{
      "sourceId" => source.source_id,
      "name" => source.name,
      "kind" => source.kind,
      "enabled" => source.enabled?,
      "offline" => source.offline?,
      "status" => source.status
    }
  end

  defp json_catalog(catalog) do
    %{
      "catalogRevision" => catalog.catalog_revision,
      "items" => Enum.map(catalog.items, &json_descriptor/1),
      "nextCursor" => catalog.next_cursor,
      "partial" => catalog.partial,
      "diagnostics" => Enum.map(catalog.diagnostics, &json_diagnostic/1),
      "remoteSources" => Enum.map(catalog.remote_sources, &json_remote_source/1)
    }
  end
end
