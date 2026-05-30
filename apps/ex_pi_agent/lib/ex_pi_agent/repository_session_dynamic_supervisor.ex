defmodule PiAgent.RepositorySessionDynamicSupervisor do
  @moduledoc """
  Dynamic supervisor for sessions within one repository.
  """

  use DynamicSupervisor

  def start_link(opts) do
    repo_path = Keyword.fetch!(opts, :repo_path)

    DynamicSupervisor.start_link(__MODULE__, opts,
      name: PiAgent.Runtime.via(repo_path, :sessions)
    )
  end

  def child_spec(opts) do
    repo_path = Keyword.fetch!(opts, :repo_path)

    %{
      id: {__MODULE__, repo_path},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent
    }
  end

  def start_session(repo_path, session_id, opts) do
    repo_path = PiAgent.Runtime.normalize_repo_path(repo_path)

    DynamicSupervisor.start_child(
      PiAgent.Runtime.via(repo_path, :sessions),
      {PiAgent.SessionSupervisor,
       Keyword.merge(opts, repo_path: repo_path, session_id: session_id)}
    )
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
