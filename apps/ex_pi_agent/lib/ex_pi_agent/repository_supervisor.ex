defmodule PiAgent.RepositorySupervisor do
  @moduledoc """
  Supervision subtree for one repository.
  """

  use Supervisor

  def start_link(opts) do
    repo_path = Keyword.fetch!(opts, :repo_path)
    Supervisor.start_link(__MODULE__, opts, name: PiAgent.Runtime.via(repo_path, :supervisor))
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
      {PiAgent.RepositoryProcess, repo_path: repo_path},
      {PiAgent.RepositorySessionDynamicSupervisor, repo_path: repo_path}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
