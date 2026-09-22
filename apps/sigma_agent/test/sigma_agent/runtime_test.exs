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

  defmodule ManualCompactionProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(%{purpose: :compaction}) do
      message = %{
        role: :assistant,
        content: [%{type: :text, text: "Manual summary"}],
        model: "mock-model",
        provider: "mock-provider",
        usage: %{input: 20, output: 3, total_tokens: 23},
        stop_reason: :stop,
        timestamp: System.system_time(:millisecond)
      }

      [{:start, %{message | content: []}}, {:done, :stop, message}]
    end
  end

  defmodule FailOperationTerminalStorage do
    @behaviour Sigma.Session.Storage

    @impl true
    def append(_path, %{"type" => "metrics", "fact" => "operation_finished"}),
      do: {:error, :terminal_write_failed}

    def append(path, entry), do: Sigma.Session.Storage.JsonlFile.append(path, entry)

    @impl true
    def read(path), do: Sigma.Session.Storage.JsonlFile.read(path)

    @impl true
    def read_with_diagnostics(path),
      do: Sigma.Session.Storage.JsonlFile.read_with_diagnostics(path)
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
        idle_timeout_ms: 30_000
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
      {Sigma.Agent.RepositoryProcess, pid, :worker, [Sigma.Agent.RepositoryProcess]}
      when is_pid(pid) ->
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
    ledger = Sigma.Agent.Terminals.ResourceLedger
    assert %{entries: %{}, trustworthy?: true} = :sys.get_state(ledger)

    on_exit(fn ->
      assert {:ok, _started} = Application.ensure_all_started(:sigma_agent)
      assert %{entries: %{}} = :sys.get_state(ledger)
      assert :ok = Sigma.Agent.Terminals.ResourceLedger.reconcile(ledger, %{})
    end)

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

    assert %{repo_path: ^repo_a, sessions: sessions_a} =
             Sigma.Agent.Runtime.repository_status(repo_a)

    assert Map.has_key?(sessions_a, "session-a")

    assert %{repo_path: ^repo_b, sessions: sessions_b} =
             Sigma.Agent.Runtime.repository_status(repo_b)

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
             Sigma.Agent.Runtime.get_session(
               repo,
               "session-idle",
               session_opts(cwd: repo, idle_timeout_ms: 60)
             )

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

    assert_receive {:state_change_started, owner, {:model_change, "anthropic", "opus"}}, 5_000

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

    assert_receive {:first_change_started, owner, {:model_change, "openai", "smart"}}, 5_000

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

  test "runtime rejects switch and fork while the source turn is busy without mutation",
       context do
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
    mutation_opts = mutation_opts(source_path, "busy-fork")

    assert {:error, :session_busy} =
             Sigma.Agent.Runtime.switch_session(
               repo,
               "source",
               "target",
               sessions_dir
             )

    assert {:error, :session_busy} =
             Sigma.Agent.Runtime.fork_session(
               repo,
               "source",
               "fork",
               sessions_dir,
               :all,
               mutation_opts
             )

    assert {:error, :session_busy} =
             Sigma.Agent.Runtime.compact_session(
               repo,
               "source",
               sessions_dir,
               Keyword.put(mutation_opts, :operation_id, "busy-compact")
             )

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

  test "manual compaction is durable, leaf-audited, and idempotent", context do
    repo = tmp_repo!(context, "repo-manual-compact")
    sessions_dir = Path.join(repo, "sessions")
    File.mkdir_p!(sessions_dir)
    source_path = Path.join(sessions_dir, "source.jsonl")

    :ok = Sigma.Session.Log.persist_event(source_path, {:agent_start, repo})

    for index <- 1..22 do
      message =
        if rem(index, 2) == 1,
          do: Sigma.Agent.Message.user("m#{index}", "user #{index}"),
          else: Sigma.Agent.Message.assistant("m#{index}", %{content: "assistant #{index}"})

      :ok = Sigma.Session.Log.persist_event(source_path, {:message_end, message})
    end

    assert {:ok, before} = Sigma.Session.Log.snapshot(source_path)

    assert {:ok, _handle} =
             Sigma.Agent.Runtime.get_session(
               repo,
               "source",
               session_opts(
                 cwd: repo,
                 transcript_path: source_path,
                 messages: before.messages,
                 provider: ManualCompactionProvider
               )
             )

    opts = [
      operation_id: "manual-compact-1",
      expected_source_revision: length(before.branch_entry_ids) + 1,
      expected_source_leaf: before.active_leaf_id
    ]

    assert {:ok, result} =
             Sigma.Agent.Runtime.compact_session(repo, "source", sessions_dir, opts)

    assert result.source_leaf_id == before.active_leaf_id
    assert is_binary(result.compaction_id)
    assert is_binary(result.summary_id)

    assert {:ok, duplicate} =
             Sigma.Agent.Runtime.compact_session(repo, "source", sessions_dir, opts)

    assert duplicate == result
    assert {:ok, snapshot} = Sigma.Session.Log.snapshot(source_path)

    assert snapshot.metrics.compactions[result.compaction_id].source_leaf_id ==
             before.active_leaf_id

    assert Enum.count(snapshot.metrics.compactions, fn {_id, fact} ->
             fact.trigger in [:manual, "manual"] and fact.status == :committed
           end) == 1
  end

  test "idle runtime switch validates restored state and failed targets leave the source usable",
       context do
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
    workspace_file = Path.join(repo, "workspace-sentinel.txt")
    File.write!(workspace_file, "user workspace remains unchanged")
    source_path = Path.join(sessions_dir, "source.jsonl")
    target_path = Path.join(sessions_dir, "fork.jsonl")

    :ok = Sigma.Session.Log.persist_event(source_path, {:agent_start, repo})

    assert {:ok, handle} =
             Sigma.Agent.Runtime.get_session(
               repo,
               "source",
               session_opts(cwd: repo, transcript_path: source_path)
             )

    user = Sigma.Agent.Message.user("persisted-before-fork", "accepted")
    assistant = Sigma.Agent.Message.assistant("completed-before-fork", %{content: "done"})
    :ok = Sigma.Agent.SessionProcess.record_event(handle.session, {:message_end, user}, nil)
    :ok = Sigma.Agent.SessionProcess.record_event(handle.session, {:message_end, assistant}, nil)
    source_before = File.read!(source_path)
    opts = mutation_opts(source_path, "idle-fork")

    assert {:ok, %{session_id: "fork"}} =
             Sigma.Agent.Runtime.fork_session(repo, "source", "fork", sessions_dir, :all, opts)

    assert String.starts_with?(File.read!(source_path), source_before)
    assert {:ok, fork_snapshot} = Sigma.Session.Log.snapshot(target_path)

    assert Enum.map(fork_snapshot.messages, & &1.id) == [
             "persisted-before-fork",
             "completed-before-fork"
           ]

    assert File.read!(workspace_file) == "user workspace remains unchanged"

    fork_message = Sigma.Agent.Message.user("fork-only", "independent")
    :ok = Sigma.Session.Log.persist_event(target_path, {:message_end, fork_message})
    assert {:ok, source_snapshot} = Sigma.Session.Log.snapshot(source_path)
    refute Enum.any?(source_snapshot.messages, &(&1.id == "fork-only"))
  end

  test "repository operation ids make completed forks idempotent", context do
    repo = tmp_repo!(context, "repo-operations-idempotent")
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

    operation_id = "fork-request-1"
    opts = mutation_opts(source_path, operation_id)

    assert {:ok, %{session_id: "fork"}} =
             Sigma.Agent.Runtime.fork_session(repo, "source", "fork", sessions_dir, :all, opts)

    marker = Sigma.Agent.Message.user("fork-only", "independent")
    :ok = Sigma.Session.Log.persist_event(target_path, {:message_end, marker})

    Process.exit(handle.repository, :kill)
    assert :ok = await_repository_restarted(repo, handle.repository, 1_000)

    assert {:ok, %{session_id: "fork"}} =
             Sigma.Agent.Runtime.fork_session(repo, "source", "fork", sessions_dir, :all, opts)

    assert {:error, :operation_conflict} =
             Sigma.Agent.Runtime.fork_session(repo, "source", "other", sessions_dir, :all, opts)

    assert {:ok, snapshot} = Sigma.Session.Log.snapshot(target_path)
    assert Enum.any?(snapshot.messages, &(&1.id == "fork-only"))
  end

  test "concurrent clients with the same fork operation id observe one result", context do
    repo = tmp_repo!(context, "repo-concurrent-fork-idempotency")
    sessions_dir = Path.join(repo, "sessions")
    File.mkdir_p!(sessions_dir)
    source_path = Path.join(sessions_dir, "source.jsonl")
    target_path = Path.join(sessions_dir, "fork.jsonl")

    :ok = Sigma.Session.Log.persist_event(source_path, {:agent_start, repo})

    :ok =
      Sigma.Session.Log.persist_event(
        source_path,
        {:message_end, Sigma.Agent.Message.user("source-message", "source")}
      )

    :ok =
      Sigma.Session.Log.persist_event(
        source_path,
        {:message_end, Sigma.Agent.Message.assistant("source-answer", %{content: "done"})}
      )

    assert {:ok, _handle} =
             Sigma.Agent.Runtime.get_session(
               repo,
               "source",
               session_opts(cwd: repo, transcript_path: source_path)
             )

    opts = mutation_opts(source_path, "concurrent-fork-1")
    parent = self()

    submissions =
      for _client <- 1..2 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :submit ->
              Sigma.Agent.Runtime.fork_session(
                repo,
                "source",
                "fork",
                sessions_dir,
                :all,
                opts
              )
          end
        end)
      end

    submitters =
      for _client <- 1..2 do
        assert_receive {:ready, submitter}, 1_000
        submitter
      end

    Enum.each(submitters, &send(&1, :submit))

    assert [{:ok, first_result}, {:ok, second_result}] =
             Enum.map(submissions, &Task.await(&1, 5_000))

    assert first_result == second_result
    result = first_result
    assert result.session_id == "fork"
    assert File.exists?(target_path)

    assert {:ok, operation_results} = Sigma.Session.Log.operation_results(source_path)

    assert [completed] =
             Enum.filter(operation_results, fn result ->
               (result[:operation_id] || result["operation_id"]) == "concurrent-fork-1"
             end)

    assert (completed[:status] || completed["status"]) == :completed
  end

  test "repository restart replays a failed operation without executing it again", context do
    repo = tmp_repo!(context, "repo-operations-failed-idempotent")
    sessions_dir = Path.join(repo, "sessions")
    File.mkdir_p!(sessions_dir)
    source_path = Path.join(sessions_dir, "source.jsonl")
    target_path = Path.join(sessions_dir, "occupied.jsonl")
    :ok = Sigma.Session.Log.persist_event(source_path, {:agent_start, repo})
    :ok = Sigma.Session.Log.persist_event(target_path, {:agent_start, repo})

    assert {:ok, handle} =
             Sigma.Agent.Runtime.get_session(
               repo,
               "source",
               session_opts(cwd: repo, transcript_path: source_path)
             )

    opts = mutation_opts(source_path, "failed-fork-1")

    assert {:error, :already_exists} =
             Sigma.Agent.Runtime.fork_session(
               repo,
               "source",
               "occupied",
               sessions_dir,
               :all,
               opts
             )

    Process.exit(handle.repository, :kill)
    assert :ok = await_repository_restarted(repo, handle.repository, 1_000)
    assert :ok = File.rm(target_path)

    assert {:error, :already_exists} =
             Sigma.Agent.Runtime.fork_session(
               repo,
               "source",
               "occupied",
               sessions_dir,
               :all,
               opts
             )

    refute File.exists?(target_path)
  end

  test "terminal persistence failure is explicit and restart does not repeat the mutation",
       context do
    repo = tmp_repo!(context, "repo-operation-terminal-failure")
    sessions_dir = Path.join(repo, "sessions")
    File.mkdir_p!(sessions_dir)
    source_path = Path.join(sessions_dir, "source.jsonl")
    target_path = Path.join(sessions_dir, "fork.jsonl")
    :ok = Sigma.Session.Log.persist_event(source_path, {:agent_start, repo})

    assert {:ok, handle} =
             Sigma.Agent.Runtime.get_session(
               repo,
               "source",
               session_opts(
                 cwd: repo,
                 transcript_path: source_path,
                 storage_mod: FailOperationTerminalStorage
               )
             )

    opts = mutation_opts(source_path, "terminal-failure-1")

    assert {:error,
            {:operation_result_persistence_failed, {:ok, %{session_id: "fork"}},
             {:storage_append_failed, :terminal_write_failed}}} =
             Sigma.Agent.Runtime.fork_session(
               repo,
               "source",
               "fork",
               sessions_dir,
               :all,
               opts
             )

    assert File.exists?(target_path)
    Process.exit(handle.repository, :kill)
    assert :ok = await_repository_restarted(repo, handle.repository, 1_000)
    assert :ok = File.rm(target_path)

    assert {:error, {:operation_interrupted, "terminal-failure-1"}} =
             Sigma.Agent.Runtime.fork_session(
               repo,
               "source",
               "fork",
               sessions_dir,
               :all,
               opts
             )

    refute File.exists?(target_path)
  end

  test "mutating session operations require identity, revision, and leaf", context do
    repo = tmp_repo!(context, "repo-operation-contract")
    sessions_dir = Path.join(repo, "sessions")
    File.mkdir_p!(sessions_dir)
    source_path = Path.join(sessions_dir, "source.jsonl")
    :ok = Sigma.Session.Log.persist_event(source_path, {:agent_start, repo})

    assert {:error, :operation_id_required} =
             Sigma.Agent.Runtime.fork_session(repo, "source", "fork", sessions_dir)

    assert {:error, :expected_source_revision_required} =
             Sigma.Agent.Runtime.compact_session(repo, "source", sessions_dir,
               operation_id: "compact"
             )

    assert {:error, :expected_source_leaf_required} =
             Sigma.Agent.Runtime.retry_turn(repo, "source", sessions_dir, "missing",
               operation_id: "retry",
               expected_source_revision: 1
             )
  end

  test "retry creates one replacement turn from the persisted checkpoint", context do
    repo = tmp_repo!(context, "repo-retry")
    sessions_dir = Path.join(repo, "sessions")
    File.mkdir_p!(sessions_dir)
    workspace_file = Path.join(repo, "workspace-sentinel.txt")
    File.write!(workspace_file, "retry must not restore files")
    source_path = Path.join(sessions_dir, "source.jsonl")

    first = %{
      Sigma.Agent.Message.user("first", "first prompt")
      | metadata: %{turn_id: "turn-first"}
    }

    second = %{
      Sigma.Agent.Message.user("second", [
        %{type: :text, text: "second prompt"},
        %{type: :image, data: "aW1hZ2U=", mime_type: "image/png"}
      ])
      | metadata: %{turn_id: "turn-second"},
        attachments: [%{"name" => "image.png", "size" => 5}]
    }

    :ok = Sigma.Session.Log.persist_event(source_path, {:agent_start, repo})
    :ok = Sigma.Session.Log.persist_event(source_path, {:message_end, first})

    :ok =
      Sigma.Session.Log.persist_event(
        source_path,
        {:message_end, Sigma.Agent.Message.assistant("first-answer", %{content: "old first"})}
      )

    :ok = Sigma.Session.Log.persist_event(source_path, {:message_end, second})

    :ok =
      Sigma.Session.Log.persist_event(
        source_path,
        {:message_end, Sigma.Agent.Message.assistant("second-answer", %{content: "old second"})}
      )

    assert {:ok, before} = Sigma.Session.Log.snapshot(source_path)

    assert {:ok, handle} =
             Sigma.Agent.Runtime.get_session(
               repo,
               "source",
               session_opts(cwd: repo, transcript_path: source_path, messages: before.messages)
             )

    Sigma.Agent.subscribe(handle.agent)
    operation_id = "retry-op-1"

    assert {:ok, result} =
             Sigma.Agent.Runtime.retry_turn(repo, "source", sessions_dir, "second",
               operation_id: operation_id,
               expected_source_revision: length(before.branch_entry_ids) + 1,
               expected_source_leaf: before.active_leaf_id
             )

    assert result.retry_of_turn_id == "turn-second"
    assert result.turn_id != "turn-second"

    assert {:ok, duplicate} =
             Sigma.Agent.Runtime.retry_turn(repo, "source", sessions_dir, "second",
               operation_id: operation_id,
               expected_source_revision: length(before.branch_entry_ids) + 1,
               expected_source_leaf: before.active_leaf_id
             )

    assert duplicate == result
    assert_receive {:turn_failed, retry_turn_id}, 1_000
    assert retry_turn_id == result.turn_id
    assert {:ok, after_snapshot} = Sigma.Session.Log.snapshot(source_path)

    assert Enum.map(after_snapshot.messages, & &1.id) == [
             "first",
             "first-answer",
             result.message_id
           ]

    assert List.last(after_snapshot.messages).metadata == %{
             "retry_of_turn_id" => "turn-second",
             "turn_id" => result.turn_id,
             "skill_preparations" => []
           }

    assert List.last(after_snapshot.messages).attachments == [
             %{"name" => "image.png", "size" => 5}
           ]

    assert {:ok, entries} = Sigma.Session.Storage.JsonlFile.read(source_path)
    assert Enum.any?(entries, &(get_in(&1, ["message", "id"]) == "second-answer"))

    assert Enum.count(entries, fn entry ->
             get_in(entry, ["message", "metadata", "retry_of_turn_id"]) == "turn-second"
           end) == 1

    assert File.read!(workspace_file) == "retry must not restore files"
  end

  test "retry checkpoint remains addressable after the session is renamed", context do
    repo = tmp_repo!(context, "repo-renamed-retry")
    sessions_dir = Path.join(repo, "sessions")
    File.mkdir_p!(sessions_dir)
    source_path = Path.join(sessions_dir, "source.jsonl")
    renamed_path = Path.join(sessions_dir, "renamed.jsonl")

    user = %{
      Sigma.Agent.Message.user("retry-source", "retry after rename")
      | metadata: %{turn_id: "turn-source"}
    }

    :ok = Sigma.Session.Log.persist_event(source_path, {:agent_start, repo})
    :ok = Sigma.Session.Log.persist_event(source_path, {:message_end, user})

    :ok =
      Sigma.Session.Log.persist_event(
        source_path,
        {:message_end, Sigma.Agent.Message.assistant("source-answer", %{content: "old"})}
      )

    assert {:ok, before} = Sigma.Session.Log.snapshot(source_path)

    assert {:ok, _handle} =
             Sigma.Agent.Runtime.get_session(
               repo,
               "source",
               session_opts(cwd: repo, transcript_path: source_path, messages: before.messages)
             )

    assert {:ok, %{session_id: "renamed"}} =
             Sigma.Agent.Runtime.rename_session(repo, "source", "renamed", sessions_dir)

    refute File.exists?(source_path)
    assert File.exists?(renamed_path)
    assert {:ok, renamed} = Sigma.Session.Log.snapshot(renamed_path)

    assert {:ok, handle} =
             Sigma.Agent.Runtime.get_session(
               repo,
               "renamed",
               session_opts(cwd: repo, transcript_path: renamed_path, messages: renamed.messages)
             )

    Sigma.Agent.subscribe(handle.agent)

    assert {:ok, result} =
             Sigma.Agent.Runtime.retry_turn(
               repo,
               "renamed",
               sessions_dir,
               "retry-source",
               mutation_opts(renamed_path, "renamed-retry-1")
             )

    assert result.retry_of_turn_id == "turn-source"
    assert_receive {:turn_failed, retry_turn_id}, 1_000
    assert retry_turn_id == result.turn_id

    assert {:ok, entries} = Sigma.Session.Storage.JsonlFile.read(renamed_path)

    assert Enum.count(entries, fn entry ->
             get_in(entry, ["message", "metadata", "retry_of_turn_id"]) == "turn-source"
           end) == 1
  end

  test "concurrent retry submissions with one operation id execute one replacement", context do
    repo = tmp_repo!(context, "repo-concurrent-retry")
    sessions_dir = Path.join(repo, "sessions")
    File.mkdir_p!(sessions_dir)
    source_path = Path.join(sessions_dir, "source.jsonl")

    user = %{
      Sigma.Agent.Message.user("retry-source", "retry once")
      | metadata: %{turn_id: "turn-source"}
    }

    :ok = Sigma.Session.Log.persist_event(source_path, {:agent_start, repo})
    :ok = Sigma.Session.Log.persist_event(source_path, {:message_end, user})

    assert {:ok, before} = Sigma.Session.Log.snapshot(source_path)

    assert {:ok, handle} =
             Sigma.Agent.Runtime.get_session(
               repo,
               "source",
               session_opts(cwd: repo, transcript_path: source_path, messages: before.messages)
             )

    Sigma.Agent.subscribe(handle.agent)
    opts = mutation_opts(source_path, "concurrent-retry-1")
    parent = self()

    submissions =
      for _client <- 1..2 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :submit ->
              Sigma.Agent.Runtime.retry_turn(
                repo,
                "source",
                sessions_dir,
                "retry-source",
                opts
              )
          end
        end)
      end

    submitters =
      for _client <- 1..2 do
        assert_receive {:ready, submitter}, 1_000
        submitter
      end

    Enum.each(submitters, &send(&1, :submit))

    assert [{:ok, first_result}, {:ok, second_result}] =
             Enum.map(submissions, &Task.await(&1, 5_000))

    assert first_result == second_result
    result = first_result
    assert result.retry_of_turn_id == "turn-source"
    assert_receive {:turn_failed, retry_turn_id}, 1_000
    assert retry_turn_id == result.turn_id

    assert {:ok, entries} = Sigma.Session.Storage.JsonlFile.read(source_path)

    assert Enum.count(entries, fn entry ->
             get_in(entry, ["message", "metadata", "retry_of_turn_id"]) == "turn-source"
           end) == 1
  end

  test "retry rejects attachment references that no longer have materialized content", context do
    repo = tmp_repo!(context, "repo-retry-missing-attachment")
    sessions_dir = Path.join(repo, "sessions")
    File.mkdir_p!(sessions_dir)
    source_path = Path.join(sessions_dir, "source.jsonl")

    user = %{
      Sigma.Agent.Message.user("retry-user", "review the attachment")
      | metadata: %{turn_id: "turn-original"},
        attachments: [%{"name" => "missing.txt", "size" => 12}]
    }

    :ok = Sigma.Session.Log.persist_event(source_path, {:agent_start, repo})
    :ok = Sigma.Session.Log.persist_event(source_path, {:message_end, user})

    :ok =
      Sigma.Session.Log.persist_event(
        source_path,
        {:message_end, Sigma.Agent.Message.assistant("answer", %{content: "old"})}
      )

    assert {:ok, snapshot} = Sigma.Session.Log.snapshot(source_path)

    assert {:ok, _handle} =
             Sigma.Agent.Runtime.get_session(
               repo,
               "source",
               session_opts(cwd: repo, transcript_path: source_path, messages: snapshot.messages)
             )

    assert {:error, :retry_attachments_unavailable} =
             Sigma.Agent.Runtime.retry_turn(repo, "source", sessions_dir, "retry-user",
               operation_id: "retry-missing-attachment",
               expected_source_revision: length(snapshot.branch_entry_ids) + 1,
               expected_source_leaf: snapshot.active_leaf_id
             )

    assert {:ok, unchanged} = Sigma.Session.Log.snapshot(source_path)
    assert unchanged.active_leaf_id == snapshot.active_leaf_id
    assert unchanged.messages == snapshot.messages
  end

  test "retry requires an explicit current replacement when the original model is unavailable",
       context do
    repo = tmp_repo!(context, "repo-retry-model")
    sessions_dir = Path.join(repo, "sessions")
    File.mkdir_p!(sessions_dir)
    source_path = Path.join(sessions_dir, "source.jsonl")

    user = %{Sigma.Agent.Message.user("retry-user", "again") | metadata: %{turn_id: "turn-old"}}

    :ok = Sigma.Session.Log.persist_event(source_path, {:agent_start, repo})
    {:ok, _entry_id} = Sigma.Session.Log.append_model_change(source_path, "anthropic", "old")
    :ok = Sigma.Session.Log.persist_event(source_path, {:message_end, user})

    :ok =
      Sigma.Session.Log.persist_event(
        source_path,
        {:message_end, Sigma.Agent.Message.assistant("old-answer", %{content: "old"})}
      )

    {:ok, _entry_id} = Sigma.Session.Log.append_model_change(source_path, "openai", "current")
    {:ok, snapshot} = Sigma.Session.Log.snapshot(source_path)

    assert {:ok, _handle} =
             Sigma.Agent.Runtime.get_session(
               repo,
               "source",
               session_opts(cwd: repo, transcript_path: source_path, messages: snapshot.messages)
             )

    opts = mutation_opts(source_path, "retry-original-unavailable")

    assert {:error,
            {:retry_model_selection_required,
             %{
               original_provider_id: "anthropic",
               original_model_id: "old",
               current_provider_id: "openai",
               current_model_id: "current"
             }}} =
             Sigma.Agent.Runtime.retry_turn(repo, "source", sessions_dir, "retry-user", opts)

    replacement_opts =
      source_path
      |> mutation_opts("retry-with-replacement")
      |> Keyword.merge(provider_id: "openai", model_id: "current")

    assert {:ok, %{retry_of_turn_id: "turn-old"}} =
             Sigma.Agent.Runtime.retry_turn(
               repo,
               "source",
               sessions_dir,
               "retry-user",
               replacement_opts
             )
  end

  test "fork rejects a stale source revision or active leaf", context do
    repo = tmp_repo!(context, "repo-operations-conflict")
    sessions_dir = Path.join(repo, "sessions")
    File.mkdir_p!(sessions_dir)
    source_path = Path.join(sessions_dir, "source.jsonl")

    :ok = Sigma.Session.Log.persist_event(source_path, {:agent_start, repo})

    assert {:ok, handle} =
             Sigma.Agent.Runtime.get_session(
               repo,
               "source",
               session_opts(cwd: repo, transcript_path: source_path)
             )

    :ok =
      Sigma.Agent.SessionProcess.record_event(
        handle.session,
        {:message_end, Sigma.Agent.Message.user("checkpoint", "accepted")},
        nil
      )

    :ok =
      Sigma.Agent.SessionProcess.record_event(
        handle.session,
        {:message_end, Sigma.Agent.Message.assistant("checkpoint-answer", %{content: "done"})},
        nil
      )

    assert {:ok, before} = Sigma.Session.Log.snapshot(source_path)
    expected_revision = length(before.branch_entry_ids) + 1
    expected_leaf = before.active_leaf_id

    assert {:ok, %{session_id: "checkpoint-fork"}} =
             Sigma.Agent.Runtime.fork_session(
               repo,
               "source",
               "checkpoint-fork",
               sessions_dir,
               :all,
               operation_id: "checkpoint-fork",
               expected_source_revision: expected_revision,
               expected_source_leaf: expected_leaf
             )

    :ok =
      Sigma.Agent.SessionProcess.record_event(
        handle.session,
        {:message_end, Sigma.Agent.Message.user("newer", "accepted")},
        nil
      )

    assert {:error, {:revision_conflict, %{expected: ^expected_revision}}} =
             Sigma.Agent.Runtime.fork_session(
               repo,
               "source",
               "stale-revision",
               sessions_dir,
               :all,
               operation_id: "stale-revision",
               expected_source_revision: expected_revision,
               expected_source_leaf: before.active_leaf_id
             )

    assert {:error, {:leaf_conflict, %{expected: ^expected_leaf}}} =
             Sigma.Agent.Runtime.fork_session(
               repo,
               "source",
               "stale-leaf",
               sessions_dir,
               :all,
               operation_id: "stale-leaf",
               expected_source_revision: length(before.branch_entry_ids) + 2,
               expected_source_leaf: expected_leaf
             )

    refute File.exists?(Path.join(sessions_dir, "stale-revision.jsonl"))
    refute File.exists?(Path.join(sessions_dir, "stale-leaf.jsonl"))
  end

  test "session operation lock atomically rejects prompt admission until transition completes",
       context do
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

    assert_receive {:transition_locked, owner}, 5_000
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
             Sigma.Agent.Runtime.fork_session(
               repo,
               "source",
               "fork",
               sessions_dir,
               :all,
               mutation_opts(source_path, "busy-after-restart")
             )

    refute File.exists?(Path.join(sessions_dir, "fork.jsonl"))
  end

  defp await_repository_restarted(repo, old_pid, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_repository_restarted(repo, old_pid, deadline)
  end

  defp mutation_opts(source_path, operation_id) do
    {:ok, snapshot} = Sigma.Session.Log.snapshot(source_path)

    [
      operation_id: operation_id,
      expected_source_revision: length(snapshot.branch_entry_ids) + 1,
      expected_source_leaf: snapshot.active_leaf_id
    ]
  end

  defp do_await_repository_restarted(repo, old_pid, deadline) do
    case Sigma.Agent.Runtime.lookup(repo, :process) do
      pid when is_pid(pid) and pid != old_pid ->
        :ok

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
