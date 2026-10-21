defmodule Sigma.Coding.Hooks.AsyncRuntimeTest do
  use ExUnit.Case, async: true

  alias Sigma.Coding.Hooks.AsyncRuntime

  setup do
    task_supervisor = start_supervised!({Task.Supervisor, []})
    runtime_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    %{options: [task_supervisor: task_supervisor, runtime_supervisor: runtime_supervisor]}
  end

  test "only eight hooks run concurrently and queued hooks start in order", %{options: options} do
    {:ok, runtime} = AsyncRuntime.start(self(), options)
    test_pid = self()

    for number <- 1..10 do
      assert :ok =
               AsyncRuntime.schedule(runtime, fn ->
                 send(test_pid, {:started, number, self()})

                 receive do
                   :release -> :ok
                 end
               end)
    end

    running =
      for _ <- 1..8 do
        assert_receive {:started, number, pid}
        {number, pid}
      end

    assert running |> Enum.map(&elem(&1, 0)) |> Enum.sort() == Enum.to_list(1..8)
    refute_receive {:started, _, _}

    [{_, first}, {_, second} | _] = running
    send(first, :release)
    assert_receive {:started, 9, _}
    refute_receive {:started, 10, _}
    send(second, :release)
    assert_receive {:started, 10, _}
    assert :ok = AsyncRuntime.shutdown(runtime)
  end

  test "owner exit cancels running hooks and drops the queue", %{options: options} do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    {:ok, runtime} = AsyncRuntime.start(owner, options)
    runtime_ref = Process.monitor(runtime)
    running = hold_eight(runtime)
    test_pid = self()
    AsyncRuntime.schedule(runtime, fn -> send(test_pid, :queued_hook_started) end)

    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^runtime_ref, :process, ^runtime, :normal}
    for {pid, ref} <- running, do: assert_receive({:DOWN, ^ref, :process, ^pid, :killed})
    refute_receive :queued_hook_started
  end

  test "explicit shutdown cancels tasks, drops the queue and is idempotent", %{options: options} do
    {:ok, runtime} = AsyncRuntime.start(self(), options)
    running = hold_eight(runtime)
    test_pid = self()
    AsyncRuntime.schedule(runtime, fn -> send(test_pid, :queued_hook_started) end)

    assert :ok = AsyncRuntime.shutdown(runtime)
    for {pid, ref} <- running, do: assert_receive({:DOWN, ^ref, :process, ^pid, :killed})
    assert :ok = AsyncRuntime.shutdown(runtime)
    assert :ok = AsyncRuntime.schedule(runtime, fn -> send(test_pid, :late_hook_started) end)
    refute_receive :queued_hook_started
    refute_receive :late_hook_started
  end

  test "observer registration is synchronous and independent of all eight async slots", %{
    options: options
  } do
    {:ok, runtime} = AsyncRuntime.start(self(), options)
    running = hold_eight(runtime)
    observers = for _ <- 1..12, do: blocked_observer()

    for pid <- observers, do: assert(:ok == AsyncRuntime.track(runtime, pid))
    assert map_size(:sys.get_state(runtime).observers) == 12
    test_pid = self()
    AsyncRuntime.schedule(runtime, fn -> send(test_pid, :queued_hook_started) end)

    [observer | _] = observers
    observer_ref = Process.monitor(observer)
    send(observer, :finish)
    assert_receive {:DOWN, ^observer_ref, :process, ^observer, :normal}
    await_observers(runtime, 11)
    refute_receive :queued_hook_started
    assert Enum.all?(running, fn {pid, _ref} -> Process.alive?(pid) end)

    assert :ok = AsyncRuntime.shutdown(runtime)
    refute Enum.any?(observers, &Process.alive?/1)
  end

  test "shutdown joins blocked observers and registration reports a closed runtime", %{
    options: options
  } do
    {:ok, runtime} = AsyncRuntime.start(self(), options)
    observers = for _ <- 1..12, do: blocked_observer()
    for pid <- observers, do: assert(:ok == AsyncRuntime.track(runtime, pid))
    refs = Enum.map(observers, &{&1, Process.monitor(&1)})

    assert :ok = AsyncRuntime.shutdown(runtime)
    refute Process.alive?(runtime)

    for {pid, ref} <- refs do
      refute Process.alive?(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    end

    assert {:error, :closed} = AsyncRuntime.track(runtime, self())
    assert :ok = AsyncRuntime.shutdown(runtime)
  end

  test "owner death joins blocked observers before the runtime exits", %{options: options} do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    {:ok, runtime} = AsyncRuntime.start(owner, options)
    runtime_ref = Process.monitor(runtime)
    observers = for _ <- 1..12, do: blocked_observer()
    for pid <- observers, do: assert(:ok == AsyncRuntime.track(runtime, pid))

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^runtime_ref, :process, ^runtime, :normal}
    refute Enum.any?(observers, &Process.alive?/1)
    assert {:error, :closed} = AsyncRuntime.track(runtime, self())
  end

  @tag capture_log: true
  test "a crashed hook releases its concurrency slot", %{options: options} do
    {:ok, runtime} = AsyncRuntime.start(self(), options)
    test_pid = self()

    AsyncRuntime.schedule(runtime, fn ->
      send(test_pid, {:will_crash, self()})

      receive do
        :crash -> raise "hook failed"
      end
    end)

    for _ <- 1..7 do
      AsyncRuntime.schedule(runtime, fn -> receive do: (:release -> :ok) end)
    end

    AsyncRuntime.schedule(runtime, fn -> send(test_pid, :recovered_slot) end)
    assert_receive {:will_crash, hook}
    refute_receive :recovered_slot
    send(hook, :crash)
    assert_receive :recovered_slot
    assert Process.alive?(runtime)
    AsyncRuntime.shutdown(runtime)
  end

  defp hold_eight(runtime) do
    test_pid = self()

    for _ <- 1..8 do
      AsyncRuntime.schedule(runtime, fn ->
        send(test_pid, {:running, self()})

        receive do
          :release -> :ok
        end
      end)
    end

    for _ <- 1..8 do
      assert_receive {:running, pid}
      {pid, Process.monitor(pid)}
    end
  end

  defp blocked_observer do
    spawn(fn ->
      Process.flag(:trap_exit, true)

      receive do
        :finish -> :ok
      end
    end)
  end

  defp await_observers(runtime, expected, attempts \\ 100)
  defp await_observers(_runtime, _expected, 0), do: flunk("Observer DOWN was not removed")

  defp await_observers(runtime, expected, attempts) do
    if map_size(:sys.get_state(runtime).observers) != expected do
      Process.sleep(1)
      await_observers(runtime, expected, attempts - 1)
    end
  end
end
