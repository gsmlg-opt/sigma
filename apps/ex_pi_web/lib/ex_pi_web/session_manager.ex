defmodule PiWeb.SessionManager do
  @moduledoc """
  Manages PiAgent processes for web sessions.

  Agents are started under PiWeb.AgentSupervisor (DynamicSupervisor) so a
  crashed agent does not affect the manager or any sibling sessions. The manager
  holds a monitor ref per agent and evicts the entry on :DOWN.
  """
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns `{:ok, {agent_pid, policy_pid}}` for the given session, starting
  the agent if it isn't already running.
  """
  def get_agent(session_id, opts \\ []) do
    GenServer.call(__MODULE__, {:get_agent, session_id, opts})
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # agents: %{session_id => {agent_pid, policy_pid, monitor_ref}}
    {:ok, %{agents: %{}}}
  end

  @impl true
  def handle_call({:get_agent, session_id, opts}, _from, state) do
    case Map.get(state.agents, session_id) do
      {pid, policy_pid, _ref} when is_pid(pid) ->
        if Process.alive?(pid) do
          {:reply, {:ok, {pid, policy_pid}}, state}
        else
          start_agent(session_id, opts, state)
        end

      nil ->
        start_agent(session_id, opts, state)
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    agents =
      Map.reject(state.agents, fn {_id, {_apid, _ppid, mref}} -> mref == ref end)

    {:noreply, %{state | agents: agents}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp start_agent(session_id, opts, state) do
    agent_opts = Keyword.put(opts, :session_id, session_id)

    case DynamicSupervisor.start_child(PiWeb.AgentSupervisor, {PiAgent, agent_opts}) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        policy_pid = PiAgent.get_policy(pid)
        entry = {pid, policy_pid, ref}
        {:reply, {:ok, {pid, policy_pid}}, put_in(state.agents[session_id], entry)}

      error ->
        {:reply, error, state}
    end
  end
end
