defmodule PiWeb.SessionSupervisorTest do
  use ExUnit.Case, async: false

  alias PiSession.Log
  alias PiSession.Storage.JsonlFile

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

  defp session_process_count(session_id) do
    [:supervisor, :agent, :policy, :tasks]
    |> Enum.map(fn role -> GenServer.whereis(via(session_id, role)) end)
    |> Enum.count(&(is_pid(&1) and Process.alive?(&1)))
  end

  defp supervisor_pid(session_id), do: GenServer.whereis(via(session_id, :supervisor))

  defp wait_for_session_manager_down do
    # Synchronize after the monitored session supervisor exits.
    :sys.get_state(PiWeb.SessionManager)
    :ok
  end

  defp wait_for_session_process_count(session_id, expected) do
    wait_for_session_process_count(
      session_id,
      expected,
      System.monotonic_time(:millisecond) + 1_000
    )
  end

  defp wait_for_session_process_count(session_id, expected, deadline) do
    if session_process_count(session_id) == expected do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("Expected #{expected} live session processes for #{session_id}")
      end

      Process.sleep(10)
      wait_for_session_process_count(session_id, expected, deadline)
    end
  end

  defp stop_session_supervisor(session_id) do
    case supervisor_pid(session_id) do
      pid when is_pid(pid) ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
        wait_for_session_manager_down()
        wait_for_session_process_count(session_id, 0)

      nil ->
        :ok
    end
  end

  defp agent_opts(session_id, storage_path, test_pid, messages \\ []) do
    [
      model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
      provider: PiWeb.MockProvider,
      options: [mock_input: 100_000, mock_response: "mock integration response"],
      on_event: fn event ->
        Log.persist_event(storage_path, event)
        send(test_pid, event)
      end,
      messages: messages,
      cwd: Path.dirname(storage_path),
      session_id: session_id
    ]
  end

  defp run_turn(agent, prompt) do
    PiAgent.prompt(agent, prompt)
    collect_events([])
  end

  defp collect_events(events) do
    receive do
      {:agent_end, _messages} = event -> Enum.reverse([event | events])
      event -> collect_events([event | events])
    after
      5_000 -> flunk("Timeout waiting for agent events")
    end
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
    wait_for_session_process_count(session_id, 0)

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
    wait_for_session_process_count(session_id, 0)

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

  test "SessionManager repairs missing session registry after hot code reload" do
    session_id = unique_session_id()

    try do
      stop_session_registry_child()
      assert Process.whereis(PiWeb.SessionRegistry) == nil

      assert {:ok, {agent_pid, policy_pid}} = PiWeb.SessionManager.get_agent(session_id)

      assert is_pid(Process.whereis(PiWeb.SessionRegistry))
      assert is_pid(agent_pid)
      assert is_pid(policy_pid)
      assert Registry.lookup(PiWeb.SessionRegistry, {session_id, :agent}) == [{agent_pid, nil}]

      stop_session_supervisor(session_id)
    after
      ensure_session_registry_child()
    end
  end

  @tag :tmp_dir
  test "session supervisor, high-usage compaction, tolerant replay, and crash rebuild interact cleanly",
       %{tmp_dir: tmp_dir} do
    session_id = unique_session_id()
    storage_path = Path.join(tmp_dir, "#{session_id}.jsonl")
    before_count = session_process_count(session_id)

    {:ok, {agent1, policy1}} =
      PiWeb.SessionManager.get_agent(session_id, agent_opts(session_id, storage_path, self()))

    events =
      1..11
      |> Enum.flat_map(fn idx -> run_turn(agent1, "high usage turn #{idx}") end)

    assert {:compact, compact_msg, first_kept_id} =
             Enum.find(events, &match?({:compact, _, _}, &1))

    assert compact_msg.role == :compaction_summary
    assert is_binary(first_kept_id)

    assert {:ok, entries_before_crash} = JsonlFile.read(storage_path)

    assert Enum.any?(entries_before_crash, fn
             %{"type" => "compaction", "summary" => summary, "firstKeptId" => ^first_kept_id} ->
               summary == compact_msg.content

             _ ->
               false
           end)

    sup1 = supervisor_pid(session_id)
    sup_ref = Process.monitor(sup1)
    Process.exit(policy1, :kill)
    assert_receive {:DOWN, ^sup_ref, :process, ^sup1, _}, 1_000
    wait_for_session_manager_down()
    wait_for_session_process_count(session_id, before_count)

    assert session_process_count(session_id) == before_count

    File.write!(storage_path, "{torn", [:append])

    assert {:ok, replayed_messages} = Log.replay(storage_path)

    assert [%PiAgent.Message{role: :compaction_summary, content: compact_content} | kept] =
             replayed_messages

    assert compact_content == compact_msg.content

    assert Enum.map(kept, & &1.id) ==
             entries_before_crash
             |> Enum.drop_while(fn entry ->
               get_in(entry, ["message", "id"]) != first_kept_id
             end)
             |> Enum.filter(&(&1["type"] == "message"))
             |> Enum.map(&get_in(&1, ["message", "id"]))

    {:ok, {agent2, _policy2}} =
      PiWeb.SessionManager.get_agent(
        session_id,
        agent_opts(session_id, storage_path, self(), replayed_messages)
      )

    assert agent2 != agent1
    assert %{messages: ^replayed_messages} = :sys.get_state(agent2)

    stop_session_supervisor(session_id)
    assert session_process_count(session_id) == before_count
  end

  defp stop_session_registry_child do
    case Process.whereis(PiWeb.SessionRegistry) do
      nil ->
        :ok

      _pid ->
        :ok = Supervisor.terminate_child(PiWeb.Supervisor, PiWeb.SessionRegistry)
        :ok = Supervisor.delete_child(PiWeb.Supervisor, PiWeb.SessionRegistry)
    end
  end

  defp ensure_session_registry_child do
    case Process.whereis(PiWeb.SessionRegistry) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        {:ok, _pid} =
          Supervisor.start_child(
            PiWeb.Supervisor,
            Registry.child_spec(keys: :unique, name: PiWeb.SessionRegistry)
          )

        :ok
    end
  end
end
