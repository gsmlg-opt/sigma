defmodule PiWeb.SessionSupervisor do
  @moduledoc """
  Per-session supervision subtree.

  Holds PermissionPolicy, Task.Supervisor, and PiAgent under :one_for_all so
  that any abnormal crash takes down the entire session and prevents orphaned
  processes. max_restarts: 0 ensures the supervisor itself terminates on the
  first crash rather than attempting to revive a partially-broken session.
  """
  use Supervisor

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    Supervisor.start_link(__MODULE__, opts, name: via(session_id))
  end

  def child_spec(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    %{
      id: {__MODULE__, session_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def via(session_id) do
    {:via, Registry, {PiWeb.SessionRegistry, {session_id, :supervisor}}}
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    policy_name = {:via, Registry, {PiWeb.SessionRegistry, {session_id, :policy}}}
    tasks_name = {:via, Registry, {PiWeb.SessionRegistry, {session_id, :tasks}}}
    agent_name = {:via, Registry, {PiWeb.SessionRegistry, {session_id, :agent}}}

    agent_opts =
      opts
      |> Keyword.put(:policy, policy_name)
      |> Keyword.put(:task_supervisor, tasks_name)
      |> Keyword.put(:name, agent_name)

    children = [
      %{
        id: :permission_policy,
        start:
          {PiCoding.PermissionPolicy, :start_link,
           [[name: policy_name, default: :allow, rules: %{}]]},
        restart: :transient
      },
      %{
        id: :task_supervisor,
        start: {Task.Supervisor, :start_link, [[name: tasks_name]]},
        restart: :transient
      },
      %{
        id: :agent,
        start: {PiAgent, :start_link, [agent_opts]},
        restart: :transient
      }
    ]

    Supervisor.init(children, strategy: :one_for_all, max_restarts: 0)
  end
end
