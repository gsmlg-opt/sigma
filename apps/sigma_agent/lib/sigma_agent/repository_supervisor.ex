defmodule Sigma.Agent.RepositorySupervisor do
  @moduledoc """
  Supervision subtree for one repository.
  """

  use Supervisor

  def start_link(opts) do
    repo_path = Keyword.fetch!(opts, :repo_path)
    Supervisor.start_link(__MODULE__, opts, name: Sigma.Agent.Runtime.via(repo_path, :supervisor))
  end

  def child_spec(opts) do
    repo_path = Keyword.fetch!(opts, :repo_path)

    %{
      id: {__MODULE__, repo_path},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent
    }
  end

  @impl true
  def init(opts) do
    repo_path = Keyword.fetch!(opts, :repo_path)

    children = [
      {Sigma.Agent.RepositoryProcess, repo_path: repo_path},
      {Sigma.Agent.RepositorySessionDynamicSupervisor, repo_path: repo_path}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
