defmodule Sigma.Agent.Terminals.NativeStreamIntegrationTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.Terminals.{Identity, Limits, Manager, ResourceLedger, Worker}
  alias Sigma.Coding.Terminal.Native

  @helper Path.expand("../../../priv/native/sigma-terminal-helper", __DIR__)

  test "native output watermark and vt100 checkpoint restore alternate-screen state" do
    run = native_run("checkpoint")

    {:ok, worker} =
      start_supervised(
        {Worker,
         run: run,
         backend: Native,
         backend_opts: [helper_path: @helper],
         attrs: %{
           cwd: System.tmp_dir!(),
           command: ["/bin/cat"]
         },
         limits: Limits.new()}
      )

    assert {:pending, 1} = Worker.start(worker)
    assert_receive {:terminal_worker_started, ^worker, ^run, _resource}, 3_000

    backend = :sys.get_state(worker).backend_state.value
    assert :ok = Native.input(backend, <<27, "[?1049hfull screen">>)

    eventually(fn -> :sys.get_state(worker).stream.native_sequence > 0 end)
    native_sequence = :sys.get_state(worker).stream.native_sequence
    assert :ok = Worker.request_checkpoint(worker, "checkpoint-1")

    eventually(fn ->
      case :sys.get_state(worker).stream.checkpoint do
        %{source_sequence: ^native_sequence, dimensions: {120, 24}, bytes: bytes} ->
          :binary.match(bytes, "full screen") != :nomatch

        _other ->
          false
      end
    end)

    assert {:ok, %{attachment_id: attachment, delivery: %{mode: :snapshot_then_replay}}} =
             Worker.attach(worker, self(), "native-view", 1, 999)

    assert_receive {:terminal_stream, ^attachment,
                    {:snapshot,
                     %{source_sequence: ^native_sequence, dimensions: {120, 24}, bytes: bytes}}}

    assert :binary.match(bytes, "full screen") != :nomatch

    send(worker, {:terminal_backend, backend, {:output, native_sequence + 2, "gap"}})
    assert_receive {:terminal_stream, ^attachment, {:resync_required, :sequence_gap}}

    assert_receive {:terminal_stream, ^attachment,
                    {:snapshot, %{source_sequence: ^native_sequence}}},
                   1_000

    refute_receive {:terminal_stream, ^attachment, {:event, %{bytes: "gap"}}}

    send(
      worker,
      {:terminal_backend, backend,
       {:checkpoint_failed, "too-large", :snapshot_too_large, %{maximum_bytes: 2_097_152}}}
    )

    assert_receive {:terminal_stream, ^attachment,
                    {:resync_required,
                     %Sigma.Agent.Terminals.Error{
                       code: :snapshot_unavailable,
                       details: %{reason: :snapshot_too_large, maximum_bytes: 2_097_152}
                     }}}

    assert :sys.get_state(worker).stream.checkpoint == nil
    assert {:ok, :confirmed} = Native.close(backend)
    eventually(fn -> not Process.alive?(backend) end)
  end

  test "native high-volume ingress bypasses manager and isolates a slow observer" do
    limits =
      Limits.new(
        max_pending_output_bytes_per_attachment: 5,
        max_raw_replay_bytes: 128
      )

    runtime =
      start_runtime(
        limits,
        command: ["/bin/sh", "-c", "stty raw -echo; printf READY; exec /bin/cat"]
      )

    terminal = create(runtime)
    terminal_id = terminal.identity.terminal_id
    eventually(fn -> running?(runtime.manager, terminal_id) end)

    {:ok, %{attachment_id: slow}} = Manager.attach(runtime.manager, terminal_id, 1, self())
    {:ok, %{attachment_id: healthy}} = Manager.attach(runtime.manager, terminal_id, 1, self())
    worker = Manager.worker_pid(runtime.manager, terminal_id)
    backend = :sys.get_state(worker).backend_state.value

    assert_receive {:terminal_stream, ^slow, {:event, %{sequence: ready, bytes: "READY"}}}, 1_000
    assert_receive {:terminal_stream, ^healthy, {:event, %{sequence: ^ready, bytes: "READY"}}}
    assert :ok = Manager.acknowledge(runtime.manager, terminal_id, 1, slow, ready)
    assert :ok = Manager.acknowledge(runtime.manager, terminal_id, 1, healthy, ready)

    assert :ok = Native.input(backend, "1234")

    assert_receive {:terminal_stream, ^slow, {:event, %{sequence: first, bytes: "1234"}}}, 1_000
    assert_receive {:terminal_stream, ^healthy, {:event, %{sequence: ^first, bytes: "1234"}}}
    assert :ok = Manager.acknowledge(runtime.manager, terminal_id, 1, healthy, first)

    assert :ok = Native.input(backend, "abcd")

    assert_receive {:terminal_stream, ^slow, {:resync_required, :slow_observer}}, 1_000
    assert_receive {:terminal_stream, ^healthy, {:event, %{sequence: second, bytes: "abcd"}}}
    assert second > first
    assert :ok = Manager.acknowledge(runtime.manager, terminal_id, 1, healthy, second)

    started_at = System.monotonic_time(:millisecond)
    assert {:ok, _snapshot} = Manager.list(runtime.manager)
    assert System.monotonic_time(:millisecond) - started_at < 100
    assert {:message_queue_len, count} = Process.info(runtime.manager, :message_queue_len)
    assert count < 10

    assert {:ok, %{paused?: true, pending_bytes: 0}} =
             Manager.attachment_status(runtime.manager, terminal_id, 1, slow)

    assert {:ok, %{paused?: false}} =
             Manager.attachment_status(runtime.manager, terminal_id, 1, healthy)

    assert {:ok, :confirmed} = Native.close(backend)
    eventually(fn -> not Process.alive?(backend) end)
  end

  defp start_runtime(limits, attrs) do
    key = {__MODULE__, make_ref()}
    on_exit(fn -> :persistent_term.erase(key) end)
    {:ok, ledger} = start_supervised({ResourceLedger, name: nil, persistence_key: key})
    {:ok, workers} = start_supervised({DynamicSupervisor, strategy: :one_for_one})
    session = Identity.session("repo", "session", unique_id())

    {:ok, manager} =
      start_supervised(
        {Manager,
         session: session,
         ledger: ledger,
         worker_supervisor: workers,
         backend: Native,
         backend_opts: [helper_path: @helper],
         limits: limits}
      )

    %{manager: manager, attrs: Map.new(attrs)}
  end

  defp create(runtime) do
    operation = Manager.issue_operation(runtime.manager, unique_id(), :create)
    assert {:ok, terminal} = Manager.create(runtime.manager, operation, runtime.attrs)
    terminal
  end

  defp running?(manager, terminal_id) do
    case Manager.list(manager) do
      {:ok, %{entries: entries}} ->
        Enum.any?(entries, &(&1.identity.terminal_id == terminal_id and &1.state == :running))

      _other ->
        false
    end
  end

  defp native_run(id) do
    "repo"
    |> Identity.session("session", unique_id())
    |> Identity.terminal(id)
    |> Identity.run(1)
  end

  defp eventually(function, attempts \\ 100)

  defp eventually(function, attempts) when attempts > 0 do
    if function.() do
      :ok
    else
      Process.sleep(10)
      eventually(function, attempts - 1)
    end
  end

  defp eventually(_function, 0), do: flunk("condition did not become true")
  defp unique_id, do: Integer.to_string(System.unique_integer([:positive, :monotonic]))
end
