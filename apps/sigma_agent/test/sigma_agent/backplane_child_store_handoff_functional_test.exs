defmodule Sigma.Agent.BackplaneChildStoreHandoffFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Error
  alias Sigma.Agent.Backplane.{ChildIO, LifetimeRecovery, Store}

  @moduletag :tmp_dir
  @moduletag capture_log: true

  setup %{tmp_dir: directory} do
    transcript = Path.join(directory, "root.jsonl")
    store_path = Path.join([transcript <> ".subagents", "child", "runtime"])

    recovery =
      start_supervised!(
        Supervisor.child_spec(
          {LifetimeRecovery, transcript: transcript, root_header_id: "root-header"},
          restart: :temporary
        )
      )

    identity = %{
      agent_id: "child-agent",
      child_session_id: "child",
      run_id: "child-run",
      incarnation: 2,
      agent_path: "/root/child"
    }

    {:ok, _} =
      LifetimeRecovery.admit(
        recovery,
        %{attempt_id: "original-attempt", run_id: "original-run"},
        %{profile: :v2},
        [],
        %{backplane_store_path: store_path, host_retirement: %{host_lifetime: "original-host"}},
        %{}
      )

    {:ok, {Store, store}} = LifetimeRecovery.runtime_store(recovery, "child/runtime")

    options = [
      config: %{cwd: directory},
      identity: identity,
      transcript_path: Path.join(Path.dirname(store_path), "session.jsonl"),
      backplane_store_path: store_path,
      lifetime_recovery: recovery
    ]

    %{recovery: recovery, store: store, options: options}
  end

  test "recovery retirement leaves the handed-off Store alive until child retirement", context do
    io = start_child(context.options)
    assert {:ok, store} = ChildIO.store(io)
    assert store == context.store
    assert :ok = LifetimeRecovery.retire(context.recovery)
    assert Process.alive?(store)
    assert {:error, %Error{class: :not_found}} = Store.load(store, "missing")

    monitor = Process.monitor(store)
    assert {:ok, %{status: :confirmed}} = ChildIO.retire(io)
    GenServer.stop(io, :normal)
    assert_receive {:DOWN, ^monitor, :process, ^store, :normal}
  end

  test "recovery reopens and owns a fresh reader after the child retires its Store", context do
    io = start_child(context.options)
    store = context.store
    monitor = Process.monitor(store)
    assert {:ok, %{status: :confirmed}} = ChildIO.retire(io)
    GenServer.stop(io, :normal)
    assert_receive {:DOWN, ^monitor, :process, ^store, :normal}

    assert {:ok, {Store, reopened}} =
             LifetimeRecovery.runtime_store(context.recovery, "child/runtime")

    assert reopened != store
    monitor = Process.monitor(reopened)
    assert :ok = LifetimeRecovery.retire(context.recovery)
    assert_receive {:DOWN, ^monitor, :process, ^reopened, :normal}
  end

  test "normal Store loss remains a visible child failure after handoff", context do
    io = start_child(context.options)
    monitor = Process.monitor(io)
    GenServer.stop(context.store, :normal)

    assert_receive {:DOWN, ^monitor, :process, ^io,
                    %Error{
                      class: :execution_failure,
                      message: "child runtime Store exited",
                      cause: :normal
                    }}

    assert :ok = LifetimeRecovery.retire(context.recovery)
  end

  defp start_child(options) do
    start_supervised!(Supervisor.child_spec({ChildIO, options}, restart: :temporary))
  end
end
