defmodule Sigma.Agent.SessionSupervisor do
  @moduledoc """
  Per-session supervision subtree under a repository.
  """

  use Supervisor

  def start_link(opts) do
    repo_path = Keyword.fetch!(opts, :repo_path)
    session_id = Keyword.fetch!(opts, :session_id)

    Supervisor.start_link(__MODULE__, opts,
      name: Sigma.Agent.Runtime.via(repo_path, session_id, :supervisor)
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

    session_name = Sigma.Agent.Runtime.via(repo_path, session_id, :session)
    policy_name = Sigma.Agent.Runtime.via(repo_path, session_id, :policy)
    tasks_name = Sigma.Agent.Runtime.via(repo_path, session_id, :tasks)
    agent_name = Sigma.Agent.Runtime.via(repo_path, session_id, :agent)
    transcript_path = Keyword.get(opts, :transcript_path)
    writer_name = if transcript_path, do: Sigma.Agent.Runtime.via(repo_path, session_id, :writer)
    permission_config = permission_config(opts)
    original_on_event = Keyword.get(opts, :on_event)

    agent_opts =
      opts
      |> Keyword.put(:policy, policy_name)
      |> Keyword.put(:task_supervisor, tasks_name)
      |> Keyword.put(:name, agent_name)
      |> Keyword.put(:writer, writer_name)
      |> Keyword.put(:on_event, fn event ->
        Sigma.Agent.SessionProcess.record_event(session_name, event, original_on_event)
      end)

    writer_children = writer_children(opts, writer_name, transcript_path, session_id)
    terminal_children = terminal_children(opts, repo_path, session_id)

    children =
      writer_children ++
        [
          %{
            id: :session,
            start:
              {Sigma.Agent.SessionProcess, :start_link,
               [
                 [
                   name: session_name,
                   repo_path: repo_path,
                   session_id: session_id,
                   idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms, 3_600_000),
                   session_context: Keyword.get(opts, :session_context),
                   on_state_change: Keyword.get(opts, :on_state_change),
                   writer: writer_name,
                   messages: Keyword.get(opts, :messages, [])
                 ]
               ]},
            restart: :transient
          },
          %{
            id: :permission_policy,
            start:
              {Sigma.Coding.PermissionPolicy, :start_link,
               [
                 [
                   name: policy_name,
                   default: permission_config.default,
                   rules: permission_config.rules
                 ]
               ]},
            restart: :transient
          },
          %{
            id: :task_supervisor,
            start: {Task.Supervisor, :start_link, [[name: tasks_name]]},
            restart: :transient
          },
          %{
            id: :agent,
            start: {Sigma.Agent, :start_link, [agent_opts]},
            restart: :transient
          }
        ] ++ terminal_children

    Supervisor.init(children, strategy: :one_for_all, max_restarts: 0)
  end

  defp terminal_children(opts, repo_path, session_id) do
    incarnation_id =
      Keyword.get_lazy(opts, :terminal_incarnation_id, fn ->
        Integer.to_string(System.unique_integer([:positive, :monotonic]), 36)
      end)

    session =
      Sigma.Agent.Terminals.Identity.session(
        Sigma.Agent.Runtime.normalize_repo_path(repo_path),
        session_id,
        incarnation_id
      )

    {backend, backend_opts} = terminal_backend(Keyword.get(opts, :terminal_backend))

    [
      {Sigma.Agent.Terminals.Subsystem,
       id: :terminal_subsystem,
       name: Sigma.Agent.Runtime.via(repo_path, session_id, :terminal_subsystem),
       manager_name: Sigma.Agent.Runtime.via(repo_path, session_id, :terminal_manager),
       worker_supervisor: Sigma.Agent.Runtime.via(repo_path, session_id, :terminal_workers),
       session: session,
       ledger: Keyword.get(opts, :terminal_resource_ledger, Sigma.Agent.Terminals.ResourceLedger),
       limits: Keyword.get(opts, :terminal_limits, Sigma.Agent.Terminals.Limits.new()),
       backend: backend,
       backend_opts: backend_opts,
       id_generator:
         Keyword.get(opts, :terminal_id_generator, fn ->
           Integer.to_string(System.unique_integer([:positive, :monotonic]), 36)
         end)}
    ]
  end

  defp terminal_backend({backend, backend_opts}) when is_atom(backend) and is_list(backend_opts),
    do: {backend, backend_opts}

  defp terminal_backend(backend) when is_atom(backend), do: {backend, []}
  defp terminal_backend(_backend), do: {nil, []}

  defp writer_children(_opts, nil, nil, _session_id), do: []

  defp writer_children(opts, writer_name, transcript_path, session_id) do
    writer_mod = Keyword.get(opts, :session_writer_mod, Sigma.Session.Writer)

    writer_opts = [
      name: writer_name,
      storage_id: transcript_path,
      storage_mod: Keyword.get(opts, :storage_mod, Sigma.Session.Storage.JsonlFile),
      session_id: session_id,
      cwd: Keyword.get(opts, :cwd)
    ]

    [
      %{
        id: :session_writer,
        start: {writer_mod, :start_link, [writer_opts]},
        restart: :transient
      }
    ]
  end

  defp permission_config(opts) do
    case Keyword.get(opts, :permission_config) do
      %{default: default, rules: rules}
      when default in [:allow, :ask, :deny] and is_map(rules) ->
        valid_rules =
          Map.filter(rules, fn {name, action} ->
            is_binary(name) and action in [:allow, :ask, :deny]
          end)

        %{default: default, rules: valid_rules}

      _config ->
        %{default: :allow, rules: %{}}
    end
  end
end
