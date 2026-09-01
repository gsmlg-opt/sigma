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

  defmodule BlockingProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params) do
      test_pid = Keyword.fetch!(params.options, :test_pid)
      cancellation_ref = Keyword.fetch!(params.options, :cancellation_ref)
      send(test_pid, {:runtime_provider_waiting, self()})

      receive do
        {:cancel, ^cancellation_ref} ->
          [{:provider_error, Sigma.Ai.ProviderError.from_reason(:cancelled)}]
      end
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

    prompt = Task.async(fn -> Sigma.Agent.prompt(handle.agent, "use the committed model") end)
    refute_receive {:provider_model, _model_id}, 100

    assert nil == Task.yield(change, 5_100)
    send(owner, :release_state_change)

    assert {:error, :disk_full} = Task.await(change, 1_000)
    assert {:accepted, _admission} = Task.await(prompt, 1_000)
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

  test "runtime rejects switch and fork while the source turn is busy without mutation", context do
    repo = tmp_repo!(context, "repo-operations-busy")
    sessions_dir = Path.join(repo, "sessions")
    File.mkdir_p!(sessions_dir)
    source_path = Path.join(sessions_dir, "source.jsonl")
    target_path = Path.join(sessions_dir, "target.jsonl")
    fork_path = Path.join(sessions_dir, "fork.jsonl")
    adopted_sessions_dir = Path.join(repo, "adopted-sessions")

    :ok = Sigma.Session.Log.persist_event(source_path, {:agent_start, repo})
    :ok = Sigma.Session.Log.persist_event(target_path, {:agent_start, repo})
    target_before = File.read!(target_path)

    assert {:ok, handle} =
             Sigma.Agent.Runtime.get_session(
               repo,
               "source",
               session_opts(
                 cwd: repo,
                 provider: BlockingProvider,
                 options: [test_pid: self()],
                 transcript_path: source_path
               )
             )

    assert {:accepted, _admission} = Sigma.Agent.prompt(handle.agent, "stay busy")
    assert_receive {:runtime_provider_waiting, _provider}, 1_000
    source_before = File.read!(source_path)

    assert {:error, :session_busy} =
             Sigma.Agent.Runtime.switch_session(
               repo,
               "source",
               "target",
               sessions_dir
             )

    assert {:error, :session_busy} =
             Sigma.Agent.Runtime.fork_session(repo, "source", "fork", sessions_dir)

    assert {:error, :session_busy} =
             Sigma.Agent.Runtime.adopt_session(
               repo,
               "source",
               sessions_dir,
               adopted_sessions_dir,
               repo
             )

    assert File.read!(source_path) == source_before
    assert File.read!(target_path) == target_before
    refute File.exists?(fork_path)
    refute File.exists?(Path.join(adopted_sessions_dir, "source.jsonl"))
  end

  test "idle runtime switch validates restored state and failed targets leave the source usable", context do
    repo = tmp_repo!(context, "repo-operations-switch")
    sessions_dir = Path.join(repo, "sessions")
    File.mkdir_p!(sessions_dir)
    source_path = Path.join(sessions_dir, "source.jsonl")
    target_path = Path.join(sessions_dir, "target.jsonl")

    :ok = Sigma.Session.Log.persist_event(source_path, {:agent_start, repo})
    :ok = Sigma.Session.Log.persist_event(target_path, {:agent_start, repo})
    {:ok, _entry_id} = Sigma.Session.Log.append_model_change(target_path, "anthropic", "opus")

    assert {:ok, handle} =
             Sigma.Agent.Runtime.get_session(
               repo,
               "source",
               session_opts(cwd: repo, transcript_path: source_path)
             )

    assert {:ok,
            %{
              session_id: "target",
              snapshot: %{provider_id: "anthropic", model_id: "opus"}
            }} =
             Sigma.Agent.Runtime.switch_session(
               repo,
               "source",
               "target",
               sessions_dir
             )

    assert {:error, {:switch_target_invalid, :missing_session_header}} =
             Sigma.Agent.Runtime.switch_session(
               repo,
               "source",
               "missing",
               sessions_dir
             )

    assert Process.alive?(handle.agent)
    assert {:accepted, _admission} = Sigma.Agent.prompt(handle.agent, "still usable")
  end

  test "idle runtime fork flushes the writer and publishes an independent target", context do
    repo = tmp_repo!(context, "repo-operations-fork")
    sessions_dir = Path.join(repo, "sessions")
    File.mkdir_p!(sessions_dir)
    source_path = Path.join(sessions_dir, "source.jsonl")
    target_path = Path.join(sessions_dir, "fork.jsonl")

    :ok = Sigma.Session.Log.persist_event(source_path, {:agent_start, repo})

    assert {:ok, handle} =
             Sigma.Agent.Runtime.get_session(
               repo,
               "source",
               session_opts(cwd: repo, transcript_path: source_path)
             )

    message = Sigma.Agent.Message.user("persisted-before-fork", "accepted")
    :ok = Sigma.Agent.SessionProcess.record_event(handle.session, {:message_end, message}, nil)
    source_before = File.read!(source_path)

    assert {:ok, %{session_id: "fork"}} =
             Sigma.Agent.Runtime.fork_session(repo, "source", "fork", sessions_dir)

    assert File.read!(source_path) == source_before
    assert {:ok, fork_snapshot} = Sigma.Session.Log.snapshot(target_path)
    assert Enum.map(fork_snapshot.messages, & &1.id) == ["persisted-before-fork"]

    fork_message = Sigma.Agent.Message.user("fork-only", "independent")
    :ok = Sigma.Session.Log.persist_event(target_path, {:message_end, fork_message})
    assert {:ok, source_snapshot} = Sigma.Session.Log.snapshot(source_path)
    refute Enum.any?(source_snapshot.messages, &(&1.id == "fork-only"))
  end

  test "session operation lock atomically rejects prompt admission until transition completes", context do
    repo = tmp_repo!(context, "repo-operation-lock")
    sessions_dir = Path.join(repo, "sessions")
    File.mkdir_p!(sessions_dir)
    source_path = Path.join(sessions_dir, "source.jsonl")
    target_path = Path.join(sessions_dir, "target.jsonl")
    :ok = Sigma.Session.Log.persist_event(source_path, {:agent_start, repo})
    :ok = Sigma.Session.Log.persist_event(target_path, {:agent_start, repo})

    assert {:ok, handle} =
             Sigma.Agent.Runtime.get_session(
               repo,
               "source",
               session_opts(cwd: repo, transcript_path: source_path)
             )

    test_pid = self()

    transition =
      Task.async(fn ->
        Sigma.Agent.Runtime.switch_session(repo, "source", "target", sessions_dir,
          validate: fn _snapshot ->
            send(test_pid, {:transition_locked, self()})

            receive do
              :release_transition -> :ok
            end
          end
        )
      end)

    assert_receive {:transition_locked, owner}, 1_000
    assert {:rejected, :session_busy} = Sigma.Agent.prompt(handle.agent, "must not race")

    assert {:error, :session_busy} =
             Sigma.Agent.Runtime.change_model(
               repo,
               "source",
               "anthropic",
               "opus",
               EmptyProvider,
               %{id: "opus", api: "mock-api", provider: "anthropic"},
               []
             )

    send(owner, :release_transition)
    assert {:ok, %{session_id: "target"}} = Task.await(transition)
    assert {:ok, %{provider_id: nil, model_id: nil}} = Sigma.Session.Log.snapshot(source_path)

    assert {:error, {:switch_validation_exception, RuntimeError}} =
             Sigma.Agent.Runtime.switch_session(repo, "source", "target", sessions_dir,
               validate: fn _snapshot -> raise "injected validator failure" end
             )

    assert {:accepted, _admission} = Sigma.Agent.prompt(handle.agent, "lock was released")
  end

  test "repository process restart rediscovers a busy session from the registry", context do
    repo = tmp_repo!(context, "repo-process-restart")
    sessions_dir = Path.join(repo, "sessions")
    File.mkdir_p!(sessions_dir)
    source_path = Path.join(sessions_dir, "source.jsonl")
    :ok = Sigma.Session.Log.persist_event(source_path, {:agent_start, repo})

    assert {:ok, handle} =
             Sigma.Agent.Runtime.get_session(
               repo,
               "source",
               session_opts(
                 cwd: repo,
                 transcript_path: source_path,
                 provider: BlockingProvider,
                 options: [test_pid: self()]
               )
             )

    assert {:accepted, _admission} = Sigma.Agent.prompt(handle.agent, "remain busy")
    assert_receive {:runtime_provider_waiting, _provider}, 1_000
    Process.exit(handle.repository, :kill)
    assert :ok = await_repository_restarted(repo, handle.repository, 1_000)

    assert {:error, :session_busy} =
             Sigma.Agent.Runtime.fork_session(repo, "source", "fork", sessions_dir)

    refute File.exists?(Path.join(sessions_dir, "fork.jsonl"))
  end

  defp await_repository_restarted(repo, old_pid, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_repository_restarted(repo, old_pid, deadline)
  end

  defp do_await_repository_restarted(repo, old_pid, deadline) do
    case Sigma.Agent.Runtime.lookup(repo, :process) do
      pid when is_pid(pid) and pid != old_pid -> :ok
      _pid ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(10)
          do_await_repository_restarted(repo, old_pid, deadline)
        end
    end
  end
end
