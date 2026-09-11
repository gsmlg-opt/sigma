defmodule Sigma.Agent.Terminals.FakeBackendTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.Terminals.{FakeBackend, Identity, Limits}

  @session Identity.session("repo-1", "session-1", "incarnation-1")
  @run Identity.run(Identity.terminal(@session, "terminal-1"), 1)

  test "delays startup and deterministically emits raw bytes and resize acknowledgements" do
    backend = FakeBackend.new(start: :delayed)
    assert {:pending, start_ref, backend} = FakeBackend.start(backend, @run, %{cwd: "/tmp"})

    assert {:ok, backend} =
             FakeBackend.complete_start(backend, start_ref, %{resource_id: "fake-1"})

    assert {:ok, backend} = FakeBackend.emit(backend, @run, <<0, 255, 65>>)
    assert {:ok, backend} = FakeBackend.resize(backend, @run, 80, 25, Limits.new())

    assert [
             {:start_requested, ^start_ref, @run, %{cwd: "/tmp"}},
             {:started, ^start_ref, @run, %{resource_id: "fake-1"}},
             {:output, @run, <<0, 255, 65>>},
             {:resize_ack, @run, 80, 25}
           ] = FakeBackend.events(backend)
  end

  test "models failed and unconfirmed cleanup plus independent owner-death cleanup" do
    assert_cleanup(:failed, {:error, :cleanup_failed})
    assert_cleanup(:unconfirmed, {:error, :cleanup_unconfirmed})

    backend = FakeBackend.new(cleanup: :confirmed) |> running_backend()
    assert {:ok, backend} = FakeBackend.owner_down(backend, @run, :killed)

    assert Enum.take(FakeBackend.events(backend), -2) == [
             {:owner_down, @run, :killed},
             {:cleanup_confirmed, @run}
           ]
  end

  test "fails startup without manufacturing a running resource" do
    backend = FakeBackend.new(start: {:failed, :backend_unavailable})
    assert {:error, :backend_unavailable, backend} = FakeBackend.start(backend, @run, %{})
    assert backend.runs == %{}

    assert List.last(FakeBackend.events(backend)) ==
             {:start_failed, 1, @run, :backend_unavailable}
  end

  defp assert_cleanup(outcome, expected) do
    backend = FakeBackend.new(cleanup: outcome) |> running_backend()
    assert {status, backend} = FakeBackend.cleanup(backend, @run)
    assert status == expected
    assert List.last(FakeBackend.events(backend)) == {cleanup_event(outcome), @run}
  end

  defp running_backend(backend) do
    assert {:ok, backend} = FakeBackend.start(backend, @run, %{})
    backend
  end

  defp cleanup_event(:failed), do: :cleanup_failed
  defp cleanup_event(:unconfirmed), do: :cleanup_unconfirmed
end
