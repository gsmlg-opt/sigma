defmodule Sigma.Agent.Runtime do
  @moduledoc """
  Repository-owned runtime entrypoint for Sigma agent sessions.
  """

  def ensure_repository(repo_path, opts \\ []) when is_binary(repo_path) do
    repo_path = normalize_repo_path(repo_path)

    with :ok <- ensure_runtime_started() do
      case DynamicSupervisor.start_child(
             Sigma.Agent.DynamicSupervisor,
             {Sigma.Agent.RepositorySupervisor, Keyword.put(opts, :repo_path, repo_path)}
           ) do
        {:ok, supervisor} ->
          {:ok, repository_handle(repo_path, supervisor)}

        {:error, {:already_started, supervisor}} ->
          {:ok, repository_handle(repo_path, supervisor)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def get_session(repo_path, session_id, opts \\ [])
      when is_binary(repo_path) and is_binary(session_id) do
    with {:ok, %{repository: repository}} <- ensure_repository(repo_path),
         {:ok, session_handle} <-
           Sigma.Agent.RepositoryProcess.get_session(repository, session_id, opts) do
      {:ok, session_handle}
    end
  end

  def repository_status(repo_path) when is_binary(repo_path) do
    repo_path = normalize_repo_path(repo_path)

    case lookup(repo_path, :process) do
      nil -> %{repo_path: repo_path, status: :stopped, sessions: %{}}
      pid -> Sigma.Agent.RepositoryProcess.status(pid)
    end
  end

  def session_status(repo_path, session_id)
      when is_binary(repo_path) and is_binary(session_id) do
    repo_path = normalize_repo_path(repo_path)

    case lookup(repo_path, session_id, :session) do
      nil -> %{repo_path: repo_path, session_id: session_id, status: :stopped}
      pid -> Sigma.Agent.SessionProcess.status(pid)
    end
  end

  def reload_context(repo_path, session_id, %Sigma.Agent.SessionContext{} = session_context) do
    case lookup(repo_path, session_id, :agent) do
      agent when is_pid(agent) -> Sigma.Agent.reload_context(agent, session_context)
      nil -> {:error, :session_not_running}
    end
  catch
    :exit, reason -> {:error, {:session_unavailable, reason}}
  end

  def context_preview(repo_path, session_id) do
    case lookup(repo_path, session_id, :agent) do
      agent when is_pid(agent) -> {:ok, Sigma.Agent.context_preview(agent)}
      nil -> {:error, :session_not_running}
    end
  catch
    :exit, reason -> {:error, {:session_unavailable, reason}}
  end

  @doc "Validates an idle transition from one running session to another journal."
  def switch_session(repo_path, current_session_id, target_session_id, sessions_dir, opts \\ [])
      when is_binary(repo_path) and is_binary(current_session_id) and
             is_binary(target_session_id) and is_binary(sessions_dir) do
    session_operation(
      repo_path,
      current_session_id,
      {:switch, target_session_id, sessions_dir, opts}
    )
  end

  @doc "Creates a fork through the repository-owned serialized operation boundary."
  def fork_session(
        repo_path,
        source_session_id,
        target_session_id,
        sessions_dir,
        message_id \\ :all,
        opts \\ []
      )
      when is_binary(repo_path) and is_binary(source_session_id) and
             is_binary(target_session_id) and is_binary(sessions_dir) do
    session_operation(
      repo_path,
      source_session_id,
      {:fork, target_session_id, sessions_dir, message_id, opts}
    )
  end

  @doc "Relocates an idle session file set through the serialized operation boundary."
  def adopt_session(
        repo_path,
        session_id,
        source_sessions_dir,
        target_sessions_dir,
        replacement_cwd,
        opts \\ []
      )
      when is_binary(repo_path) and is_binary(session_id) and
             is_binary(source_sessions_dir) and is_binary(target_sessions_dir) and
             is_binary(replacement_cwd) do
    session_operation(
      repo_path,
      session_id,
      {:adopt, source_sessions_dir, target_sessions_dir, replacement_cwd, opts}
    )
  end

  def rename_session(repo_path, session_id, target_session_id, sessions_dir)
      when is_binary(repo_path) and is_binary(session_id) and is_binary(target_session_id) and
             is_binary(sessions_dir) do
    session_operation(repo_path, session_id, {:rename, target_session_id, sessions_dir, []})
  end

  def delete_session(repo_path, session_id, sessions_dir)
      when is_binary(repo_path) and is_binary(session_id) and is_binary(sessions_dir) do
    session_operation(repo_path, session_id, {:delete, sessions_dir, []})
  end

  @doc """
  Serializes and acknowledges a persisted model change for a running session.
  """
  def change_model(repo_path, session_id, provider_id, model_id, provider, model, options)
      when is_binary(repo_path) and is_binary(session_id) and is_binary(provider_id) and
             is_binary(model_id) and is_atom(provider) and is_map(model) do
    with session_process when is_pid(session_process) <-
           lookup(repo_path, session_id, :session),
         agent when is_pid(agent) <- lookup(repo_path, session_id, :agent) do
      Sigma.Agent.SessionProcess.change_model(
        session_process,
        agent,
        provider_id,
        model_id,
        provider,
        model,
        options
      )
    else
      nil -> {:error, :session_not_running}
    end
  catch
    :exit, reason -> {:error, {:session_unavailable, reason}}
  end

  def normalize_repo_path(repo_path) do
    repo_path
    |> Path.expand()
    |> Path.absname()
  end

  defp session_operation(repo_path, source_session_id, operation) do
    with {:ok, %{repository: repository}} <- ensure_repository(repo_path) do
      Sigma.Agent.RepositoryProcess.session_operation(repository, source_session_id, operation)
    end
  catch
    :exit, reason -> {:error, {:session_unavailable, reason}}
  end

  def via(repo_path, role) do
    {:via, Registry, {Sigma.Agent.RepositoryRegistry, {normalize_repo_path(repo_path), role}}}
  end

  def via(repo_path, session_id, role) do
    {:via, Registry,
     {Sigma.Agent.RepositoryRegistry, {normalize_repo_path(repo_path), session_id, role}}}
  end

  def lookup(repo_path, role) do
    with pid when is_pid(pid) <- Process.whereis(Sigma.Agent.RepositoryRegistry),
         [{target_pid, _}] <-
           Registry.lookup(Sigma.Agent.RepositoryRegistry, {normalize_repo_path(repo_path), role}) do
      target_pid
    else
      _ -> nil
    end
  end

  def lookup(repo_path, session_id, role) do
    key = {normalize_repo_path(repo_path), session_id, role}

    with pid when is_pid(pid) <- Process.whereis(Sigma.Agent.RepositoryRegistry),
         [{target_pid, _}] <- Registry.lookup(Sigma.Agent.RepositoryRegistry, key) do
      target_pid
    else
      _ -> nil
    end
  end

  defp ensure_runtime_started do
    case Process.whereis(Sigma.Agent.DynamicSupervisor) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case Application.ensure_all_started(:sigma_agent) do
          {:ok, _apps} -> ensure_runtime_processes_started()
          {:error, reason} -> {:error, {:application_start_failed, reason}}
        end
    end
  end

  defp ensure_runtime_processes_started do
    with registry_pid when is_pid(registry_pid) <- Process.whereis(Sigma.Agent.RepositoryRegistry),
         supervisor_pid when is_pid(supervisor_pid) <- Process.whereis(Sigma.Agent.DynamicSupervisor) do
      _ = {registry_pid, supervisor_pid}
      :ok
    else
      _ -> {:error, :runtime_not_started}
    end
  end

  defp repository_handle(repo_path, supervisor) do
    %{
      repo_path: repo_path,
      repository_supervisor: supervisor,
      repository: lookup(repo_path, :process),
      session_supervisor: lookup(repo_path, :sessions)
    }
  end
end
