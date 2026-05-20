defmodule PiCoding.Tools.BashTest do
  use ExUnit.Case, async: true
  alias PiCoding.Tools.Bash

  @cwd File.cwd!()

  test "executes a simple command" do
    params = %{"command" => "echo 'hello world'"}
    opts = [cwd: @cwd]

    assert {:ok, result} = Bash.execute("1", params, opts)
    assert [%{text: text}] = result.content
    assert String.trim(text) == "hello world"
    assert result.details.exit_code == 0
    assert result.details.command == "echo 'hello world'"
  end

  test "returns non-zero exit code" do
    params = %{"command" => "exit 42"}
    opts = [cwd: @cwd]

    assert {:ok, result} = Bash.execute("1", params, opts)
    assert result.details.exit_code == 42
  end

  test "captures stderr" do
    params = %{"command" => "echo 'error message' >&2"}
    opts = [cwd: @cwd]

    assert {:ok, result} = Bash.execute("1", params, opts)
    assert [%{text: text}] = result.content
    assert String.trim(text) == "error message"
  end

  test "streams output via on_update" do
    parent = self()
    on_update = fn result -> send(parent, {:update, result}) end

    # We use a command that definitely produces output in stages
    params = %{"command" => "echo 'part1'; sleep 0.2; echo 'part2'"}
    opts = [cwd: @cwd, on_update: on_update]

    assert {:ok, _result} = Bash.execute("1", params, opts)

    # We should receive at least two updates (one for part1, one for part2)
    # Actually, we might receive more depending on how Port handles it.
    assert_receive {:update, %{content: [%{text: text1}]}}, 500
    assert text1 =~ "part1"

    assert_receive {:update, %{content: [%{text: text2}]}}, 500
    assert text2 =~ "part1"
    assert text2 =~ "part2"
  end

  test "handles timeout" do
    # Command that takes 2 seconds, with a 1 second timeout
    params = %{"command" => "sleep 2", "timeout" => 1}
    opts = [cwd: @cwd]

    assert {:error, reason} = Bash.execute("1", params, opts)
    assert reason =~ "timed out"
  end

  test "handles cancellation signal" do
    signal = make_ref()
    parent = self()

    # Run execute in a separate process
    test_pid =
      spawn_link(fn ->
        res = Bash.execute("1", %{"command" => "sleep 2"}, cwd: @cwd, signal: signal)
        send(parent, {:result, res})
      end)

    # Give it a moment to start and enter wait_for_task
    Process.sleep(100)

    # Send abort signal to the process running Bash.execute
    send(test_pid, {:abort, signal})

    assert_receive {:result, {:error, "Command aborted"}}, 500
  end

  test "fails if cwd does not exist" do
    params = %{"command" => "ls"}
    opts = [cwd: "/non/existent/path/at/all/costs"]

    assert {:error, reason} = Bash.execute("1", params, opts)
    assert reason =~ "Working directory does not exist"
  end
end
