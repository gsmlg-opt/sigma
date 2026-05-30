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

  setup context do
    repo = Path.join([System.tmp_dir!(), "ex-pi-session-supervisor-test", "#{context.test}"])
    File.rm_rf!(repo)
    File.mkdir_p!(repo)

    on_exit(fn ->
      stop_repository_supervisors(repo)
      Process.sleep(50)
      File.rm_rf!(repo)
    end)

    {:ok, repo: repo}
  end

  defp unique_session_id, do: "test-sess-#{System.unique_integer([:positive, :monotonic])}"

  defp start_session(repo, session_id) do
    {:ok, handle} =
      PiAgent.Runtime.get_session(repo, session_id,
        model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
        provider: EmptyProvider,
        cwd: repo
      )

    handle
  end

  defp session_process_count(repo, session_id) do
    [:supervisor, :session, :agent, :policy, :tasks]
    |> Enum.map(fn role -> PiAgent.Runtime.lookup(repo, session_id, role) end)
    |> Enum.count(&(is_pid(&1) and Process.alive?(&1)))
  end

  defp wait_for_session_process_count(repo, session_id, expected) do
    wait_for_session_process_count(
      repo,
      session_id,
      expected,
      System.monotonic_time(:millisecond) + 1_000
    )
  end

  defp wait_for_session_process_count(repo, session_id, expected, deadline) do
    if session_process_count(repo, session_id) == expected do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("Expected #{expected} live session processes for #{session_id}")
      end

      Process.sleep(10)
      wait_for_session_process_count(repo, session_id, expected, deadline)
    end
  end

  defp stop_session_supervisor(repo, session_id) do
    case PiAgent.Runtime.lookup(repo, session_id, :supervisor) do
      pid when is_pid(pid) ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
        wait_for_session_process_count(repo, session_id, 0)

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

  test "killing PermissionPolicy brings down the entire session subtree", %{repo: repo} do
    session_id = unique_session_id()
    handle = start_session(repo, session_id)

    agent_pid = handle.agent
    policy_pid = handle.policy
    tasks_pid = handle.tasks

    assert is_pid(agent_pid)
    assert is_pid(policy_pid)
    assert is_pid(tasks_pid)

    ref = Process.monitor(handle.session_supervisor)
    Process.exit(policy_pid, :kill)

    assert_receive {:DOWN, ^ref, :process, _pid, _}, 1_000
    wait_for_session_process_count(repo, session_id, 0)

    refute Process.alive?(agent_pid)
    refute Process.alive?(policy_pid)
    refute Process.alive?(tasks_pid)

    assert [] = Registry.lookup(PiAgent.RepositoryRegistry, {repo, session_id, :agent})
    assert [] = Registry.lookup(PiAgent.RepositoryRegistry, {repo, session_id, :policy})
  end

  test "killing PiAgent brings down the entire session subtree", %{repo: repo} do
    session_id = unique_session_id()
    handle = start_session(repo, session_id)

    ref = Process.monitor(handle.session_supervisor)
    Process.exit(handle.agent, :kill)

    assert_receive {:DOWN, ^ref, :process, _pid, _}, 1_000
    wait_for_session_process_count(repo, session_id, 0)

    refute Process.alive?(handle.policy)
    assert [] = Registry.lookup(PiAgent.RepositoryRegistry, {repo, session_id, :policy})
  end

  test "Runtime rebuilds session after subtree crash", %{repo: repo} do
    session_id = unique_session_id()

    {:ok, handle1} = PiAgent.Runtime.get_session(repo, session_id, cwd: repo)
    assert is_pid(handle1.agent)

    ref = Process.monitor(handle1.session_supervisor)
    Process.exit(handle1.session_supervisor, :kill)
    assert_receive {:DOWN, ^ref, :process, _pid, _}, 1_000
    wait_for_session_process_count(repo, session_id, 0)

    {:ok, handle2} = PiAgent.Runtime.get_session(repo, session_id, cwd: repo)
    assert is_pid(handle2.agent)
    refute handle1.agent == handle2.agent
  end

  test "runtime keeps repository process when a session subtree dies", %{repo: repo} do
    session_id = unique_session_id()
    handle = start_session(repo, session_id)

    repo_ref = Process.monitor(handle.repository)
    session_ref = Process.monitor(handle.session_supervisor)
    Process.exit(handle.session_supervisor, :kill)

    assert_receive {:DOWN, ^session_ref, :process, _pid, _}, 1_000
    refute_receive {:DOWN, ^repo_ref, :process, _pid, _}, 100
    assert Process.alive?(handle.repository)
  end

  @tag :tmp_dir
  test "session supervisor, high-usage compaction, tolerant replay, and crash rebuild interact cleanly",
       %{tmp_dir: tmp_dir, repo: repo} do
    session_id = unique_session_id()
    storage_path = Path.join(tmp_dir, "#{session_id}.jsonl")
    before_count = session_process_count(repo, session_id)

    {:ok, handle1} =
      PiAgent.Runtime.get_session(
        repo,
        session_id,
        agent_opts(session_id, storage_path, self())
      )

    events =
      1..11
      |> Enum.flat_map(fn idx -> run_turn(handle1.agent, "high usage turn #{idx}") end)

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

    sup_ref = Process.monitor(handle1.session_supervisor)
    Process.exit(handle1.policy, :kill)
    assert_receive {:DOWN, ^sup_ref, :process, _pid, _}, 1_000
    wait_for_session_process_count(repo, session_id, before_count)

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

    {:ok, handle2} =
      PiAgent.Runtime.get_session(
        repo,
        session_id,
        agent_opts(session_id, storage_path, self(), replayed_messages)
      )

    assert handle2.agent != handle1.agent
    assert %{messages: ^replayed_messages} = :sys.get_state(handle2.agent)

    stop_session_supervisor(repo, session_id)
    assert session_process_count(repo, session_id) == before_count
  end

  defp stop_repository_supervisors(repo) do
    for {_id, pid, :supervisor, [PiAgent.RepositorySupervisor]} <-
          DynamicSupervisor.which_children(PiAgent.DynamicSupervisor),
        Process.alive?(pid),
        repo_supervisor_for?(pid, repo) do
      ref = Process.monitor(pid)
      DynamicSupervisor.terminate_child(PiAgent.DynamicSupervisor, pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        500 -> :ok
      end
    end
  end

  defp repo_supervisor_for?(supervisor, repo) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(false, fn
      {PiAgent.RepositoryProcess, pid, :worker, [PiAgent.RepositoryProcess]} when is_pid(pid) ->
        %{repo_path: repo_path} = PiAgent.RepositoryProcess.status(pid)
        repo_path == repo

      _ ->
        false
    end)
  end
end
