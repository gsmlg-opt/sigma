defmodule Sigma.Coding.Hooks.AsyncShutdownFunctionalTest do
  use ExUnit.Case, async: true

  alias Sigma.Coding.Hooks.AsyncRuntime

  setup do
    task_supervisor = start_supervised!({Task.Supervisor, []})
    runtime_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    assert {:ok, runtime} =
             AsyncRuntime.start(self(),
               task_supervisor: task_supervisor,
               runtime_supervisor: runtime_supervisor
             )

    %{runtime: runtime}
  end

  test "confirmed shutdown waits for actual command cleanup and joins observers", %{
    runtime: runtime
  } do
    owner = self()

    command =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        send(owner, {:command_ready, self()})

        receive do
          {:EXIT, ^runtime, :shutdown} ->
            send(owner, :command_cleanup_waiting)
            receive do: (:cleanup_complete -> :ok)
            AsyncRuntime.command_settled(runtime, {:ok, %{status: :confirmed}})
        end
      end)

    observer = spawn(fn -> receive do: (:finish -> :ok) end)

    on_exit(fn ->
      for pid <- [command, observer], Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    assert_receive {:command_ready, ^command}
    assert :ok = AsyncRuntime.track_command(runtime, command)
    assert :ok = AsyncRuntime.track(runtime, observer)
    shutdown = Task.async(fn -> AsyncRuntime.shutdown_confirmed(runtime) end)
    assert_receive :command_cleanup_waiting
    assert Task.yield(shutdown, 50) == nil
    send(command, :cleanup_complete)
    assert {:ok, %{status: :confirmed}} = Task.await(shutdown)
    refute Process.alive?(command)
    refute Process.alive?(observer)
    refute Process.alive?(runtime)
  end

  test "an actual command cleanup failure retains its cause", %{runtime: runtime} do
    owner = self()

    command =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        send(owner, {:command_ready, self()})

        receive do
          {:EXIT, ^runtime, :shutdown} ->
            AsyncRuntime.command_settled(
              runtime,
              {:error, {:command_cleanup_failed, :injected_failure}}
            )

            {:error, :normal_task_return}
        end
      end)

    assert_receive {:command_ready, ^command}
    assert :ok = AsyncRuntime.track_command(runtime, command)

    assert {:error,
            {:async_hook_cleanup_unconfirmed,
             [%{worker: ^command, reason: {:command_cleanup_failed, :injected_failure}}]}} =
             AsyncRuntime.shutdown_confirmed(runtime)

    refute Process.alive?(runtime)
    refute Process.alive?(command)
  end

  test "normal worker exit without its cleanup report remains unconfirmed", %{runtime: runtime} do
    command = spawn(fn -> receive do: (:finish -> :ok) end)
    assert :ok = AsyncRuntime.track_command(runtime, command)
    ref = Process.monitor(command)
    send(command, :finish)
    assert_receive {:DOWN, ^ref, :process, ^command, :normal}

    assert {:error,
            {:async_hook_cleanup_unconfirmed,
             [%{worker: ^command, reason: :command_cleanup_not_reported}]}} =
             AsyncRuntime.shutdown_confirmed(runtime)
  end

  test "duplicate command and observer registrations join every monitor without killing cleanup",
       %{
         runtime: runtime
       } do
    owner = self()

    command =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        send(owner, {:command_ready, self()})

        receive do
          {:EXIT, ^runtime, :shutdown} ->
            AsyncRuntime.command_settled(runtime, {:ok, %{status: :confirmed}})
        end
      end)

    assert_receive {:command_ready, ^command}
    assert :ok = AsyncRuntime.track_command(runtime, command)
    assert :ok = AsyncRuntime.track_command(runtime, command)
    assert :ok = AsyncRuntime.track(runtime, command)
    assert :ok = AsyncRuntime.track(runtime, command)
    assert {:ok, %{status: :confirmed}} = AsyncRuntime.shutdown_confirmed(runtime)
    refute Process.alive?(command)
  end

  test "a scheduled command worker reports before normal DOWN without brutal task shutdown", %{
    runtime: runtime
  } do
    owner = self()

    assert :ok =
             AsyncRuntime.schedule(runtime, fn ->
               Process.flag(:trap_exit, true)
               assert :ok = AsyncRuntime.track_command(runtime, self())
               send(owner, {:scheduled_command_ready, self()})

               receive do
                 {:EXIT, ^runtime, :shutdown} ->
                   AsyncRuntime.command_settled(runtime, {:ok, %{status: :confirmed}})
               end
             end)

    assert_receive {:scheduled_command_ready, command}
    assert {:ok, %{status: :confirmed}} = AsyncRuntime.shutdown_confirmed(runtime)
    refute Process.alive?(command)
  end

  test "a command worker lost before shutdown cannot become a confirmed receipt", %{
    runtime: runtime
  } do
    command = spawn(fn -> receive do: (:finish -> :ok) end)
    assert :ok = AsyncRuntime.track_command(runtime, command)
    ref = Process.monitor(command)
    Process.exit(command, :kill)
    assert_receive {:DOWN, ^ref, :process, ^command, :killed}

    assert {:error, {:async_hook_cleanup_unconfirmed, [%{worker: ^command, reason: :killed}]}} =
             AsyncRuntime.shutdown_confirmed(runtime)
  end

  test "a dead runtime has no successful cleanup acknowledgement", %{runtime: runtime} do
    ref = Process.monitor(runtime)
    Process.exit(runtime, :kill)
    assert_receive {:DOWN, ^ref, :process, ^runtime, :killed}

    assert {:error,
            {:async_runtime_shutdown_unconfirmed,
             %{acknowledgement: {:exit, {:noproc, _}}, termination: :noproc}}} =
             AsyncRuntime.shutdown_confirmed(runtime)
  end
end
