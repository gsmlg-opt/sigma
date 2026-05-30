defmodule PiAgent.SessionSupervisor do
  @moduledoc """
  Per-session supervision subtree under a repository.
  """

  use Supervisor

  def start_link(opts) do
    repo_path = Keyword.fetch!(opts, :repo_path)
    session_id = Keyword.fetch!(opts, :session_id)

    Supervisor.start_link(__MODULE__, opts,
      name: PiAgent.Runtime.via(repo_path, session_id, :supervisor)
    )
  end

  def child_spec(opts) do
    repo_path = Keyword.fetch!(opts, :repo_path)
    session_id = Keyword.fetch!(opts, :session_id)

    %{
      id: {__MODULE__, repo_path, session_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @impl true
  def init(opts) do
    repo_path = Keyword.fetch!(opts, :repo_path)
    session_id = Keyword.fetch!(opts, :session_id)

    session_name = PiAgent.Runtime.via(repo_path, session_id, :session)
    policy_name = PiAgent.Runtime.via(repo_path, session_id, :policy)
    tasks_name = PiAgent.Runtime.via(repo_path, session_id, :tasks)
    agent_name = PiAgent.Runtime.via(repo_path, session_id, :agent)
    original_on_event = Keyword.get(opts, :on_event)

    agent_opts =
      opts
      |> Keyword.put(:policy, policy_name)
      |> Keyword.put(:task_supervisor, tasks_name)
      |> Keyword.put(:name, agent_name)
      |> Keyword.put(:on_event, fn event ->
        PiAgent.SessionProcess.record_event(session_name, event, original_on_event)
      end)

    children = [
      %{
        id: :session,
        start:
          {PiAgent.SessionProcess, :start_link,
           [
             [
               name: session_name,
               repo_path: repo_path,
               session_id: session_id,
               idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms, 3_600_000),
               session_context: Keyword.get(opts, :session_context),
               messages: Keyword.get(opts, :messages, [])
             ]
           ]},
        restart: :transient
      },
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
