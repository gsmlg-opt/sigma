defmodule Sigma.Agent.Terminals.ResourceLedgerTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.Terminals.{Error, Identity, Limits, ResourceLedger}

  test "atomically enforces node run and retained capacities" do
    {ledger, key} = start_ledger()
    on_exit(fn -> :persistent_term.erase(key) end)
    limits = Limits.new(max_managed_runs_per_node: 1, max_retained_records_per_node: 2)
    run1 = run("session-1", "terminal-1")
    run2 = run("session-2", "terminal-2")

    assert :ok = ResourceLedger.reserve_new(ledger, run1, "op-1", limits)

    assert {:error, %Error{code: :capacity_exhausted, details: %{resource: :managed_runs}}} =
             ResourceLedger.reserve_new(ledger, run2, "op-2", limits)

    assert :ok = ResourceLedger.mark_released(ledger, run1)
    assert :ok = ResourceLedger.reserve_new(ledger, run2, "op-2", limits)

    assert %{retained_count: 1, managed_run_count: 0, resource_pin?: false} =
             ResourceLedger.summary(ledger, run1.terminal.session)

    assert %{retained_count: 1, managed_run_count: 1, resource_pin?: true} =
             ResourceLedger.summary(ledger, run2.terminal.session)
  end

  test "remove refuses reserved, managed, and unconfirmed occupancy" do
    {ledger, key} = start_ledger()
    on_exit(fn -> :persistent_term.erase(key) end)
    limits = Limits.new()
    reserved = run("session", "reserved")
    managed = run("session", "managed")
    unconfirmed = run("session", "unconfirmed")

    for {run, state} <- [{reserved, :reserved}, {managed, :managed}, {unconfirmed, :unconfirmed}] do
      assert :ok = ResourceLedger.reserve_new(ledger, run, "op-#{state}", limits)
    end

    assert :ok = ResourceLedger.mark_managed(ledger, managed)
    assert :ok = ResourceLedger.mark_unconfirmed(ledger, unconfirmed)

    for {run, state} <- [{reserved, :reserved}, {managed, :managed}, {unconfirmed, :unconfirmed}] do
      assert {:error, %Error{code: :invalid_transition, details: %{resource_state: ^state}}} =
               ResourceLedger.remove(ledger, run)
    end

    assert %{retained_count: 3, managed_run_count: 3, resource_pin?: true} =
             ResourceLedger.summary(ledger, reserved.terminal.session)
  end

  test "recovery preserves occupancy and denies starts until reconciliation" do
    {ledger, key} = start_ledger()
    on_exit(fn -> :persistent_term.erase(key) end)
    limits = Limits.new()
    occupied = run("session-1", "terminal-1")
    candidate = run("session-2", "terminal-2")

    assert :ok = ResourceLedger.reserve_new(ledger, occupied, "op-1", limits)
    state = :sys.get_state(ledger)
    Process.unlink(ledger)
    GenServer.stop(ledger)

    assert {:ok, recovered} = ResourceLedger.start_link(name: nil, persistence_key: key)
    Process.unlink(recovered)

    assert %{trustworthy?: false, managed_run_count: 1} =
             ResourceLedger.summary(recovered, occupied.terminal.session)

    assert {:error, %Error{code: :session_unavailable}} =
             ResourceLedger.reserve_new(recovered, candidate, "op-2", limits)

    assert :ok = ResourceLedger.reconcile(recovered, state.entries)
    assert :ok = ResourceLedger.mark_released(recovered, occupied)
    assert :ok = ResourceLedger.reserve_new(recovered, candidate, "op-2", limits)
    GenServer.stop(recovered)
  end

  test "an unverified empty recovery also denies new starts" do
    {ledger, key} = start_ledger()
    on_exit(fn -> :persistent_term.erase(key) end)
    Process.unlink(ledger)
    Process.exit(ledger, :kill)

    assert {:ok, recovered} = ResourceLedger.start_link(name: nil, persistence_key: key)
    Process.unlink(recovered)

    assert {:error, %Error{code: :session_unavailable}} =
             ResourceLedger.reserve_new(recovered, run("session", "terminal"), "op", Limits.new())

    GenServer.stop(recovered)
  end

  defp start_ledger do
    key = {__MODULE__, make_ref()}
    {:ok, ledger} = ResourceLedger.start_link(name: nil, persistence_key: key)
    {ledger, key}
  end

  defp run(session_id, terminal_id) do
    session = Identity.session("repo", session_id, "incarnation")
    Identity.run(Identity.terminal(session, terminal_id), 1)
  end
end
