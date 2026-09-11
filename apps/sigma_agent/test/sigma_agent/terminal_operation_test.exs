defmodule Sigma.Agent.TerminalOperationTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.Terminals.{Error, FakeBackend, ResourceLedger}

  defmodule BlockingCleanupBackend do
    defstruct [:test_pid]

    def new(opts), do: %__MODULE__{test_pid: Keyword.fetch!(opts, :test_pid)}
    def start(state, _run, _attrs), do: {:ok, state}

    def cleanup(state, _run) do
      send(state.test_pid, {:cleanup_started, self()})

      receive do
        :finish_cleanup -> {{:ok, :confirmed}, state}
      end
    end

    def events(_state), do: []
  end

  defmodule EmptyProvider do
    @behaviour Sigma.Ai.Provider
    def stream(_params), do: []
  end

  defmodule CompactionProvider do
    @behaviour Sigma.Ai.Provider

    def stream(%{purpose: :compaction}) do
      message = %{
        role: :assistant,
        content: [%{type: :text, text: "summary"}],
        model: "mock",
        provider: "mock",
        usage: %{input: 1, output: 1, total_tokens: 2},
        stop_reason: :stop,
        timestamp: System.system_time(:millisecond)
      }

      [{:start, %{message | content: []}}, {:done, :stop, message}]
    end

    def stream(params) do
      test_pid = Keyword.fetch!(params.options, :test_pid)
      cancellation_ref = Keyword.fetch!(params.options, :cancellation_ref)

      Stream.resource(
        fn -> :waiting end,
        fn
          :done ->
            {:halt, :done}

          :waiting ->
            send(test_pid, {:provider_waiting, self()})

            receive do
              {:cancel, ^cancellation_ref} ->
                {[{:provider_error, Sigma.Ai.ProviderError.from_reason(:cancelled)}], :done}
            end
        end,
        fn _state -> :ok end
      )
    end
  end

  setup context do
    root =
      Path.join(
        System.tmp_dir!(),
        "sigma-terminal-operation-#{context.test}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    key = {__MODULE__, make_ref()}
    {:ok, ledger} = start_supervised({ResourceLedger, name: nil, persistence_key: key})

    on_exit(fn ->
      stop_repository(Path.join(root, "repo"))
      :persistent_term.erase(key)
      File.rm_rf!(root)
    end)

    {:ok, root: root, ledger: ledger}
  end

  test "delete closes create admission before cleanup and filesystem mutation", context do
    %{repo: repo, sessions_dir: sessions_dir, source_path: source_path} =
      start_session(context, {BlockingCleanupBackend, test_pid: self()})

    assert {:ok, _terminal} = create_terminal(repo, "source", "create")

    delete =
      Task.async(fn ->
        Sigma.Agent.Runtime.delete_session(repo, "source", sessions_dir,
          terminal_cleanup_timeout_ms: 2_000
        )
      end)

    assert_receive {:cleanup_started, worker}
    assert File.exists?(source_path)
    blocked = Sigma.Agent.Terminals.issue_operation(repo, "source", "late-create", :create)

    assert {:error, %Error{code: :session_draining}} =
             Sigma.Agent.Terminals.create(repo, "source", blocked)

    send(worker, :finish_cleanup)
    assert {:ok, %{deleted: true}} = Task.await(delete)
    refute File.exists?(source_path)
  end

  test "cleanup failure prevents delete and reopens admission", context do
    %{repo: repo, sessions_dir: sessions_dir, source_path: source_path} =
      start_session(context, {FakeBackend, cleanup: :unconfirmed})

    assert {:ok, _terminal} = create_terminal(repo, "source", "create")

    assert {:error, %Error{code: :cleanup_unconfirmed}} =
             Sigma.Agent.Runtime.delete_session(repo, "source", sessions_dir)

    assert File.exists?(source_path)
    operation = Sigma.Agent.Terminals.issue_operation(repo, "source", "after-failure", :create)
    assert {:ok, _terminal} = Sigma.Agent.Terminals.create(repo, "source", operation)
  end

  test "identity-changing rename and adoption reject live resources before mutation", context do
    %{repo: repo, sessions_dir: sessions_dir, source_path: source_path} = start_session(context)
    adopted_dir = Path.join(repo, "adopted")
    assert {:ok, _terminal} = create_terminal(repo, "source", "create")

    assert {:error, %Error{details: %{reason: :terminal_resources_require_close}}} =
             Sigma.Agent.Runtime.rename_session(repo, "source", "renamed", sessions_dir)

    assert {:error, %Error{details: %{reason: :terminal_resources_require_close}}} =
             Sigma.Agent.Runtime.adopt_session(
               repo,
               "source",
               sessions_dir,
               adopted_dir,
               repo
             )

    assert File.exists?(source_path)
    refute File.exists?(Path.join(sessions_dir, "renamed.jsonl"))
    refute File.exists?(Path.join(adopted_dir, "source.jsonl"))
  end

  test "file-operation failure keeps the session usable after acknowledged history cleanup",
       context do
    %{repo: repo, sessions_dir: sessions_dir, source_path: source_path} = start_session(context)
    target_path = Path.join(sessions_dir, "occupied.jsonl")
    :ok = Sigma.Session.Log.persist_event(target_path, {:agent_start, repo})
    assert {:ok, terminal} = create_terminal(repo, "source", "create")
    manager = Sigma.Agent.Runtime.lookup(repo, "source", :terminal_manager)

    assert {:ok, :stopping} =
             Sigma.Agent.Terminals.Manager.shell_exited(
               manager,
               terminal.identity.terminal_id,
               0
             )

    assert {:ok, %{state: :exited}} =
             Sigma.Agent.Terminals.Manager.await_cleanup(
               manager,
               terminal.identity.terminal_id,
               1
             )

    assert {:error, :already_exists} =
             Sigma.Agent.Runtime.rename_session(repo, "source", "occupied", sessions_dir,
               discard_terminal_history: true
             )

    assert File.exists?(source_path)
    assert File.exists?(target_path)
    assert {:ok, %{retained_count: 0}} = Sigma.Agent.Terminals.list(repo, "source")
    assert {:ok, _terminal} = create_terminal(repo, "source", "after-file-failure")
  end

  test "hibernate preserves terminal and stop admission exposes its pin", context do
    %{repo: repo, handle: handle} = start_session(context, FakeBackend, idle_timeout_ms: 40)
    assert {:ok, terminal} = create_terminal(repo, "source", "create")

    assert :ok = Sigma.Agent.SessionProcess.await_hibernating(handle.session, 1_000)
    assert {:ok, %{entries: [^terminal]}} = Sigma.Agent.Terminals.list(repo, "source")

    assert {:error, %Error{details: %{reason: :terminal_resources_present}}} =
             Sigma.Agent.Runtime.can_stop_session(repo, "source")
  end

  test "recreating a deleted session changes incarnation and rejects stale clients", context do
    %{repo: repo, sessions_dir: sessions_dir} = start_session(context)
    assert {:ok, %{session: old_session}} = Sigma.Agent.Terminals.list(repo, "source")

    assert {:ok, %{deleted: true}} =
             Sigma.Agent.Runtime.delete_session(repo, "source", sessions_dir)

    source_path = Path.join(sessions_dir, "source.jsonl")
    :ok = Sigma.Session.Log.persist_event(source_path, {:agent_start, repo})

    {:ok, _handle} =
      Sigma.Agent.Runtime.get_session(repo, "source", opts(context, repo, source_path))

    assert {:ok, %{session: new_session}} = Sigma.Agent.Terminals.list(repo, "source")
    refute new_session.incarnation_id == old_session.incarnation_id

    assert {:error, %Error{code: :stale_session_incarnation}} =
             Sigma.Agent.Runtime.validate_session_incarnation(
               repo,
               "source",
               old_session.incarnation_id
             )
  end

  test "fork model change cancellation and compaction have no terminal side effects", context do
    repo = Path.join(context.root, "repo")
    sessions_dir = Path.join(repo, "sessions")
    source_path = Path.join(sessions_dir, "source.jsonl")
    File.mkdir_p!(sessions_dir)
    :ok = Sigma.Session.Log.persist_event(source_path, {:agent_start, repo})

    for index <- 1..22 do
      message =
        if rem(index, 2) == 1,
          do: Sigma.Agent.Message.user("m#{index}", "user #{index}"),
          else: Sigma.Agent.Message.assistant("m#{index}", %{content: "answer #{index}"})

      :ok = Sigma.Session.Log.persist_event(source_path, {:message_end, message})
    end

    {:ok, source} = Sigma.Session.Log.snapshot(source_path)

    {:ok, handle} =
      Sigma.Agent.Runtime.get_session(
        repo,
        "source",
        opts(context, repo, source_path,
          provider: CompactionProvider,
          messages: source.messages
        )
      )

    assert {:ok, _terminal} = create_terminal(repo, "source", "create")
    assert {:ok, before} = Sigma.Agent.Terminals.list(repo, "source")

    assert {:ok, %{session_id: "fork"}} =
             Sigma.Agent.Runtime.fork_session(
               repo,
               "source",
               "fork",
               sessions_dir,
               :all,
               checkpoint_opts(source_path, "fork")
             )

    assert Sigma.Agent.Runtime.lookup(repo, "fork", :terminal_manager) == nil

    assert {:ok, _entry_id} =
             Sigma.Agent.Runtime.change_model(
               repo,
               "source",
               "mock",
               "next",
               CompactionProvider,
               %{id: "next", api: "mock", provider: "mock"},
               test_pid: self()
             )

    Sigma.Agent.subscribe(handle.agent)
    assert {:accepted, %{turn_id: turn_id}} = Sigma.Agent.prompt(handle.agent, "cancel me")
    assert_receive {:provider_waiting, _provider}, 1_000
    assert {:cancelling, ^turn_id} = Sigma.Agent.cancel(handle.agent)
    assert_receive {:turn_cancelled}, 1_000

    assert {:ok, _result} =
             Sigma.Agent.Runtime.compact_session(
               repo,
               "source",
               sessions_dir,
               checkpoint_opts(source_path, "compact")
             )

    assert {:ok, after_operations} = Sigma.Agent.Terminals.list(repo, "source")
    assert after_operations == before
  end

  defp start_session(context, backend \\ FakeBackend, extra_opts \\ []) do
    repo = Path.join(context.root, "repo")
    sessions_dir = Path.join(repo, "sessions")
    source_path = Path.join(sessions_dir, "source.jsonl")
    File.mkdir_p!(sessions_dir)
    :ok = Sigma.Session.Log.persist_event(source_path, {:agent_start, repo})

    {:ok, handle} =
      Sigma.Agent.Runtime.get_session(
        repo,
        "source",
        opts(context, repo, source_path, Keyword.put(extra_opts, :terminal_backend, backend))
      )

    %{repo: repo, sessions_dir: sessions_dir, source_path: source_path, handle: handle}
  end

  defp opts(context, repo, source_path, extra \\ []) do
    Keyword.merge(
      [
        cwd: repo,
        transcript_path: source_path,
        provider: EmptyProvider,
        model: %{id: "mock", api: "mock", provider: "mock"},
        idle_timeout_ms: 30_000,
        terminal_backend: FakeBackend,
        terminal_resource_ledger: context.ledger
      ],
      extra
    )
  end

  defp create_terminal(repo, session_id, operation_id) do
    operation = Sigma.Agent.Terminals.issue_operation(repo, session_id, operation_id, :create)
    Sigma.Agent.Terminals.create(repo, session_id, operation)
  end

  defp checkpoint_opts(source_path, operation_id) do
    {:ok, snapshot} = Sigma.Session.Log.snapshot(source_path)

    [
      operation_id: operation_id,
      expected_source_revision: length(snapshot.branch_entry_ids) + 1,
      expected_source_leaf: snapshot.active_leaf_id
    ]
  end

  defp stop_repository(repo) do
    case Sigma.Agent.Runtime.lookup(repo, :supervisor) do
      pid when is_pid(pid) ->
        DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)

      nil ->
        :ok
    end
  end
end
