defmodule PiWeb.SessionSupervisorTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  defmodule EmptyProvider do
    @behaviour PiAi.Provider
    @impl true
    def stream(_params), do: []
  end

  defp unique_session_id, do: "test-sess-#{System.unique_integer([:positive, :monotonic])}"

  defp start_session(session_id) do
    {:ok, sup_pid} =
      DynamicSupervisor.start_child(
        PiWeb.AgentSupervisor,
        {PiWeb.SessionSupervisor,
         [
           session_id: session_id,
           model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
           provider: EmptyProvider
         ]}
      )

    sup_pid
  end

  defp via(session_id, role) do
    {:via, Registry, {PiWeb.SessionRegistry, {session_id, role}}}
  end

  test "killing PermissionPolicy brings down the entire session subtree" do
    session_id = unique_session_id()
    sup_pid = start_session(session_id)

    agent_pid = GenServer.whereis(via(session_id, :agent))
    policy_pid = GenServer.whereis(via(session_id, :policy))
    tasks_pid = GenServer.whereis(via(session_id, :tasks))

    assert is_pid(agent_pid)
    assert is_pid(policy_pid)
    assert is_pid(tasks_pid)

    ref = Process.monitor(sup_pid)
    Process.exit(policy_pid, :kill)

    assert_receive {:DOWN, ^ref, :process, ^sup_pid, _}, 1_000

    refute Process.alive?(agent_pid)
    refute Process.alive?(policy_pid)
    refute Process.alive?(tasks_pid)

    assert [] = Registry.lookup(PiWeb.SessionRegistry, {session_id, :agent})
    assert [] = Registry.lookup(PiWeb.SessionRegistry, {session_id, :policy})
  end

  test "killing PiAgent brings down the entire session subtree" do
    session_id = unique_session_id()
    sup_pid = start_session(session_id)

    agent_pid = GenServer.whereis(via(session_id, :agent))
    policy_pid = GenServer.whereis(via(session_id, :policy))

    ref = Process.monitor(sup_pid)
    Process.exit(agent_pid, :kill)

    assert_receive {:DOWN, ^ref, :process, ^sup_pid, _}, 1_000

    refute Process.alive?(policy_pid)
    assert [] = Registry.lookup(PiWeb.SessionRegistry, {session_id, :policy})
  end

  test "SessionManager rebuilds session after subtree crash" do
    session_id = unique_session_id()

    {:ok, {agent1, _policy1}} = PiWeb.SessionManager.get_agent(session_id)
    assert is_pid(agent1)

    # Grab child pids before killing so we can wait for full propagation
    sup_pid = GenServer.whereis(via(session_id, :supervisor))
    tasks_pid = GenServer.whereis(via(session_id, :tasks))
    sup_ref = Process.monitor(sup_pid)
    tasks_ref = Process.monitor(tasks_pid)

    Process.exit(sup_pid, :kill)
    assert_receive {:DOWN, ^sup_ref, :process, ^sup_pid, _}, 1_000
    # Wait for the task supervisor child to die so its Registry entry is released
    assert_receive {:DOWN, ^tasks_ref, :process, ^tasks_pid, _}, 1_000

    # Allow SessionManager to process the :DOWN from the supervisor
    :sys.get_state(PiWeb.SessionManager)

    {:ok, {agent2, _policy2}} = PiWeb.SessionManager.get_agent(session_id)
    assert is_pid(agent2)
    refute agent1 == agent2
  end
end
