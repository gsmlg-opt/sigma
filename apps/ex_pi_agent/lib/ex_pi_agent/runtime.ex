defmodule PiAgent.Runtime do
  @moduledoc """
  Repository-owned runtime entrypoint for Pi agent sessions.
  """

  def ensure_repository(repo_path, opts \\ []) when is_binary(repo_path) do
    repo_path = normalize_repo_path(repo_path)

    case DynamicSupervisor.start_child(
           PiAgent.DynamicSupervisor,
           {PiAgent.RepositorySupervisor, Keyword.put(opts, :repo_path, repo_path)}
         ) do
      {:ok, supervisor} ->
        {:ok, repository_handle(repo_path, supervisor)}

      {:error, {:already_started, supervisor}} ->
        {:ok, repository_handle(repo_path, supervisor)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def get_session(repo_path, session_id, opts \\ [])
      when is_binary(repo_path) and is_binary(session_id) do
    with {:ok, %{repository: repository}} <- ensure_repository(repo_path),
         {:ok, session_handle} <-
           PiAgent.RepositoryProcess.get_session(repository, session_id, opts) do
      {:ok, session_handle}
    end
  end

  def repository_status(repo_path) when is_binary(repo_path) do
    repo_path = normalize_repo_path(repo_path)

    case lookup(repo_path, :process) do
      nil -> %{repo_path: repo_path, status: :stopped, sessions: %{}}
      pid -> PiAgent.RepositoryProcess.status(pid)
    end
  end

  def session_status(repo_path, session_id)
      when is_binary(repo_path) and is_binary(session_id) do
    repo_path = normalize_repo_path(repo_path)

    case lookup(repo_path, session_id, :session) do
      nil -> %{repo_path: repo_path, session_id: session_id, status: :stopped}
      pid -> PiAgent.SessionProcess.status(pid)
    end
  end

  def normalize_repo_path(repo_path) do
    repo_path
    |> Path.expand()
    |> Path.absname()
  end

  def via(repo_path, role) do
    {:via, Registry, {PiAgent.RepositoryRegistry, {normalize_repo_path(repo_path), role}}}
  end

  def via(repo_path, session_id, role) do
    {:via, Registry,
     {PiAgent.RepositoryRegistry, {normalize_repo_path(repo_path), session_id, role}}}
  end

  def lookup(repo_path, role) do
    case Registry.lookup(PiAgent.RepositoryRegistry, {normalize_repo_path(repo_path), role}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def lookup(repo_path, session_id, role) do
    key = {normalize_repo_path(repo_path), session_id, role}

    case Registry.lookup(PiAgent.RepositoryRegistry, key) do
      [{pid, _}] -> pid
      [] -> nil
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
