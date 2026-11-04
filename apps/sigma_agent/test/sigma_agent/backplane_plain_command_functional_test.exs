defmodule Sigma.Agent.Backplane.PlainCommandFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Command
  alias Sigma.Agent.Backplane.PlainCommand

  setup do
    {:ok, host} = start_supervised(PlainCommand)
    {:ok, command} = PlainCommand.command(host)

    %{command: command, host: host}
  end

  test "PTY launch acknowledges a real terminal with the declared dimensions", %{command: command} do
    assert {:ok, %{rows: 24, columns: 120}} = Command.terminal(command)
    {invocation, job} = launch(command, "test -t 0 && test -t 1 && stty size")
    assert %{terminal: %{pid: pid, sid: pid, rows: 24, columns: 120}} = job
    assert is_integer(pid)
    result = finished(command, invocation, job)
    assert text(result) == "24 120\r\n"
    assert result.exit_status == 0
    assert result.cleanup_status == :confirmed
    assert result.cleanup_evidence.complete
    release(command, invocation)
  end

  test "split UTF-8 frames and repeated cursor reads preserve exact output", %{command: command} do
    {invocation, job} =
      launch(
        command,
        ~S(printf '\344'; sleep 0.1; printf '\275\240'; sleep 0.1; printf '\345\245\275')
      )

    first = read_until(command, invocation, job, &(&1.output != []))
    assert String.valid?(text(first))
    final = finished(command, invocation, job, cursor: first.cursor)
    assert text(first) <> text(final) == "你好"

    assert {:ok, %{output: [], cursor: cursor}} =
             Command.read(command, invocation, job, cursor: final.cursor)

    assert cursor == final.cursor
    release(command, invocation)
  end

  test "stdin larger than the native frame limit is chunked without adding newlines", %{
    command: command
  } do
    # Raw mode disables the terminal line discipline's per-line input limit.
    payload = String.duplicate("界", 7_000)
    size = byte_size(payload)
    {invocation, job} = launch(command, "stty raw -echo; printf READY; head -c #{size}")
    ready = read_until(command, invocation, job, &(text(&1) == "READY"))
    later = Map.take(invocation, [:owner_run_id, :incarnation])
    assert :ok = Command.write(command, later, job, payload)
    result = finished(command, later, job, cursor: ready.cursor)
    assert text(result) == payload
    assert result.exit_status == 0
    release(command, invocation)
  end

  test "fast natural exit drains the complete output tail before releasing the handle", %{
    command: command
  } do
    {invocation, job} = launch(command, "head -c 262144 /dev/zero | tr '\\0' x; printf TAIL")
    result = finished(command, invocation, job)
    assert text(result) == String.duplicate("x", 262_144) <> "TAIL"
    assert result.exit_status == 0
    assert result.cleanup_status == :confirmed
    # A settled job remains readable until the public release acknowledgement.
    assert {:ok, again} = Command.read(command, invocation, job, cursor: 0)
    assert text(again) == text(result)
    release(command, invocation)

    assert {:error, %{class: :unknown_outcome}} =
             Command.read(command, invocation, job, cursor: 0)
  end

  test "nonzero exit is retained independently of confirmed cleanup", %{command: command} do
    {invocation, job} = launch(command, "printf failure; exit 7")
    result = finished(command, invocation, job)
    assert result.status == :completed
    assert result.exit_status == 7
    assert text(result) == "failure"
    assert result.cleanup_status == :confirmed
    release(command, invocation)
  end

  test "an incomplete final UTF-8 sequence is displayed instead of silently dropped", %{
    command: command
  } do
    {invocation, job} = launch(command, ~S(printf 'prefix\344'))
    result = finished(command, invocation, job)
    assert text(result) == "prefix�"
    assert result.exit_status == 0
    release(command, invocation)
  end

  test "stopping the command host reaps its job, helper and shell", %{
    command: command,
    host: host
  } do
    {_invocation, job} = launch(command, "printf READY; sleep 30")
    job_ref = Process.monitor(job.pty_job)
    assert :ok = PlainCommand.stop(host)
    assert_receive {:DOWN, ^job_ref, :process, _job, :normal}, 1_000
    refute Process.alive?(host)
    refute File.exists?("/proc/#{job.terminal.helper_pid}")
    refute File.exists?("/proc/#{job.terminal.pid}")
  end

  test "an abruptly stopped command host still retires its confirmed PTY job", %{
    command: command,
    host: host
  } do
    {_invocation, job} = launch(command, "printf READY; sleep 30")
    job_ref = Process.monitor(job.pty_job)
    Process.exit(host, :kill)
    assert_receive {:DOWN, ^job_ref, :process, _job, :normal}, 8_000
    refute File.exists?("/proc/#{job.terminal.helper_pid}")
    refute File.exists?("/proc/#{job.terminal.pid}")
  end

  test "deadline terminates the command and preserves the termination receipt", %{
    command: command
  } do
    {invocation, job} = launch(command, "printf READY; sleep 30", deadline_limit: 150)
    result = finished(command, invocation, job)
    assert result.status == :timeout
    assert result.termination_status == :requested
    assert result.cleanup_status == :confirmed
    assert text(result) == "READY"
    release(command, invocation)
  end

  test "output budget caps bytes and confirms command cleanup", %{command: command} do
    {invocation, job} = launch(command, "yes x", output_limit: 512)
    result = finished(command, invocation, job)
    assert result.status == :output_limit_exceeded
    assert result.output_limit_exceeded?
    assert byte_size(text(result)) == 512
    assert result.cleanup_status == :confirmed
    release(command, invocation)
  end

  test "session cancellation is confirmed using the original session identity", %{
    command: command
  } do
    {invocation, job} = launch(command, "printf READY; sleep 30")
    assert :ok = Command.cancel_confirmed(command, invocation, 7_000)
    result = finished(command, invocation, job)
    assert result.status == :cancelled
    assert result.cleanup_status == :confirmed
    assert result.termination_status == :requested
    assert :ok = Command.cancel_confirmed(command, invocation, 7_000)
    release(command, invocation)
  end

  test "two retained PTYs keep independent stdin and survive the other job closing", %{
    command: command
  } do
    {first, first_job} =
      launch(
        command,
        ~S(stty -echo; printf READY; while read line; do [ "$line" = exit ] && exit 0; printf 'one:%s' "$line"; done)
      )

    {second, second_job} =
      launch(
        command,
        ~S(stty -echo; printf READY; while read line; do [ "$line" = exit ] && exit 0; printf 'two:%s' "$line"; done)
      )

    first_ready = read_until(command, first, first_job, &(text(&1) == "READY"))
    second_ready = read_until(command, second, second_job, &(text(&1) == "READY"))

    assert :ok = Command.write(command, first, first_job, "alpha\n")

    first_reply =
      read_until(command, first, first_job, &(text(&1) == "one:alpha"),
        cursor: first_ready.cursor
      )

    assert first_reply.status == :running
    release(command, first)
    refute Process.alive?(first_job.pty_job)
    assert Process.alive?(second_job.pty_job)

    assert :ok = Command.write(command, second, second_job, "beta\n")

    second_reply =
      read_until(command, second, second_job, &(text(&1) == "two:beta"),
        cursor: second_ready.cursor
      )

    assert second_reply.status == :running
    assert :ok = Command.write(command, second, second_job, "exit\n")
    final = finished(command, second, second_job, cursor: second_reply.cursor)
    assert text(final) == ""
    assert final.exit_status == 0
    release(command, second)
  end

  test "owner shutdown cleans the PTY while retaining its results until acknowledgement", %{
    command: command
  } do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {invocation, job} = launch(command, "printf READY; sleep 30", [], %{owner_pid: owner})
    ready = read_until(command, invocation, job, &(text(&1) == "READY"))
    send(owner, :stop)
    result = finished(command, invocation, job)
    assert result.cleanup_status == :confirmed
    assert result.status == :cancelled
    assert text(result) == text(ready)
    release(command, invocation)
  end

  test "non-PTY jobs retain the ordinary LocalCommand behavior", %{command: command} do
    invocation = invocation("printf ordinary; exit 3") |> Map.put(:tty, false)
    assert :ok = Command.reserve(command, invocation)
    assert {:ok, job} = Command.start(command, invocation)
    refute Map.has_key?(job, :pty_job)
    result = finished(command, invocation, job)
    assert text(result) == "ordinary"
    assert result.exit_status == 3
    release(command, invocation)
  end

  defp launch(command, script, limits \\ [], extra \\ %{}) do
    invocation = Map.merge(invocation(script), extra)
    assert :ok = Command.reserve(command, invocation)
    assert {:ok, job} = Command.start(command, invocation, limits)
    {invocation, job}
  end

  defp invocation(script) do
    %{
      owner_run_id: "plain-pty-#{System.unique_integer([:positive, :monotonic])}",
      incarnation: 1,
      session_id: System.unique_integer([:positive, :monotonic]),
      workspace: File.cwd!(),
      executable: System.find_executable("sh"),
      arguments: ["-c", script],
      environment: %{},
      tty: true,
      terminal: %{rows: 24, columns: 120}
    }
  end

  defp release(command, invocation) do
    assert :ok = Command.cancel_confirmed(command, invocation, 7_000)
    assert :ok = Command.acknowledge_release(command, invocation)
  end

  defp finished(command, invocation, job, opts \\ []) do
    read_until(
      command,
      invocation,
      job,
      &(&1.status != :running and &1.cleanup_status not in [:pending, :not_started]),
      opts
    )
  end

  defp read_until(command, invocation, job, predicate, opts \\ []) do
    until = System.monotonic_time(:millisecond) + 10_000
    read_until(command, invocation, job, predicate, opts, until)
  end

  defp read_until(command, invocation, job, predicate, opts, until) do
    assert {:ok, result} =
             Command.read(command, invocation, job, cursor: Keyword.get(opts, :cursor, 0))

    if predicate.(result) do
      result
    else
      assert System.monotonic_time(:millisecond) < until,
             "PTY result did not settle: #{inspect(result)}"

      Process.sleep(10)
      read_until(command, invocation, job, predicate, opts, until)
    end
  end

  defp text(result), do: IO.iodata_to_binary(result.output)
end
