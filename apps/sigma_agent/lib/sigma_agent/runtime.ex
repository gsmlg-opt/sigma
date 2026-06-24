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

  def normalize_repo_path(repo_path) do
    repo_path
    |> Path.expand()
    |> Path.absname()
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
