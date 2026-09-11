defmodule Sigma.Agent.Terminals.ContractsTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.Terminals.{Catalog, Error, Identity, Limits, Operation, OutputFrame}

  @session Identity.session("repo-1", "session-1", "incarnation-1")

  test "simultaneous ensure-initial operations converge while explicit creates remain distinct" do
    catalog =
      Catalog.new(@session, Limits.new(max_retained_tabs_per_session: 3), known_since_ms: 0)

    assert {:ok, first, catalog, :applied} =
             Catalog.ensure_initial(
               catalog,
               Operation.issue("open-a", :ensure_initial, 10),
               "opaque-terminal-a",
               10
             )

    assert first.state == :starting
    assert first.identity.terminal_id == "opaque-terminal-a"
    refute first.identity.terminal_id =~ "open-a"

    assert {:ok, same, catalog, :converged} =
             Catalog.ensure_initial(
               catalog,
               Operation.issue("open-b", :ensure_initial, 10),
               "unused-concurrent-id",
               10
             )

    assert same.identity == first.identity
    assert Catalog.retained_count(catalog) == 1

    assert {:ok, second, catalog, :applied} =
             Catalog.create(
               catalog,
               Operation.issue("create-a", :create, 11),
               "opaque-terminal-b",
               11
             )

    assert {:ok, third, catalog, :applied} =
             Catalog.create(
               catalog,
               Operation.issue("create-b", :create, 12),
               "opaque-terminal-c",
               12
             )

    refute second.identity == third.identity
    assert Catalog.retained_count(catalog) == 3

    assert {:error, %Error{code: :retained_tab_limit}} =
             Catalog.create(
               catalog,
               Operation.issue("create-c", :create, 13),
               "opaque-terminal-d",
               13
             )
  end

  test "mutation retries replay, mismatched reuse conflicts, and expired operations are explicit" do
    limits = Limits.new(mutation_dedup_window_ms: 100, max_operation_records: 2)
    catalog = Catalog.new(@session, limits, known_since_ms: 1_000)
    operation = Operation.issue("create-a", :create, 1_010)

    assert {:ok, terminal, catalog, :applied} =
             Catalog.create(catalog, operation, "opaque-terminal-a", 1_010)

    assert {:ok, replayed, replay_catalog, :replayed} =
             Catalog.create(catalog, operation, "ignored-retry-id", 1_020)

    assert replayed.identity == terminal.identity
    assert replay_catalog == catalog

    assert {:error, %Error{code: :operation_conflict}} =
             Catalog.ensure_initial(
               catalog,
               %{operation | kind: :ensure_initial},
               "ignored-conflict-id",
               1_020
             )

    assert {:error, %Error{code: :operation_expired}} =
             Catalog.create(
               catalog,
               Operation.issue("late", :create, 1_000),
               "opaque-terminal-b",
               1_100
             )

    assert {:error, %Error{code: :operation_outcome_unknown}} =
             Catalog.create(
               catalog,
               Operation.issue("before-history", :create, 999),
               "opaque-terminal-c",
               1_010
             )

    assert {:error, %Error{code: :invalid_operation_ticket}} =
             Catalog.create(
               catalog,
               Operation.issue("from-future", :create, 1_021),
               "opaque-terminal-d",
               1_020
             )
  end

  test "retained count includes terminal lifecycle states while resource pins track resources" do
    limits = Limits.new()

    terminals = [
      terminal("starting", :starting, :reserved),
      terminal("running", :running, :managed),
      terminal("stopping", :stopping, :managed),
      terminal("exited", :exited, :released),
      terminal("failed", :failed, :released),
      terminal("cleanup", :cleanup_failed, :unconfirmed)
    ]

    catalog = Catalog.from_terminals(@session, terminals, limits)

    assert Catalog.retained_count(catalog) == 6
    assert Catalog.managed_run_count(catalog) == 4
    assert Catalog.resource_pin?(catalog)

    assert Catalog.state_counts(catalog) == %{
             starting: 1,
             running: 1,
             stopping: 1,
             exited: 1,
             failed: 1,
             cleanup_failed: 1
           }
  end

  test "lifecycle transitions retain exit state, preserve uncertain cleanup, and fence restart generations" do
    starting = terminal("terminal", :starting, :reserved)
    assert {:ok, running} = Catalog.transition(starting, :started)
    assert running.state == :running
    assert running.resource_state == :managed

    assert {:ok, stopping} = Catalog.transition(running, {:shell_exited, 17})
    assert stopping.exit_status == 17
    assert stopping.state == :stopping

    assert {:ok, uncertain} = Catalog.transition(stopping, {:cleanup_failed, :deadline})
    assert uncertain.state == :cleanup_failed
    assert uncertain.resource_state == :unconfirmed
    assert {:error, %Error{}} = Catalog.transition(uncertain, :restart)

    assert {:ok, exited} = Catalog.transition(stopping, :cleanup_confirmed)
    assert exited.state == :exited
    assert exited.resource_state == :released

    assert {:ok, restarted} = Catalog.transition(exited, :restart)
    assert restarted.run_generation == exited.run_generation + 1
    assert restarted.state == :starting
    assert restarted.exit_status == nil
  end

  test "startup failure is retained only after cleanup and cleanup failure can be retried" do
    starting = terminal("terminal", :starting, :reserved)
    assert {:ok, stopping} = Catalog.transition(starting, {:startup_failed, :enoent})
    assert stopping.failure_reason == :enoent
    assert stopping.cleanup_disposition == :failed

    assert {:ok, cleanup_failed} = Catalog.transition(stopping, {:cleanup_failed, :deadline})
    assert cleanup_failed.resource_state == :unconfirmed
    assert {:ok, retrying} = Catalog.transition(cleanup_failed, :retry_cleanup)
    assert retrying.state == :stopping
    assert retrying.cleanup_disposition == :failed

    assert {:ok, failed} = Catalog.transition(retrying, :cleanup_confirmed)
    assert failed.state == :failed
    assert failed.resource_state == :released
    assert failed.failure_reason == :enoent
  end

  test "rejects lifecycle events outside their explicit source states" do
    for state <- [:starting, :stopping, :exited, :failed, :cleanup_failed] do
      assert {:error, %Error{code: :invalid_transition}} =
               Catalog.transition(terminal("terminal", state, resource_state(state)), {
                 :shell_exited,
                 0
               })
    end

    for state <- [:starting, :running, :exited, :failed, :cleanup_failed] do
      assert {:error, %Error{code: :invalid_transition}} =
               Catalog.transition(
                 terminal("terminal", state, resource_state(state)),
                 :cleanup_confirmed
               )
    end

    for state <- [:starting, :running, :stopping, :cleanup_failed] do
      assert {:error, %Error{code: :invalid_transition}} =
               Catalog.transition(terminal("terminal", state, resource_state(state)), :restart)
    end

    assert {:ok, close_pending} =
             Catalog.transition(terminal("terminal", :running, :managed), :close_requested)

    assert close_pending.cleanup_disposition == :close

    assert {:error, %Error{code: :invalid_transition}} =
             Catalog.transition(close_pending, :cleanup_confirmed)
  end

  test "rejects invalid or reused server allocation identities" do
    catalog = Catalog.new(@session, Limits.new())

    assert {:error, %Error{code: :invalid_terminal_identity}} =
             Catalog.create(catalog, Operation.issue("create-a", :create, 0), "", 0)

    assert {:ok, _terminal, catalog, :applied} =
             Catalog.create(catalog, Operation.issue("create-b", :create, 0), "opaque", 0)

    assert {:error, %Error{code: :terminal_identity_conflict}} =
             Catalog.create(catalog, Operation.issue("create-c", :create, 0), "opaque", 0)
  end

  test "dimensions and operation history bounds are injected explicitly" do
    limits = Limits.new(max_operation_records: 1, min_columns: 10, max_columns: 20)
    catalog = Catalog.new(@session, limits)

    assert Limits.valid_dimensions?(limits, 10, 1)
    refute Limits.valid_dimensions?(limits, 9, 1)

    assert {:ok, _terminal, catalog, :applied} =
             Catalog.create(catalog, Operation.issue("first", :create, 0), "opaque-first", 0)

    assert {:error, %Error{code: :operation_history_full}} =
             Catalog.create(catalog, Operation.issue("second", :create, 1), "opaque-second", 1)
  end

  test "catalog pages and output frames are explicitly bounded" do
    limits = Limits.new(max_catalog_page_entries: 1, max_output_frame_bytes: 4)

    catalog =
      Catalog.from_terminals(
        @session,
        [terminal("a", :exited, :released), terminal("b", :failed, :released)],
        limits
      )

    assert {:ok, %{entries: [_], next_cursor: cursor, retained_count: 2}} =
             Catalog.snapshot(catalog, 0)

    assert cursor == %{offset: 1, revision: 2}
    assert {:ok, %{entries: [_], next_cursor: nil}} = Catalog.snapshot(catalog, cursor)

    assert {:error, %Error{code: :stale_catalog_revision}} =
             Catalog.snapshot(%{catalog | revision: 3}, cursor)

    run = Identity.run(Identity.terminal(@session, "terminal-a"), 1)

    assert {:ok, %OutputFrame{sequence: 1, bytes: <<0, 255, 1, 2>>}} =
             OutputFrame.new(run, 1, <<0, 255, 1, 2>>, limits)

    assert {:error, %Error{code: :output_frame_too_large}} =
             OutputFrame.new(run, 2, "12345", limits)
  end

  test "error parsing never creates atoms" do
    before = :erlang.system_info(:atom_count)

    for index <- 1..200 do
      assert %Error{code: :unknown} = Error.from_code("attacker-code-#{index}")
    end

    assert :erlang.system_info(:atom_count) == before
  end

  defp terminal(id, state, resource_state) do
    Catalog.terminal(Identity.terminal(@session, id), id, state, resource_state)
  end

  defp resource_state(state) when state in [:starting], do: :reserved
  defp resource_state(state) when state in [:running, :stopping], do: :managed
  defp resource_state(state) when state in [:exited, :failed], do: :released
  defp resource_state(:cleanup_failed), do: :unconfirmed
end
