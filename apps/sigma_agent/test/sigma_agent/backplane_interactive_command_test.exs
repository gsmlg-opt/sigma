defmodule Sigma.Agent.BackplaneInteractiveCommandTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Command
  alias Sigma.Agent.Backplane.PlainCommand

  @moduletag :tmp_dir

  test "PTY keeps running after its output buffer fills and polls only new bytes", %{
    tmp_dir: root
  } do
    server = start_supervised!({PlainCommand, []})

    {:ok, command} =
      PlainCommand.command(server,
        deadline_limit: :infinity,
        output_policy: :truncate,
        output_limit: 64
      )

    invocation = %{
      executable: System.find_executable("sh"),
      arguments: [
        "-c",
        "stty -echo; printf HEAD; i=0; while [ $i -lt 100 ]; do printf abcdefghij; i=$((i+1)); done; printf TAIL; read -r gate; printf DONE"
      ],
      owner_run_id: "interactive-pty",
      session_id: 321,
      incarnation: 1,
      owner_pid: self(),
      workspace: root,
      environment: %{},
      tty: true,
      terminal: %{rows: 24, columns: 120}
    }

    assert {:ok, job} = Command.start(command, invocation)
    assert :sys.get_state(job.pty_job).timer == nil

    on_exit(fn ->
      if Process.alive?(job.pty_job), do: Sigma.Agent.Backplane.PtyJob.cancel(job.pty_job)
    end)

    result = await_output(command, invocation, job, 0, 100)
    text = IO.iodata_to_binary(result.output)
    assert result.status == :running
    assert String.starts_with?(text, "HEAD")
    assert String.ends_with?(text, "TAIL")
    assert byte_size(text) <= 64
    assert result.omitted_output_bytes > 0
    assert {:ok, %{output: []}} = Command.read(command, invocation, job, cursor: result.cursor)
    assert :ok = Command.write(command, invocation, job, "continue\n")
    next = await_output(command, invocation, job, result.cursor, 100)
    assert IO.iodata_to_binary(next.output) == "DONE"
  end

  defp await_output(_command, _invocation, _job, _cursor, 0), do: flunk("missing PTY output")

  defp await_output(command, invocation, job, cursor, attempts) do
    assert {:ok, result} = Command.read(command, invocation, job, cursor: cursor)

    if result.output == [] do
      Process.sleep(10)
      await_output(command, invocation, job, cursor, attempts - 1)
    else
      Process.sleep(30)
      {:ok, result} = Command.read(command, invocation, job, cursor: cursor)
      result
    end
  end
end
