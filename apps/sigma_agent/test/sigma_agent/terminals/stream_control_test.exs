Code.require_file(Path.expand("../../support/terminal_headless_fixture.ex", __DIR__))

defmodule Sigma.Agent.Terminals.StreamControlTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.Terminals.{
    Error,
    FakeBackend,
    HeadlessFixture,
    Identity,
    Limits,
    Manager,
    ResourceLedger,
    Worker
  }

  test "creator receives initial control and observer capacity is enforced" do
    runtime = start_runtime(limits: Limits.new(max_observers_per_terminal: 2))
    terminal = create(runtime, %{creator: %{observer: self()}})
    run = run(terminal)

    assert_receive {:terminal_creator_attachment, ^run,
                    {:ok, %{controller: true, control_epoch: 1, attachment_id: first}}}

    assert {:ok, %{controller: false, attachment_id: second}} =
             Manager.attach(runtime.manager, terminal.identity.terminal_id, 1, self())

    assert first != second

    assert {:error, %Error{code: :capacity_exhausted}} =
             Manager.attach(runtime.manager, terminal.identity.terminal_id, 1, self())
  end

  test "delayed startup retains creator attachment intent and notifies exactly once" do
    runtime = start_runtime(backend_opts: [start: :delayed])
    terminal = create(runtime, %{creator: %{observer: self()}})
    run = run(terminal)

    refute_receive {:terminal_creator_attachment, ^run, _result}

    assert {:ok, %{state: :running}} =
             Manager.complete_start(runtime.manager, terminal.identity.terminal_id)

    assert_receive {:terminal_creator_attachment, ^run,
                    {:ok, %{controller: true, control_epoch: 1}}}

    refute_receive {:terminal_creator_attachment, ^run, _result}, 20
  end

  test "dead delayed-start creator is rejected without leaving an attachment" do
    runtime = start_runtime(backend_opts: [start: :delayed])
    observer = spawn(fn -> Process.sleep(:infinity) end)
    terminal = create(runtime, %{creator: %{observer: observer}})
    Process.exit(observer, :kill)
    eventually(fn -> not Process.alive?(observer) end)

    assert {:ok, %{state: :running}} =
             Manager.complete_start(runtime.manager, terminal.identity.terminal_id)

    assert {:ok, %{controller: false}} =
             Manager.attach(runtime.manager, terminal.identity.terminal_id, 1, self())
  end

  test "concurrent takeover has one winner and delayed old-controller frames are fenced" do
    runtime = start_runtime(limits: Limits.new(max_observers_per_terminal: 3))
    terminal = create(runtime)
    terminal_id = terminal.identity.terminal_id
    {:ok, %{attachment_id: first}} = Manager.attach(runtime.manager, terminal_id, 1, self())
    {:ok, %{control_epoch: 1}} = Manager.acquire_control(runtime.manager, terminal_id, 1, first)
    {:ok, %{attachment_id: second}} = Manager.attach(runtime.manager, terminal_id, 1, self())
    {:ok, %{attachment_id: third}} = Manager.attach(runtime.manager, terminal_id, 1, self())
    parent = self()

    tasks =
      for attachment <- [second, third] do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> Manager.takeover_control(runtime.manager, terminal_id, 1, attachment, 1)
          end
        end)
      end

    submitters =
      for _ <- tasks do
        assert_receive {:ready, pid}
        pid
      end

    Enum.each(submitters, &send(&1, :go))
    results = Enum.map(tasks, &Task.await/1)

    assert 1 == Enum.count(results, &match?({:ok, %{controller: true}}, &1))
    assert 1 == Enum.count(results, &match?({:error, %Error{code: :control_conflict}}, &1))

    request = fence(run(terminal), snapshot(runtime.manager).revision, first, 1)

    assert {:error, %Error{code: :not_controller}} =
             Manager.input(runtime.manager, terminal_id, 1, request, "stale")

    refute Enum.any?(backend_events(runtime, terminal), &match?({:input, _, "stale"}, &1))
  end

  test "observer down and lease expiry vacate control" do
    runtime = start_runtime(limits: Limits.new(controller_lease_ms: 30))
    terminal = create(runtime)
    terminal_id = terminal.identity.terminal_id

    observer =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, %{attachment_id: first}} = Manager.attach(runtime.manager, terminal_id, 1, observer)
    {:ok, %{control_epoch: 1}} = Manager.acquire_control(runtime.manager, terminal_id, 1, first)
    Process.exit(observer, :kill)

    {:ok, %{attachment_id: second}} = Manager.attach(runtime.manager, terminal_id, 1, self())

    eventually(fn ->
      match?(
        {:ok, %{controller: true}},
        Manager.acquire_control(runtime.manager, terminal_id, 1, second)
      )
    end)

    Process.sleep(35)
    {:ok, %{attachment_id: third}} = Manager.attach(runtime.manager, terminal_id, 1, self())

    assert {:ok, %{controller: true}} =
             Manager.acquire_control(runtime.manager, terminal_id, 1, third)
  end

  test "inactive read-only attachments expire and heartbeat extends their lifetime" do
    runtime = start_runtime(limits: Limits.new(attachment_inactivity_ms: 200))
    terminal = create(runtime)
    terminal_id = terminal.identity.terminal_id
    {:ok, %{attachment_id: attachment}} = Manager.attach(runtime.manager, terminal_id, 1, self())

    Process.sleep(20)
    assert :ok = Manager.touch_attachment(runtime.manager, terminal_id, 1, attachment)
    Process.sleep(20)
    assert {:ok, _status} = Manager.attachment_status(runtime.manager, terminal_id, 1, attachment)

    eventually(
      fn ->
        match?(
          {:error, %Error{details: %{reason: :attachment_not_found}}},
          Manager.attachment_status(runtime.manager, terminal_id, 1, attachment)
        )
      end,
      200
    )
  end

  test "final input and resize fence checks every identity and confirms canonical dimensions" do
    runtime = start_runtime()
    terminal = create(runtime)
    terminal_id = terminal.identity.terminal_id
    run = run(terminal)
    {:ok, %{attachment_id: controller}} = Manager.attach(runtime.manager, terminal_id, 1, self())

    {:ok, %{control_epoch: epoch}} =
      Manager.acquire_control(runtime.manager, terminal_id, 1, controller)

    revision = snapshot(runtime.manager).revision
    valid = fence(run, revision, controller, epoch)

    assert :ok = Manager.input(runtime.manager, terminal_id, 1, valid, "echo ok\n")

    assert {:ok, %{sequence: 1, resize: {90, 31}}} =
             Manager.resize(runtime.manager, terminal_id, 1, valid, 90, 31)

    assert {:error, %Error{code: :invalid_dimensions}} =
             Manager.resize(runtime.manager, terminal_id, 1, valid, 0, 0)

    stale_cases = [
      {put_in(valid.run.terminal.session.incarnation_id, "old"), :stale_session_incarnation},
      {put_in(valid.run.terminal.session.session_id, "other"), :session_scope_mismatch},
      {put_in(valid.run.terminal.terminal_id, "other"), :stale_terminal},
      {%{valid | run: %{run | generation: 2}}, :stale_run_generation},
      {%{valid | catalog_revision: revision - 1}, :stale_catalog_revision},
      {%{valid | control_epoch: epoch + 1}, :stale_control_epoch}
    ]

    for {request, code} <- stale_cases do
      assert {:error, %Error{code: ^code}} =
               Manager.input(runtime.manager, terminal_id, 1, request, "rejected")
    end

    events = backend_events(runtime, terminal)
    assert Enum.any?(events, &match?({:input, ^run, "echo ok\n"}, &1))
    assert Enum.any?(events, &match?({:resize_ack, ^run, 90, 31}, &1))
    refute Enum.any?(events, &match?({:input, _, "rejected"}, &1))
  end

  test "output continues detached and reconnect replays ordered output and resize" do
    runtime = start_runtime()
    terminal = create(runtime)
    run = run(terminal)
    terminal_id = terminal.identity.terminal_id

    assert {:ok, %{sequence: 1}} = Manager.output(runtime.manager, run, "one")
    {:ok, %{attachment_id: attachment}} = Manager.attach(runtime.manager, terminal_id, 1, self())
    assert_receive {:terminal_stream, ^attachment, {:event, %{sequence: 1, bytes: "one"}}}

    {:ok, %{control_epoch: epoch}} =
      Manager.acquire_control(runtime.manager, terminal_id, 1, attachment)

    request = fence(run, snapshot(runtime.manager).revision, attachment, epoch)

    assert {:ok, %{sequence: 2, resize: {100, 40}}} =
             Manager.resize(runtime.manager, terminal_id, 1, request, 100, 40)

    assert {:ok, %{sequence: 3}} = Manager.output(runtime.manager, run, "two")
    assert :ok = Manager.detach(runtime.manager, terminal_id, 1, attachment)
    assert {:ok, %{sequence: 4}} = Manager.output(runtime.manager, run, "detached")

    assert {:ok, %{dimensions: {100, 40}, delivery: %{mode: :replay}, attachment_id: next}} =
             Manager.attach(runtime.manager, terminal_id, 1, self(), 1)

    assert_receive {:terminal_stream, ^next, {:event, %{sequence: 2, resize: {100, 40}}}}
    assert_receive {:terminal_stream, ^next, {:event, %{sequence: 3, bytes: "two"}}}
    assert_receive {:terminal_stream, ^next, {:event, %{sequence: 4, bytes: "detached"}}}
  end

  test "slow attachment pauses for resync without blocking an acknowledging viewer" do
    limits = Limits.new(max_pending_output_bytes_per_attachment: 5, max_raw_replay_bytes: 64)
    runtime = start_runtime(limits: limits)
    terminal = create(runtime)
    run = run(terminal)
    terminal_id = terminal.identity.terminal_id
    {:ok, %{attachment_id: slow}} = Manager.attach(runtime.manager, terminal_id, 1, self())
    {:ok, %{attachment_id: healthy}} = Manager.attach(runtime.manager, terminal_id, 1, self())

    assert {:ok, %{sequence: 1}} = Manager.output(runtime.manager, run, "1234")
    assert_receive {:terminal_stream, ^slow, {:event, %{sequence: 1}}}
    assert_receive {:terminal_stream, ^healthy, {:event, %{sequence: 1}}}
    assert :ok = Manager.acknowledge(runtime.manager, terminal_id, 1, healthy, 1)

    assert {:ok, %{sequence: 2}} = Manager.output(runtime.manager, run, "abcd")
    assert_receive {:terminal_stream, ^slow, {:resync_required, :slow_observer}}
    assert_receive {:terminal_stream, ^healthy, {:event, %{sequence: 2, bytes: "abcd"}}}

    assert {:ok, %{paused?: true, pending_bytes: 0}} =
             Manager.attachment_status(runtime.manager, terminal_id, 1, slow)

    assert :ok = Manager.acknowledge(runtime.manager, terminal_id, 1, healthy, 2)

    assert {:ok, %{paused?: false}} =
             Manager.attachment_status(runtime.manager, terminal_id, 1, healthy)
  end

  test "replay gaps require a coherent snapshot and unavailable checkpoints are typed" do
    limits = Limits.new(max_raw_replay_bytes: 4, max_pending_output_bytes_per_attachment: 64)
    runtime = start_runtime(limits: limits)
    terminal = create(runtime)
    run = run(terminal)
    terminal_id = terminal.identity.terminal_id

    {:ok, _} = Manager.output(runtime.manager, run, "aaaa")
    assert {:ok, %{sequence: 1}} = Manager.checkpoint(runtime.manager, run, "screen-one")
    {:ok, _} = Manager.output(runtime.manager, run, "bbbb")

    assert {:ok,
            %{
              delivery: %{mode: :snapshot_then_replay, snapshot: %{sequence: 1}},
              attachment_id: id
            }} =
             Manager.attach(runtime.manager, terminal_id, 1, self(), 0)

    assert_receive {:terminal_stream, ^id, {:snapshot, %{bytes: "screen-one", sequence: 1}}}
    assert_receive {:terminal_stream, ^id, {:event, %{bytes: "bbbb", sequence: 2}}}

    {:ok, _} = Manager.output(runtime.manager, run, "cccc")

    assert {:error, %Error{code: :snapshot_unavailable}} =
             Manager.attach(runtime.manager, terminal_id, 1, self(), 0)
  end

  test "fragmented UTF-8 and CSI survive checkpoint and device response is generated once" do
    limits = Limits.new(max_raw_replay_bytes: 128)
    runtime = start_runtime(limits: limits)
    terminal = create(runtime)
    run = run(terminal)

    fixture =
      %HeadlessFixture{}
      |> HeadlessFixture.write(<<0xE4, 0xBD>>)
      |> HeadlessFixture.write(<<0xA0, 27, "[?1049">>)
      |> HeadlessFixture.write("hfull screen")

    assert fixture.alternate_screen?
    restored = fixture |> HeadlessFixture.serialize() |> HeadlessFixture.restore()
    assert restored.bytes == <<0xE4, 0xBD, 0xA0, 27, "[?1049hfull screen">>
    assert restored.alternate_screen?

    {:ok, _} = Manager.output(runtime.manager, run, <<0xE4, 0xBD>>)
    {:ok, _} = Manager.output(runtime.manager, run, <<0xA0, 27, "[5">>)
    {:ok, _} = Manager.output(runtime.manager, run, "n")

    assert {:ok, %{sequence: 3}} =
             Manager.checkpoint(runtime.manager, run, HeadlessFixture.serialize(fixture))

    events = backend_events(runtime, terminal)
    assert 1 == Enum.count(events, &match?({:device_response, ^run, <<27, "[0n">>}, &1))
  end

  test "render watermark advances only after acknowledgement and old-run output is rejected" do
    runtime = start_runtime()
    terminal = create(runtime)
    run = run(terminal)
    terminal_id = terminal.identity.terminal_id
    {:ok, %{attachment_id: attachment}} = Manager.attach(runtime.manager, terminal_id, 1, self())
    {:ok, %{sequence: 1}} = Manager.output(runtime.manager, run, "frame")

    assert {:ok, %{rendered_sequence: 0, pending_bytes: 5}} =
             Manager.attachment_status(runtime.manager, terminal_id, 1, attachment)

    assert :ok = Manager.acknowledge(runtime.manager, terminal_id, 1, attachment, 1)

    assert {:ok, %{rendered_sequence: 1, pending_bytes: 0}} =
             Manager.attachment_status(runtime.manager, terminal_id, 1, attachment)

    assert {:error, %Error{code: :stale_run_generation}} =
             Worker.output(
               Manager.worker_pid(runtime.manager, terminal_id),
               %{run | generation: 2},
               "old"
             )
  end

  defp start_runtime(opts \\ []) do
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
         backend: FakeBackend,
         backend_opts: Keyword.get(opts, :backend_opts, []),
         limits: Keyword.get(opts, :limits, Limits.new())}
      )

    %{manager: manager, session: session}
  end

  defp create(runtime, attrs \\ %{}) do
    operation = Manager.issue_operation(runtime.manager, unique_id(), :create)
    assert {:ok, terminal} = Manager.create(runtime.manager, operation, attrs)
    terminal
  end

  defp run(terminal), do: Identity.run(terminal.identity, terminal.run_generation)

  defp fence(run, revision, attachment_id, epoch) do
    %{
      run: run,
      catalog_revision: revision,
      attachment_id: attachment_id,
      control_epoch: epoch
    }
  end

  defp snapshot(manager) do
    assert {:ok, snapshot} = Manager.list(manager)
    snapshot
  end

  defp backend_events(runtime, terminal) do
    runtime.manager
    |> Manager.worker_pid(terminal.identity.terminal_id)
    |> Worker.backend_events()
  end

  defp unique_id, do: Integer.to_string(System.unique_integer([:positive, :monotonic]))

  defp eventually(function, attempts \\ 30)

  defp eventually(function, attempts) when attempts > 0 do
    if function.(),
      do: :ok,
      else:
        (
          Process.sleep(5)
          eventually(function, attempts - 1)
        )
  end

  defp eventually(_function, 0), do: flunk("condition did not become true")
end
