defmodule Sigma.Coding.Terminal.NativeTest do
  use ExUnit.Case, async: false

  alias Sigma.Coding.Terminal.Native

  @helper Path.expand(
            "../../../../../native/sigma_terminal_helper/target/debug/sigma-terminal-helper",
            __DIR__
          )

  test "reports a missing packaged helper explicitly" do
    assert {:error, :backend_unavailable} =
             Native.capabilities(helper_path: Path.join(__DIR__, "missing-helper"))
  end

  test "preserves bytes, applies a real resize, and returns a coherent checkpoint" do
    {:ok, backend} =
      start_backend(
        command: [
          "/bin/sh",
          "-c",
          "stty raw -echo; trap 'stty size' WINCH; printf '\\377\\000READY'; while :; do sleep 1; done"
        ]
      )

    assert {:started, %{pid: pid, sid: pid, started_at: started_at}} = event(backend, :started)
    assert is_integer(started_at)
    assert {:output, _seq, bytes} = event(backend, :output)
    assert bytes =~ <<255, 0, "READY">>

    assert :ok = Native.resize(backend, 132, 41)
    assert {:resized, 132, 41} = event(backend, :resized)
    assert {:output, seq, resize_output} = event(backend, :output)
    assert resize_output =~ "41 132"

    assert :ok = Native.checkpoint(backend, "resize-checkpoint")

    assert {:checkpoint, "resize-checkpoint", checkpoint_seq, 132, 41, checkpoint} =
             event(backend, :checkpoint)

    assert checkpoint_seq >= seq
    assert is_binary(checkpoint)
    assert {:ok, :confirmed} = Native.close(backend)
  end

  test "rejects oversized input and invalid dimensions before native dispatch" do
    {:ok, backend} = start_backend(command: ["/bin/sh", "-c", "sleep 30"])
    assert {:started, _resource} = event(backend, :started)

    assert {:error, :input_too_large} = Native.input(backend, :binary.copy(<<0>>, 16 * 1024 + 1))
    assert {:error, :invalid_dimensions} = Native.resize(backend, 1, 24)
    assert {:error, :invalid_dimensions} = Native.resize(backend, 501, 24)
    assert {:error, :invalid_dimensions} = Native.resize(backend, 80, 0)
    assert {:error, :invalid_dimensions} = Native.resize(backend, 80, 301)
    assert {:ok, :confirmed} = Native.close(backend)
  end

  test "reports an oversized checkpoint without forwarding its payload" do
    {:ok, backend} =
      start_backend(
        rows: 300,
        columns: 500,
        command: [
          "/bin/sh",
          "-c",
          ~S[awk 'BEGIN { for (i=0; i<75000; i++) printf "\033[38;2;255;0;0mX\033[38;2;0;255;0mY"; printf "DONE" }'; sleep 30]
        ]
      )

    assert {:started, _resource} = event(backend, :started)
    consume_output_until(backend, "DONE")
    assert :ok = Native.checkpoint(backend, "too-large")

    assert {:checkpoint_failed, "too-large", :snapshot_too_large, %{maximum_bytes: 2_097_152}} =
             event(backend, :checkpoint_failed)

    assert {:ok, :confirmed} = Native.close(backend)
  end

  test "natural shell exit is reported before confirmed descendant cleanup" do
    {:ok, backend} =
      start_backend(
        command: [
          "/bin/sh",
          "-c",
          "(trap '' HUP TERM; while :; do sleep 1; done) & exit 7"
        ]
      )

    assert {:started, _resource} = event(backend, :started)
    assert {:shell_exit, 7, nil} = event(backend, :shell_exit)

    assert {:cleanup, {:ok, :confirmed}, %{complete: true, remaining: []}} =
             event(backend, :cleanup)
  end

  test "close revokes input and concurrent retries share one cleanup result" do
    {:ok, backend} =
      start_backend(command: ["/bin/sh", "-c", "trap '' HUP TERM; while :; do sleep 1; done"])

    assert {:started, _resource} = event(backend, :started)
    first = Task.async(fn -> Native.close(backend) end)
    assert_eventually(fn -> Native.input(backend, "no") == {:error, :input_revoked} end)
    second = Task.async(fn -> Native.close(backend) end)

    assert {:ok, :confirmed} = Task.await(first, 7_000)
    assert {:ok, :confirmed} = Task.await(second, 7_000)
    assert {:ok, :confirmed} = Native.close(backend)
  end

  test "helper crash is an explicit unconfirmed backend failure" do
    Process.flag(:trap_exit, true)
    {:ok, backend} = start_backend(command: ["/bin/sh", "-c", "sleep 30"])
    assert {:started, %{pid: shell_pid}} = event(backend, :started)
    assert {:ok, %{helper_pid: helper_pid}} = Native.resource(backend)

    on_exit(fn -> System.cmd("kill", ["-KILL", to_string(shell_pid)], stderr_to_stdout: true) end)
    System.cmd("kill", ["-KILL", to_string(helper_pid)], stderr_to_stdout: true)

    assert {:backend_failed, {:helper_exit, _status}} = event(backend, :backend_failed)
    assert_receive {:EXIT, ^backend, :normal}, 2_000
  end

  test "adapter owner death closes the helper control channel and reaps the run" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, backend} =
          start_backend(
            owner: self(),
            command: ["/bin/sh", "-c", "trap '' HUP TERM; while :; do sleep 1; done"]
          )

        send(parent, {:owner_backend, self(), backend})
        forward_backend_events(parent)
      end)

    assert_receive {:owner_backend, ^owner, backend}, 2_000
    assert_receive {:forwarded, ^backend, {:started, resource}}, 2_000
    backend_ref = Process.monitor(backend)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^backend_ref, :process, ^backend, _reason}, 2_000

    assert_eventually(fn -> not os_process_alive?(resource.helper_pid) end, 7_000)
    assert_eventually(fn -> not os_process_alive?(resource.pid) end, 7_000)
  end

  defp start_backend(opts) do
    Native.start_link(Keyword.merge([helper_path: @helper, owner: self()], opts))
  end

  defp event(backend, kind) do
    receive do
      {:terminal_backend, ^backend, event} when elem(event, 0) == kind -> event
      {:terminal_backend, ^backend, _other} -> event(backend, kind)
    after
      7_000 -> flunk("timed out waiting for backend event #{inspect(kind)}")
    end
  end

  defp consume_output_until(backend, expected, received \\ "") do
    {:output, _sequence, bytes} = event(backend, :output)
    received = received <> bytes
    if received =~ expected, do: :ok, else: consume_output_until(backend, expected, received)
  end

  defp forward_backend_events(parent) do
    receive do
      {:terminal_backend, backend, event} ->
        send(parent, {:forwarded, backend, event})
        forward_backend_events(parent)
    end
  end

  defp assert_eventually(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_assert_eventually(fun, deadline)
  end

  defp do_assert_eventually(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) >= deadline -> flunk("condition did not become true")
      true -> Process.sleep(20) && do_assert_eventually(fun, deadline)
    end
  end

  defp os_process_alive?(pid) do
    {_output, status} = System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true)
    status == 0
  end
end
