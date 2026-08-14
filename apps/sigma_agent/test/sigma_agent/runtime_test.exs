defmodule Sigma.Agent.RuntimeTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  defmodule EmptyProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(_params), do: []
  end

  defmodule CapturingProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params) do
      send(params.options[:test_pid], {:provider_model, params.model.id})
      []
    end
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
    for {_id, pid, :supervisor, [Sigma.Agent.RepositorySupervisor]} <-
          DynamicSupervisor.which_children(Sigma.Agent.DynamicSupervisor),
        Process.alive?(pid),
        repo_under_tmp?(pid, tmp_dir) do
      ref = Process.monitor(pid)
      DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)

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
      {Sigma.Agent.RepositoryProcess, pid, :worker, [Sigma.Agent.RepositoryProcess]} when is_pid(pid) ->
        %{repo_path: repo_path} = Sigma.Agent.RepositoryProcess.status(pid)
        String.starts_with?(repo_path, tmp_dir)

      _ ->
        false
    end)
  end

  test "starts repository supervisors lazily and reuses them per repo", context do
    repo = tmp_repo!(context, "repo-a")

    assert [] = Registry.lookup(Sigma.Agent.RepositoryRegistry, {repo, :process})

    assert {:ok, %{repository: repo_pid1}} = Sigma.Agent.Runtime.ensure_repository(repo)
    assert is_pid(repo_pid1)
    assert [{^repo_pid1, nil}] = Registry.lookup(Sigma.Agent.RepositoryRegistry, {repo, :process})

    assert {:ok, %{repository: repo_pid2}} = Sigma.Agent.Runtime.ensure_repository(repo)
    assert repo_pid1 == repo_pid2
  end

  test "restarts the agent application when the runtime supervisor is missing", context do
    repo = tmp_repo!(context, "repo-app-restart")

    assert :ok = Application.stop(:sigma_agent)
    refute Process.whereis(Sigma.Agent.DynamicSupervisor)

    assert {:ok, %{repository: repo_pid}} = Sigma.Agent.Runtime.ensure_repository(repo)
    assert is_pid(Process.whereis(Sigma.Agent.DynamicSupervisor))
    assert is_pid(repo_pid)
    assert Process.alive?(repo_pid)
  end

  test "isolates repositories and sessions under separate repository subtrees", context do
    repo_a = tmp_repo!(context, "repo-a")
    repo_b = tmp_repo!(context, "repo-b")

    assert {:ok, handle_a} =
             Sigma.Agent.Runtime.get_session(repo_a, "session-a", session_opts(cwd: repo_a))

    assert {:ok, handle_b} =
             Sigma.Agent.Runtime.get_session(repo_b, "session-b", session_opts(cwd: repo_b))

    assert handle_a.repository != handle_b.repository
    assert handle_a.session != handle_b.session
    assert handle_a.agent != handle_b.agent

    assert %{repo_path: ^repo_a, sessions: sessions_a} = Sigma.Agent.Runtime.repository_status(repo_a)
    assert Map.has_key?(sessions_a, "session-a")

    assert %{repo_path: ^repo_b, sessions: sessions_b} = Sigma.Agent.Runtime.repository_status(repo_b)
    assert Map.has_key?(sessions_b, "session-b")
  end

  test "agent crash tears down session subtree without stopping repository process", context do
    repo = tmp_repo!(context, "repo")

    assert {:ok, handle} =
             Sigma.Agent.Runtime.get_session(repo, "session-crash", session_opts(cwd: repo))

    repo_ref = Process.monitor(handle.repository)
    session_ref = Process.monitor(handle.session_supervisor)

    Process.exit(handle.agent, :kill)

    assert_receive {:DOWN, ^session_ref, :process, _pid, _reason}, 1_000
    refute_receive {:DOWN, ^repo_ref, :process, _pid, _reason}, 100

    assert Process.alive?(handle.repository)
    assert [] = Registry.lookup(Sigma.Agent.RepositoryRegistry, {repo, "session-crash", :agent})
  end

  test "session process hibernates after idle timeout", context do
    repo = tmp_repo!(context, "repo")

    assert {:ok, handle} =
             Sigma.Agent.Runtime.get_session(repo, "session-idle", session_opts(cwd: repo))

    assert :ok = Sigma.Agent.SessionProcess.await_hibernating(handle.session, 1_000)
    assert %{status: :hibernating} = Sigma.Agent.SessionProcess.status(handle.session)
  end

  test "session process collects context, messages, and compaction status", context do
    repo = tmp_repo!(context, "repo")
    initial_messages = [Sigma.Agent.Message.user("m1", "hello")]
    session_context = Sigma.Agent.SessionContext.new(agents_context: "Repo instructions")

    assert {:ok, handle} =
             Sigma.Agent.Runtime.get_session(
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
           } = Sigma.Agent.SessionProcess.status(handle.session)

    compact_msg = %Sigma.Agent.Message{
      id: "compaction_1",
      role: :compaction_summary,
      content: "Summary",
      timestamp: System.system_time(:millisecond)
    }

    Sigma.Agent.SessionProcess.record_event(handle.session, {:compact, compact_msg, "m2"}, nil)
    Sigma.Agent.SessionProcess.record_event(handle.session, {:agent_end, [compact_msg]}, nil)

    assert %{
             message_count: 1,
             compaction_count: 1,
             last_compaction: %{summary_id: "compaction_1", first_kept_id: "m2"}
           } = Sigma.Agent.SessionProcess.status(handle.session)
  end

  test "session process acknowledges a persisted state change", context do
    repo = tmp_repo!(context, "repo")
    test_pid = self()

    assert {:ok, handle} =
             Sigma.Agent.Runtime.get_session(
               repo,
               "session-state-change",
               session_opts(
                 cwd: repo,
                 on_state_change: fn received ->
                   send(test_pid, {:persisted, received})
                   :ok
                 end
               )
             )

    event = {:model_change, "anthropic", "opus"}
    selected_model = %{id: "opus", api: "mock-api", provider: "anthropic"}

    assert :ok =
             Sigma.Agent.Runtime.change_model(
               repo,
               "session-state-change",
               "anthropic",
               "opus",
               EmptyProvider,
               selected_model,
               []
             )

    assert_receive {:persisted, ^event}
    assert %{event_count: 1} = Sigma.Agent.SessionProcess.status(handle.session)
    assert %{model: ^selected_model} = :sys.get_state(handle.agent)
  end

  test "session process rejects a state change when persistence fails", context do
    repo = tmp_repo!(context, "repo")

    assert {:ok, handle} =
             Sigma.Agent.Runtime.get_session(
               repo,
               "session-state-failure",
               session_opts(
                 cwd: repo,
                 on_state_change: fn _event -> {:error, :disk_full} end
               )
             )

    selected_model = %{id: "opus", api: "mock-api", provider: "anthropic"}

    assert {:error, :disk_full} =
             Sigma.Agent.Runtime.change_model(
               repo,
               "session-state-failure",
               "anthropic",
               "opus",
               EmptyProvider,
               selected_model,
               []
             )

    assert %{event_count: 0} = Sigma.Agent.SessionProcess.status(handle.session)
    assert %{model: %{id: "mock-model"}} = :sys.get_state(handle.agent)
  end

  test "session process contains persistence callback failures and rolls back", context do
    repo = tmp_repo!(context, "repo")

    assert {:ok, handle} =
             Sigma.Agent.Runtime.get_session(
               repo,
               "session-state-exception",
               session_opts(
                 cwd: repo,
                 on_state_change: fn _event -> raise "persistence unavailable" end
               )
             )

    assert {:error, {:state_change_exception, RuntimeError}} =
             Sigma.Agent.Runtime.change_model(
               repo,
               "session-state-exception",
               "anthropic",
               "opus",
               EmptyProvider,
               %{id: "opus", api: "mock-api", provider: "anthropic"},
               []
             )

    assert Process.alive?(handle.session)
    assert %{event_count: 0} = Sigma.Agent.SessionProcess.status(handle.session)
    assert %{model: %{id: "mock-model"}} = :sys.get_state(handle.agent)
  end

  test "model changes serialize prompts and cannot commit after a caller timeout", context do
    repo = tmp_repo!(context, "repo")
    test_pid = self()

    on_state_change = fn event ->
      send(test_pid, {:state_change_started, self(), event})

      receive do
        :release_state_change -> {:error, :disk_full}
      end
    end

    assert {:ok, handle} =
             Sigma.Agent.Runtime.get_session(
               repo,
               "session-prompt-ordering",
               session_opts(
                 cwd: repo,
                 provider: CapturingProvider,
                 options: [test_pid: test_pid],
                 on_state_change: on_state_change
               )
             )

    change =
      Task.async(fn ->
        Sigma.Agent.Runtime.change_model(
          repo,
          "session-prompt-ordering",
          "anthropic",
          "opus",
          CapturingProvider,
          %{id: "opus", api: "mock-api", provider: "anthropic"},
          test_pid: test_pid
        )
      end)

    assert_receive {:state_change_started, owner, {:model_change, "anthropic", "opus"}}

    Sigma.Agent.prompt(handle.agent, "use the committed model")
    refute_receive {:provider_model, _model_id}, 100

    assert nil == Task.yield(change, 5_100)
    send(owner, :release_state_change)

    assert {:error, :disk_full} = Task.await(change, 1_000)
    assert_receive {:provider_model, "mock-model"}, 1_000
  end

  test "session process serializes concurrent model changes", context do
    repo = tmp_repo!(context, "repo")
    test_pid = self()

    on_state_change = fn
      {:model_change, "openai", "smart"} = event ->
        send(test_pid, {:first_change_started, self(), event})

        receive do
          :release_first_change -> :ok
        end

      {:model_change, "anthropic", "opus"} = event ->
        send(test_pid, {:second_change_started, event})
        :ok
    end

    assert {:ok, handle} =
             Sigma.Agent.Runtime.get_session(
               repo,
               "session-serialized",
               session_opts(cwd: repo, on_state_change: on_state_change)
             )

    first =
      Task.async(fn ->
        Sigma.Agent.Runtime.change_model(
          repo,
          "session-serialized",
          "openai",
          "smart",
          EmptyProvider,
          %{id: "smart", api: "mock-api", provider: "openai"},
          []
        )
      end)

    assert_receive {:first_change_started, owner, {:model_change, "openai", "smart"}}

    second =
      Task.async(fn ->
        send(test_pid, :second_change_requested)

        Sigma.Agent.Runtime.change_model(
          repo,
          "session-serialized",
          "anthropic",
          "opus",
          EmptyProvider,
          %{id: "opus", api: "mock-api", provider: "anthropic"},
          []
        )
      end)

    assert_receive :second_change_requested
    refute_receive {:second_change_started, _event}, 100
    send(owner, :release_first_change)

    assert :ok = Task.await(first)
    assert_receive {:second_change_started, {:model_change, "anthropic", "opus"}}
    assert :ok = Task.await(second)
    assert %{event_count: 2} = Sigma.Agent.SessionProcess.status(handle.session)
  end
end
