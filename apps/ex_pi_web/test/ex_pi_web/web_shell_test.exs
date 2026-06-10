defmodule PiWeb.WebShellTest do
  use ExUnit.Case, async: false

  @tag :tmp_dir
  test "starts the shell in the requested working directory and forwards output", %{
    tmp_dir: tmp_dir
  } do
    shell = System.find_executable("sh")

    assert {:ok, pid} =
             PiWeb.WebShell.start_link(
               owner: self(),
               cwd: tmp_dir,
               shell: shell,
               shell_args: ["-c", "pwd"]
             )

    assert_receive {:web_shell_output, ^pid, output}, 1_000
    assert output =~ tmp_dir
    assert_receive {:web_shell_exit, ^pid, 0}, 1_000
  end

  @tag :tmp_dir
  test "forwards terminal input to shell stdin", %{tmp_dir: tmp_dir} do
    shell = System.find_executable("sh")

    assert {:ok, pid} =
             PiWeb.WebShell.start_link(
               owner: self(),
               cwd: tmp_dir,
               shell: shell,
               shell_args: ["-s"]
             )

    PiWeb.WebShell.input(pid, "printf 'cwd:%s\\n' \"$PWD\"\r")
    PiWeb.WebShell.input(pid, "exit\n")

    assert wait_for_output(pid, "cwd:#{tmp_dir}") =~ tmp_dir
    assert_receive {:web_shell_exit, ^pid, 0}, 1_000
  end

  defp wait_for_output(pid, expected, acc \\ "") do
    receive do
      {:web_shell_output, ^pid, data} ->
        acc = acc <> data

        if String.contains?(acc, expected) do
          acc
        else
          wait_for_output(pid, expected, acc)
        end
    after
      1_000 -> flunk("expected shell output to include #{inspect(expected)}, got #{inspect(acc)}")
    end
  end
end
