defmodule Sigma.Agent.Terminals.SupervisionTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.Terminals
  alias Sigma.Agent.Terminals.{Error, FakeBackend, ResourceLedger}

  defmodule EmptyProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(_params), do: []
  end

  setup context do
    repo =
      Path.join(
        System.tmp_dir!(),
        "sigma-terminal-supervision-#{context.test}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(repo)

    on_exit(fn ->
      stop_repository(repo)
      File.rm_rf!(repo)
    end)

    {:ok, repo: repo}
  end

  test "terminal branch failure leaves core session alive and reports retained occupancy", %{
    repo: repo
  } do
    assert {:ok, handle} = Sigma.Agent.Runtime.get_session(repo, "session", session_opts(repo))
    operation = Terminals.issue_operation(repo, "session", "create", :create)
    assert {:ok, terminal} = Terminals.create(repo, "session", operation)

    manager = Sigma.Agent.Runtime.lookup(repo, "session", :terminal_manager)
    subsystem = Sigma.Agent.Runtime.lookup(repo, "session", :terminal_subsystem)
    subsystem_ref = Process.monitor(subsystem)
    Process.exit(manager, :kill)

    assert_receive {:DOWN, ^subsystem_ref, :process, ^subsystem, _reason}, 1_000
    assert Process.alive?(handle.agent)
    assert Process.alive?(handle.session)

    assert {:error, %Error{code: :catalog_unavailable}, summary} =
             Terminals.resource_summary(repo, "session")

    assert summary.available? == false
    assert summary.retained_count == 1
    assert summary.managed_run_count == 1
    assert summary.resource_pin?
    assert [{_run, %{resource_state: :unconfirmed}}] = summary.entries

    run = Terminals.Identity.run(terminal.identity, terminal.run_generation)
    :ok = ResourceLedger.mark_released(ResourceLedger, run)
    :ok = ResourceLedger.remove(ResourceLedger, run)
  end

  test "resource summary returns explicit unknown counts while the ledger is down", %{repo: repo} do
    persistence_key = {__MODULE__, make_ref()}
    {:ok, ledger} = ResourceLedger.start_link(name: nil, persistence_key: persistence_key)

    on_exit(fn ->
      if Process.alive?(ledger), do: GenServer.stop(ledger)
      :persistent_term.erase(persistence_key)
    end)

    assert {:ok, _handle} =
             Sigma.Agent.Runtime.get_session(
               repo,
               "session",
               session_opts(repo, terminal_resource_ledger: ledger)
             )

    assert :ok = GenServer.stop(ledger)

    assert {:error, %Error{code: :session_unavailable}, summary} =
             Terminals.resource_summary(repo, "session")

    assert summary == %{
             available?: false,
             entries: :unknown,
             managed_run_count: :unknown,
             resource_pin?: :unknown,
             retained_count: :unknown,
             trustworthy?: false
           }

    manager = Sigma.Agent.Runtime.lookup(repo, "session", :terminal_manager)
    assert Process.alive?(manager)
  end

  test "a core agent crash still tears down the terminal branch and session subtree", %{
    repo: repo
  } do
    assert {:ok, handle} = Sigma.Agent.Runtime.get_session(repo, "session", session_opts(repo))
    subsystem = Sigma.Agent.Runtime.lookup(repo, "session", :terminal_subsystem)
    session_ref = Process.monitor(handle.session_supervisor)
    subsystem_ref = Process.monitor(subsystem)

    Process.exit(handle.agent, :kill)

    assert_receive {:DOWN, ^subsystem_ref, :process, ^subsystem, _reason}, 1_000
    assert_receive {:DOWN, ^session_ref, :process, _session, _reason}, 1_000
    assert Process.alive?(handle.repository)
  end

  defp session_opts(repo, overrides \\ []) do
    Keyword.merge(
      [
        model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
        provider: EmptyProvider,
        cwd: repo,
        idle_timeout_ms: 30_000,
        terminal_backend: FakeBackend
      ],
      overrides
    )
  end

  defp stop_repository(repo) do
    case Sigma.Agent.Runtime.lookup(repo, :supervisor) do
      pid when is_pid(pid) ->
        DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)

      _ ->
        :ok
    end
  end
end
