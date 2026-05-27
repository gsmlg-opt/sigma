defmodule PiWeb.SessionManager do
  @moduledoc """
  Manages per-session supervision subtrees.

  Each session is a `PiWeb.SessionSupervisor` started under `PiWeb.AgentSupervisor`
  (DynamicSupervisor). The manager monitors the supervisor pid and evicts the entry
  when the supervisor goes down, regardless of whether the crash originated in
  PiAgent, PermissionPolicy, or Task.Supervisor.
  """
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns `{:ok, {agent_pid, policy_pid}}` for the given session, starting
  the session supervisor if it isn't already running.
  """
  def get_agent(session_id, opts \\ []) do
    GenServer.call(__MODULE__, {:get_agent, session_id, opts})
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # agents: %{session_id => {sup_pid, agent_pid, policy_pid, monitor_ref}}
    {:ok, %{agents: %{}}}
  end

  @impl true
  def handle_call({:get_agent, session_id, opts}, _from, state) do
    case Map.get(state.agents, session_id) do
      {_sup, agent_pid, policy_pid, _ref} when is_pid(agent_pid) ->
        if Process.alive?(agent_pid) do
          {:reply, {:ok, {agent_pid, policy_pid}}, state}
        else
          start_session(session_id, opts, state)
        end

      nil ->
        start_session(session_id, opts, state)
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    agents =
      Map.reject(state.agents, fn {_id, {_sup, _a, _p, mref}} -> mref == ref end)

    {:noreply, %{state | agents: agents}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp start_session(session_id, opts, state) do
    session_opts = Keyword.put(opts, :session_id, session_id)

    with :ok <- ensure_session_registry_started(),
         {:ok, sup_pid} <-
           DynamicSupervisor.start_child(
             PiWeb.AgentSupervisor,
             {PiWeb.SessionSupervisor, session_opts}
           ) do
      ref = Process.monitor(sup_pid)

      agent_pid =
        GenServer.whereis({:via, Registry, {PiWeb.SessionRegistry, {session_id, :agent}}})

      policy_pid =
        GenServer.whereis({:via, Registry, {PiWeb.SessionRegistry, {session_id, :policy}}})

      entry = {sup_pid, agent_pid, policy_pid, ref}
      {:reply, {:ok, {agent_pid, policy_pid}}, put_in(state.agents[session_id], entry)}
    else
      {:error, {:already_started, sup_pid}} when is_pid(sup_pid) ->
        agent_pid =
          GenServer.whereis({:via, Registry, {PiWeb.SessionRegistry, {session_id, :agent}}})

        policy_pid =
          GenServer.whereis({:via, Registry, {PiWeb.SessionRegistry, {session_id, :policy}}})

        ref = Process.monitor(sup_pid)
        entry = {sup_pid, agent_pid, policy_pid, ref}
        {:reply, {:ok, {agent_pid, policy_pid}}, put_in(state.agents[session_id], entry)}

      error ->
        {:reply, error, state}
    end
  end

  defp ensure_session_registry_started do
    case Process.whereis(PiWeb.SessionRegistry) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        start_session_registry_child()
    end
  end

  defp start_session_registry_child do
    child_spec = {Registry, keys: :unique, name: PiWeb.SessionRegistry}

    case Supervisor.start_child(PiWeb.Supervisor, child_spec) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, :already_present} -> restart_session_registry_child()
      {:error, reason} -> {:error, reason}
    end
  end

  defp restart_session_registry_child do
    case Supervisor.restart_child(PiWeb.Supervisor, PiWeb.SessionRegistry) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
