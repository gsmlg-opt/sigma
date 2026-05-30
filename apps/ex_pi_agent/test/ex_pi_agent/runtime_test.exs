defmodule PiAgent.RuntimeTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  defmodule EmptyProvider do
    @behaviour PiAi.Provider

    @impl true
    def stream(_params), do: []
  end

  setup context do
    tmp_dir =
      Path.join([
        System.tmp_dir!(),
        "ex-pi-runtime-test",
        "#{context.test}-#{System.unique_integer([:positive])}"
      ])

    File.rm_rf!(tmp_dir)
    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      stop_repository_supervisors(tmp_dir)
      Process.sleep(50)
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  defp tmp_repo!(context, name) do
    repo = Path.join(context.tmp_dir, name)
    File.mkdir_p!(repo)
    repo
  end

  defp session_opts(extra) do
    Keyword.merge(
      [
        model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
        provider: EmptyProvider,
        idle_timeout_ms: 60
      ],
      extra
    )
  end

  defp stop_repository_supervisors(tmp_dir) do
    for {_id, pid, :supervisor, [PiAgent.RepositorySupervisor]} <-
          DynamicSupervisor.which_children(PiAgent.DynamicSupervisor),
        Process.alive?(pid),
        repo_under_tmp?(pid, tmp_dir) do
      ref = Process.monitor(pid)
      DynamicSupervisor.terminate_child(PiAgent.DynamicSupervisor, pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        500 -> :ok
      end
    end
  end

  defp repo_under_tmp?(supervisor, tmp_dir) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(false, fn
      {PiAgent.RepositoryProcess, pid, :worker, [PiAgent.RepositoryProcess]} when is_pid(pid) ->
        %{repo_path: repo_path} = PiAgent.RepositoryProcess.status(pid)
        String.starts_with?(repo_path, tmp_dir)

      _ ->
        false
    end)
  end

  test "starts repository supervisors lazily and reuses them per repo", context do
    repo = tmp_repo!(context, "repo-a")

    assert [] = Registry.lookup(PiAgent.RepositoryRegistry, {repo, :process})

    assert {:ok, %{repository: repo_pid1}} = PiAgent.Runtime.ensure_repository(repo)
    assert is_pid(repo_pid1)
    assert [{^repo_pid1, nil}] = Registry.lookup(PiAgent.RepositoryRegistry, {repo, :process})

    assert {:ok, %{repository: repo_pid2}} = PiAgent.Runtime.ensure_repository(repo)
    assert repo_pid1 == repo_pid2
  end

  test "isolates repositories and sessions under separate repository subtrees", context do
    repo_a = tmp_repo!(context, "repo-a")
    repo_b = tmp_repo!(context, "repo-b")

    assert {:ok, handle_a} =
             PiAgent.Runtime.get_session(repo_a, "session-a", session_opts(cwd: repo_a))

    assert {:ok, handle_b} =
             PiAgent.Runtime.get_session(repo_b, "session-b", session_opts(cwd: repo_b))

    assert handle_a.repository != handle_b.repository
    assert handle_a.session != handle_b.session
    assert handle_a.agent != handle_b.agent

    assert %{repo_path: ^repo_a, sessions: sessions_a} = PiAgent.Runtime.repository_status(repo_a)
    assert Map.has_key?(sessions_a, "session-a")

    assert %{repo_path: ^repo_b, sessions: sessions_b} = PiAgent.Runtime.repository_status(repo_b)
    assert Map.has_key?(sessions_b, "session-b")
  end

  test "agent crash tears down session subtree without stopping repository process", context do
    repo = tmp_repo!(context, "repo")

    assert {:ok, handle} =
             PiAgent.Runtime.get_session(repo, "session-crash", session_opts(cwd: repo))

    repo_ref = Process.monitor(handle.repository)
    session_ref = Process.monitor(handle.session_supervisor)

    Process.exit(handle.agent, :kill)

    assert_receive {:DOWN, ^session_ref, :process, _pid, _reason}, 1_000
    refute_receive {:DOWN, ^repo_ref, :process, _pid, _reason}, 100

    assert Process.alive?(handle.repository)
    assert [] = Registry.lookup(PiAgent.RepositoryRegistry, {repo, "session-crash", :agent})
  end

  test "session process hibernates after idle timeout", context do
    repo = tmp_repo!(context, "repo")

    assert {:ok, handle} =
             PiAgent.Runtime.get_session(repo, "session-idle", session_opts(cwd: repo))

    assert :ok = PiAgent.SessionProcess.await_hibernating(handle.session, 1_000)
    assert %{status: :hibernating} = PiAgent.SessionProcess.status(handle.session)
  end

  test "session process collects context, messages, and compaction status", context do
    repo = tmp_repo!(context, "repo")
    initial_messages = [PiAgent.Message.user("m1", "hello")]
    session_context = PiAgent.SessionContext.new(agents_context: "Repo instructions")

    assert {:ok, handle} =
             PiAgent.Runtime.get_session(
               repo,
               "session-state",
               session_opts(
                 cwd: repo,
                 messages: initial_messages,
                 session_context: session_context
               )
             )

    assert %{
             message_count: 1,
             session_context?: true,
             compaction_count: 0
           } = PiAgent.SessionProcess.status(handle.session)

    compact_msg = %PiAgent.Message{
      id: "compaction_1",
      role: :compaction_summary,
      content: "Summary",
      timestamp: System.system_time(:millisecond)
    }

    PiAgent.SessionProcess.record_event(handle.session, {:compact, compact_msg, "m2"}, nil)
    PiAgent.SessionProcess.record_event(handle.session, {:agent_end, [compact_msg]}, nil)

    assert %{
             message_count: 1,
             compaction_count: 1,
             last_compaction: %{summary_id: "compaction_1", first_kept_id: "m2"}
           } = PiAgent.SessionProcess.status(handle.session)
  end
end
