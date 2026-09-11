defmodule Sigma.Agent.Terminals.ControllerLeaseTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.Terminals.{ControllerLease, Error, Identity, Limits}

  @session Identity.session("repo-1", "session-1", "incarnation-1")
  @terminal Identity.terminal(@session, "terminal-1")
  @run Identity.run(@terminal, 3)

  test "vacant acquisition, atomic takeover, expiry, and release increment epochs" do
    limits = Limits.new(controller_lease_ms: 100)
    lease = ControllerLease.new()

    assert {:ok, lease} = ControllerLease.acquire(lease, "attachment-a", 0, limits)
    assert lease.epoch == 1

    assert {:error, %Error{code: :control_occupied}} =
             ControllerLease.acquire(lease, "attachment-b", 10, limits)

    assert {:error, %Error{code: :control_conflict}} =
             ControllerLease.takeover(lease, "attachment-b", 0, 10, limits)

    assert {:ok, lease} = ControllerLease.takeover(lease, "attachment-b", 1, 10, limits)
    assert lease.controller_id == "attachment-b"
    assert lease.epoch == 2

    assert {:ok, expired} = ControllerLease.acquire(lease, "attachment-c", 110, limits)
    assert expired.epoch == 3

    assert {:ok, released} = ControllerLease.release(expired, "attachment-c", 3)
    assert released.controller_id == nil
    assert released.epoch == 4
  end

  test "final dispatch rejects stale session, terminal, run, revision, attachment, and epoch" do
    lease = %ControllerLease{controller_id: "attachment-a", epoch: 7, expires_at_ms: 1_000}
    current = %{run: @run, catalog_revision: 9, lease: lease}
    valid = fence(@run, 9, "attachment-a", 7)

    assert :ok = ControllerLease.authorize(current, valid, 999)

    stale_session = put_in(valid.run.terminal.session.incarnation_id, "old")

    assert {:error, %Error{code: :stale_session_incarnation}} =
             ControllerLease.authorize(current, stale_session, 999)

    wrong_scope = put_in(valid.run.terminal.session.session_id, "other-session")

    assert {:error, %Error{code: :session_scope_mismatch}} =
             ControllerLease.authorize(current, wrong_scope, 999)

    stale_terminal = put_in(valid.run.terminal.terminal_id, "other")

    assert {:error, %Error{code: :stale_terminal}} =
             ControllerLease.authorize(current, stale_terminal, 999)

    assert {:error, %Error{code: :stale_run_generation}} =
             ControllerLease.authorize(
               current,
               fence(%{@run | generation: 2}, 9, "attachment-a", 7),
               999
             )

    assert {:error, %Error{code: :stale_catalog_revision}} =
             ControllerLease.authorize(current, fence(@run, 8, "attachment-a", 7), 999)

    assert {:error, %Error{code: :not_controller}} =
             ControllerLease.authorize(current, fence(@run, 9, "attachment-b", 7), 999)

    assert {:error, %Error{code: :stale_control_epoch}} =
             ControllerLease.authorize(current, fence(@run, 9, "attachment-a", 6), 999)

    assert {:error, %Error{code: :controller_lease_expired}} =
             ControllerLease.authorize(current, valid, 1_000)
  end

  defp fence(run, revision, attachment_id, epoch) do
    %{
      run: run,
      catalog_revision: revision,
      attachment_id: attachment_id,
      control_epoch: epoch
    }
  end
end
