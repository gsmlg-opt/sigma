defmodule Sigma.Agent.Terminals.ManagerTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.Terminals.{Error, FakeBackend, Identity, Limits, Manager, ResourceLedger}

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

  test "simultaneous first-open requests converge while startup is pending" do
    runtime = start_runtime(start: :delayed)
    op1 = Manager.issue_operation(runtime.manager, "open-1", :ensure_initial)
    op2 = Manager.issue_operation(runtime.manager, "open-2", :ensure_initial)
    parent = self()

    tasks =
      for operation <- [op1, op2] do
        Task.async(fn ->
          send(parent, {:ready, self()})
          receive do: (:go -> Manager.ensure_initial(runtime.manager, operation))
        end)
      end

    submitters =
      for _ <- tasks,
          do:
            (
              assert_receive {:ready, pid}
              pid
            )

    Enum.each(submitters, &send(&1, :go))

    assert [{:ok, first}, {:ok, second}] = Enum.map(tasks, &Task.await/1)
    assert first.identity == second.identity
    assert first.state == :starting

    assert {:ok, %{retained_count: 1, state_counts: %{starting: 1}}} =
             Manager.list(runtime.manager)
  end

  test "catalog subscribers observe shared lifecycle revisions without terminal content" do
    runtime = start_runtime()
    assert {:ok, session} = Manager.subscribe(runtime.manager)
    operation = Manager.issue_operation(runtime.manager, "subscribed-create", :create)
    assert {:ok, terminal} = Manager.create(runtime.manager, operation)

    assert_receive {:terminal_catalog_changed, ^session, revision}
    assert is_integer(revision)

    close = Manager.issue_operation(runtime.manager, "subscribed-close", :close)

    assert {:ok, :stopping} =
             Manager.close(runtime.manager, terminal.identity.terminal_id, 1, close)

    assert_receive {:terminal_catalog_changed, ^session, next_revision}
    assert next_revision > revision
    refute_received {:terminal_catalog_changed, _session, _revision, _content}
  end

  test "create deduplication and limits are enforced before backend effects" do
    runtime =
      start_runtime(
        limits: Limits.new(max_managed_runs_per_node: 1, max_retained_records_per_node: 4)
      )

    operation = Manager.issue_operation(runtime.manager, "create-1", :create, %{cwd: "/tmp"})
    assert {:ok, terminal} = Manager.create(runtime.manager, operation, %{cwd: "/tmp"})
    assert {:ok, ^terminal} = Manager.create(runtime.manager, operation, %{cwd: "/tmp"})

    second = Manager.issue_operation(runtime.manager, "create-2", :create)
    assert {:error, %Error{code: :capacity_exhausted}} = Manager.create(runtime.manager, second)
    assert {:ok, %{retained_count: 1}} = Manager.list(runtime.manager)
  end

  test "failed startup remains retained without consuming a managed-run slot" do
    runtime = start_runtime(start: {:failed, :backend_unavailable})
    operation = Manager.issue_operation(runtime.manager, "create-failed", :create)

    assert {:error, %Error{code: :startup_failed}} = Manager.create(runtime.manager, operation)

    assert {:ok,
            %{
              retained_count: 1,
              entries: [%{state: :failed, resource_state: :released}]
            }} = Manager.list(runtime.manager)

    assert %{retained_count: 1, managed_run_count: 0, resource_pin?: false} =
             Manager.resource_summary(runtime.manager)
  end

  test "cleanup uncertainty retains tab, pin, and capacity until a truthful retry" do
    runtime = start_runtime(cleanup: [:unconfirmed, :confirmed])
    create = Manager.issue_operation(runtime.manager, "create", :create)
    assert {:ok, terminal} = Manager.create(runtime.manager, create)

    close =
      Manager.issue_operation(runtime.manager, "close", :close, terminal.identity.terminal_id)

    assert {:ok, :stopping} =
             Manager.close(runtime.manager, terminal.identity.terminal_id, 1, close)

    assert {:error, %Error{code: :cleanup_unconfirmed}} =
             Manager.await_cleanup(runtime.manager, terminal.identity.terminal_id, 1)

    assert %{retained_count: 1, managed_run_count: 1, resource_pin?: true} =
             Manager.resource_summary(runtime.manager)

    retry = Manager.issue_operation(runtime.manager, "retry", :retry_cleanup)

    assert {:ok, :stopping} =
             Manager.retry_cleanup(runtime.manager, terminal.identity.terminal_id, 1, retry)

    assert {:ok, :closed} =
             Manager.await_cleanup(runtime.manager, terminal.identity.terminal_id, 1)

    assert {:ok, :closed} =
             Manager.retry_cleanup(runtime.manager, terminal.identity.terminal_id, 1, retry)

    assert {:ok, %{retained_count: 0}} = Manager.list(runtime.manager)

    assert %{retained_count: 0, managed_run_count: 0, resource_pin?: false} =
             Manager.resource_summary(runtime.manager)
  end

  test "natural exit is retained and explicit restart increments generation" do
    runtime = start_runtime()
    create = Manager.issue_operation(runtime.manager, "create", :create)
    assert {:ok, terminal} = Manager.create(runtime.manager, create)

    assert {:ok, :stopping} =
             Manager.shell_exited(runtime.manager, terminal.identity.terminal_id, 0)

    assert {:ok, exited} =
             Manager.await_cleanup(runtime.manager, terminal.identity.terminal_id, 1)

    assert exited.state == :exited
    assert exited.run_generation == 1

    restart = Manager.issue_operation(runtime.manager, "restart", :restart)

    assert {:ok, running} =
             Manager.restart(runtime.manager, terminal.identity.terminal_id, 1, restart)

    assert running.state == :running
    assert running.run_generation == 2
    assert running.identity == terminal.identity
  end

  test "blocked cleanup does not block catalog operations for other terminals" do
    runtime =
      start_runtime(backend: BlockingCleanupBackend, backend_opts: [test_pid: self()])

    create1 = Manager.issue_operation(runtime.manager, "create-1", :create)
    create2 = Manager.issue_operation(runtime.manager, "create-2", :create)
    assert {:ok, first} = Manager.create(runtime.manager, create1)
    assert {:ok, second} = Manager.create(runtime.manager, create2)
    close = Manager.issue_operation(runtime.manager, "close", :close)

    assert {:ok, :stopping} =
             Manager.close(runtime.manager, first.identity.terminal_id, 1, close)

    assert_receive {:cleanup_started, worker}

    assert {:ok, %{entries: [stopping, running]}} = Manager.list(runtime.manager)
    assert stopping.state == :stopping
    assert running.identity == second.identity
    assert running.state == :running

    send(worker, :finish_cleanup)

    assert {:ok, :closed} =
             Manager.await_cleanup(runtime.manager, first.identity.terminal_id, 1)
  end

  test "drain closes creation admission before asynchronous cleanup" do
    runtime =
      start_runtime(backend: BlockingCleanupBackend, backend_opts: [test_pid: self()])

    create = Manager.issue_operation(runtime.manager, "create", :create)
    assert {:ok, terminal} = Manager.create(runtime.manager, create)
    assert {:ok, drain} = Manager.begin_drain(runtime.manager, :delete)
    assert {:ok, [run]} = Manager.cleanup_all(runtime.manager, drain)
    assert run.terminal == terminal.identity
    assert_receive {:cleanup_started, worker}

    blocked = Manager.issue_operation(runtime.manager, "blocked-create", :create)

    assert {:error, %Error{code: :session_draining}} =
             Manager.create(runtime.manager, blocked)

    send(worker, :finish_cleanup)
    assert {:ok, :closed} = Manager.await_cleanup(runtime.manager, run.terminal.terminal_id, 1)
    assert %{retained_count: 0, managed_run_count: 0} = Manager.resource_summary(runtime.manager)
  end

  test "identity drain rejects resources and requires acknowledgement for released history" do
    runtime = start_runtime()
    create = Manager.issue_operation(runtime.manager, "create", :create)
    assert {:ok, terminal} = Manager.create(runtime.manager, create)

    assert {:error,
            %Error{
              code: :session_draining,
              details: %{reason: :terminal_resources_require_close}
            }} = Manager.begin_drain(runtime.manager, :identity_change)

    assert {:ok, :stopping} =
             Manager.shell_exited(runtime.manager, terminal.identity.terminal_id, 0)

    assert {:ok, %{state: :exited}} =
             Manager.await_cleanup(runtime.manager, terminal.identity.terminal_id, 1)

    assert {:error,
            %Error{
              code: :session_draining,
              details: %{reason: :terminal_history_acknowledgement_required}
            }} = Manager.begin_drain(runtime.manager, :identity_change)

    assert {:ok, drain} =
             Manager.begin_drain(runtime.manager, :identity_change,
               discard_terminal_history: true
             )

    assert {:ok, [_run]} = Manager.cleanup_all(runtime.manager, drain)

    assert {:ok, :closed} =
             Manager.await_cleanup(runtime.manager, terminal.identity.terminal_id, 1)
  end

  test "automatic stop admission rejects managed and unconfirmed resources but allows exited history" do
    runtime = start_runtime(cleanup: [:unconfirmed, :confirmed])
    create = Manager.issue_operation(runtime.manager, "create", :create)
    assert {:ok, terminal} = Manager.create(runtime.manager, create)

    assert {:error,
            %Error{code: :session_draining, details: %{reason: :terminal_resources_present}}} =
             Manager.can_stop(runtime.manager)

    assert {:ok, :stopping} =
             Manager.shell_exited(runtime.manager, terminal.identity.terminal_id, 0)

    assert {:error, %Error{code: :cleanup_unconfirmed}} =
             Manager.await_cleanup(runtime.manager, terminal.identity.terminal_id, 1)

    assert {:error,
            %Error{code: :session_draining, details: %{reason: :terminal_resources_present}}} =
             Manager.can_stop(runtime.manager)

    retry = Manager.issue_operation(runtime.manager, "retry", :retry_cleanup)

    assert {:ok, :stopping} =
             Manager.retry_cleanup(runtime.manager, terminal.identity.terminal_id, 1, retry)

    assert {:ok, %{state: :exited}} =
             Manager.await_cleanup(runtime.manager, terminal.identity.terminal_id, 1)

    assert {:ok, %{retained_history?: true}} = Manager.can_stop(runtime.manager)
  end

  test "incarnation validation rejects stale clients" do
    runtime = start_runtime()
    assert :ok = Manager.validate_incarnation(runtime.manager, runtime.session.incarnation_id)

    assert {:error, %Error{code: :stale_session_incarnation}} =
             Manager.validate_incarnation(runtime.manager, "old-incarnation")
  end

  test "rename validates revision and preserves stable creation ordinals" do
    runtime = start_runtime()
    create1 = Manager.issue_operation(runtime.manager, "create-1", :create)
    assert {:ok, first} = Manager.create(runtime.manager, create1)
    revision = snapshot(runtime.manager).revision
    rename = Manager.issue_operation(runtime.manager, "rename", :rename, "Build")

    assert {:ok, renamed} =
             Manager.rename(
               runtime.manager,
               first.identity.terminal_id,
               " Build ",
               revision,
               rename
             )

    assert renamed.label == "Build"

    create2 = Manager.issue_operation(runtime.manager, "create-2", :create)
    assert {:ok, second} = Manager.create(runtime.manager, create2)
    assert second.label == "Terminal 2"

    stale = Manager.issue_operation(runtime.manager, "stale-rename", :rename)

    assert {:error, %Error{code: :stale_catalog_revision}} =
             Manager.rename(
               runtime.manager,
               second.identity.terminal_id,
               "Other",
               revision,
               stale
             )
  end

  test "one worker death is contained and reconciled without automatic restart" do
    runtime = start_runtime()
    create = Manager.issue_operation(runtime.manager, "create", :create)
    assert {:ok, terminal} = Manager.create(runtime.manager, create)
    worker = Manager.worker_pid(runtime.manager, terminal.identity.terminal_id)

    Process.exit(worker, :kill)

    eventually(fn ->
      Manager.worker_pid(runtime.manager, terminal.identity.terminal_id) == nil
    end)

    assert Process.alive?(runtime.manager)

    assert {:ok, %{entries: [%{state: :cleanup_failed, resource_state: :unconfirmed}]}} =
             Manager.list(runtime.manager)

    assert %{resource_pin?: true, managed_run_count: 1} =
             Manager.resource_summary(runtime.manager)
  end

  defp start_runtime(opts \\ []) do
    key = {__MODULE__, make_ref()}
    on_exit(fn -> :persistent_term.erase(key) end)
    {:ok, ledger} = start_supervised({ResourceLedger, name: nil, persistence_key: key})
    {:ok, workers} = start_supervised({DynamicSupervisor, strategy: :one_for_one})

    session =
      Identity.session("repo", "session", Integer.to_string(:erlang.unique_integer([:positive])))

    limits = Keyword.get(opts, :limits, Limits.new())
    backend = Keyword.get(opts, :backend, FakeBackend)
    backend_opts = Keyword.get(opts, :backend_opts, Keyword.take(opts, [:start, :cleanup]))

    {:ok, manager} =
      start_supervised(
        {Manager,
         session: session,
         ledger: ledger,
         worker_supervisor: workers,
         backend: backend,
         backend_opts: backend_opts,
         limits: limits}
      )

    %{manager: manager, ledger: ledger, workers: workers, session: session}
  end

  defp eventually(function, attempts \\ 20)

  defp eventually(function, attempts) when attempts > 0 do
    if function.() do
      :ok
    else
      Process.sleep(10)
      eventually(function, attempts - 1)
    end
  end

  defp eventually(_function, 0), do: flunk("condition did not become true")

  defp snapshot(manager) do
    assert {:ok, snapshot} = Manager.list(manager)
    snapshot
  end
end
