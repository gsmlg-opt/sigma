defmodule Sigma.Coding.Hooks.RunnerShutdownFunctionalTest do
  use ExUnit.Case, async: true

  alias Sigma.Coding.Hooks.{AsyncRuntime, Runner, Spec}
  alias Sigma.Coding.Hooks.Spec.Command

  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    task_supervisor = start_supervised!({Task.Supervisor, []})
    runtime_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    {:ok, runtime} =
      AsyncRuntime.start(self(),
        task_supervisor: task_supervisor,
        runtime_supervisor: runtime_supervisor
      )

    on_exit(fn -> AsyncRuntime.shutdown(runtime) end)

    %{
      runtime: runtime,
      ctx: %{
        cwd: directory,
        session_id: "s",
        turn_id: "t",
        model: "model",
        hook_shell: "/bin/sh",
        hook_task_supervisor: task_supervisor,
        hook_async_runtime: runtime
      }
    }
  end

  test "strict shutdown observes the actual shell and descendant closed before confirmation", %{
    runtime: runtime,
    ctx: ctx,
    tmp_dir: directory
  } do
    script =
      ~S(printf '%s' "$$" > shell-pid; sleep 30 & printf '%s' "$!" > child-pid; touch started; wait)

    assert {:proceed, []} = Runner.run(:stop, [command(script)], ctx)
    await_file(Path.join(directory, "started"))
    shell = read_pid(directory, "shell-pid")
    child = read_pid(directory, "child-pid")
    assert process_running?(shell)
    assert process_running?(child)

    assert {:ok, %{status: :confirmed}} = AsyncRuntime.shutdown_confirmed(runtime)
    refute process_running?(shell)
    refute process_running?(child)
    assert Task.Supervisor.children(ctx.hook_task_supervisor) == []
  end

  test "a real Runner rescue returning normally preserves its actual lifecycle exception", %{
    runtime: runtime,
    ctx: ctx
  } do
    owner = self()

    ctx =
      ctx
      |> Map.put(:hook_shell, {:invalid, :port_argument})
      |> Map.put(:hook_async_callback, fn _text, warnings ->
        send(owner, {:finished, warnings})
      end)

    assert {:proceed, []} = Runner.run(:stop, [command("printf unreachable")], ctx)
    assert_receive {:finished, [_ | _]}, 2_000

    assert {:error,
            {:async_hook_cleanup_unconfirmed, [%{reason: {:command_lifecycle_exception, error}}]}} =
             AsyncRuntime.shutdown_confirmed(runtime)

    assert is_exception(error)
    assert Exception.message(error) != ""
    assert Task.Supervisor.children(ctx.hook_task_supervisor) == []
  end

  test "natural command exit preserves detached helpers but cannot confirm they are closed", %{
    runtime: runtime,
    ctx: ctx,
    tmp_dir: directory
  } do
    owner = self()

    ctx =
      Map.put(ctx, :hook_async_callback, fn _text, warnings ->
        send(owner, {:finished, warnings})
      end)

    script = ~S(sleep 30 </dev/null >/dev/null 2>&1 & printf '%s' "$!" > child-pid; exit 0)
    assert {:proceed, []} = Runner.run(:stop, [command(script)], ctx)
    assert_receive {:finished, []}, 2_000
    child = read_pid(directory, "child-pid")

    on_exit(fn ->
      System.cmd("kill", ["-KILL", "--", Integer.to_string(child)], stderr_to_stdout: true)
    end)

    assert process_running?(child)

    assert {:error,
            {:async_hook_cleanup_unconfirmed,
             [%{reason: {:command_processes_still_active, active}}]}} =
             AsyncRuntime.shutdown_confirmed(runtime)

    assert child in active
    assert process_running?(child)
  end

  defp command(script) do
    %Spec{
      event: :stop,
      handler: %Command{cmd: script, timeout_ms: 10_000, async: true},
      matcher: :any,
      origin: {:user, "/user"},
      dialect: :pi,
      trusted?: true
    }
  end

  defp read_pid(directory, name),
    do: directory |> Path.join(name) |> File.read!() |> String.to_integer()

  defp process_running?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        [_, state] = Regex.run(~r/\A[0-9]+ \(.*\) ([A-Za-z]) /s, stat)
        state not in ["Z", "X"]

      {:error, :enoent} ->
        false
    end
  end

  defp await_file(path, attempts \\ 200)
  defp await_file(_path, 0), do: flunk("real hook command did not start")

  defp await_file(path, attempts) do
    if File.exists?(path),
      do: :ok,
      else:
        (
          Process.sleep(5)
          await_file(path, attempts - 1)
        )
  end
end
