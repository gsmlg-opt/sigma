defmodule Sigma.Coding.Hooks.AsyncRuntime do
  @moduledoc """
  Owns one session's queued and running async hooks, with at most eight running.

  The session owner is monitored. Owner exit and explicit shutdown discard queued
  hooks and cancel running tasks; normally completed hooks release their helpers.
  Model-request observers are tracked separately without consuming async slots.
  Shutdown kills and joins these observers before returning.
  Command workers register before launching subprocesses; shutdown asks them to
  clean up and joins them before acknowledging closure.
  """

  use GenServer, restart: :temporary
  require Logger

  @max_concurrency 8

  def start(owner, options \\ []) when is_pid(owner) do
    DynamicSupervisor.start_child(
      Keyword.get(options, :runtime_supervisor, Sigma.Coding.Hooks.AsyncSupervisor),
      {__MODULE__, {owner, options}}
    )
  end

  def start_link({owner, options}), do: GenServer.start_link(__MODULE__, {owner, options})

  @doc "Queue a hook, or discard it if the session runtime has shut down."
  def schedule(runtime, fun) when is_function(fun, 0) do
    GenServer.call(runtime, {:schedule, fun}, :infinity)
  catch
    :exit, _ -> :ok
  end

  @doc "Register an observer before it starts work; a closing runtime rejects it."
  def track(runtime, observer) when is_pid(observer) do
    GenServer.call(runtime, {:track, observer}, :infinity)
  catch
    :exit, _ -> {:error, :closed}
  end

  @doc "Register a subprocess worker before allowing it to launch a command."
  def track_command(runtime, worker) when is_pid(worker) do
    GenServer.call(runtime, {:track_command, worker}, :infinity)
  catch
    :exit, _ -> {:error, :closed}
  end

  @doc "Report this command worker's actual cleanup before exiting; never waits on shutdown."
  def command_settled(runtime, result) when is_pid(runtime) do
    send(runtime, {:async_hook_command_settled, self(), result})
    :ok
  end

  @doc "Best-effort, idempotent shutdown; use shutdown_confirmed/1 for a retirement receipt."
  def shutdown(runtime) do
    ref = Process.monitor(runtime)

    try do
      GenServer.call(runtime, :shutdown, :infinity)
    catch
      :exit, _ -> :ok
    end

    # Join the runtime as well as the call: registered cleanup runs in terminate/2.
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    end
  end

  @doc "Joins actual cleanup and returns confirmation only after normal runtime termination."
  def shutdown_confirmed(runtime) do
    ref = Process.monitor(runtime)

    acknowledgement =
      try do
        GenServer.call(runtime, :shutdown_confirmed, :infinity)
      catch
        :exit, reason -> {:exit, reason}
      end

    receive do
      {:DOWN, ^ref, :process, _pid, reason} ->
        case {acknowledgement, reason} do
          {{:ok, %{status: :confirmed}} = confirmed, :normal} ->
            confirmed

          {{:error, _} = error, :normal} ->
            error

          _ ->
            {:error,
             {:async_runtime_shutdown_unconfirmed,
              %{acknowledgement: acknowledgement, termination: reason}}}
        end
    end
  end

  @impl true
  def init({owner, options}) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       owner_ref: Process.monitor(owner),
       task_supervisor:
         Keyword.get(options, :task_supervisor, Sigma.Coding.Dispatcher.TaskSupervisor),
       running: %{},
       observers: %{},
       command_workers: %{},
       command_failures: %{},
       command_settlements: %{},
       retired: false,
       queued: :queue.new()
     }}
  end

  @impl true
  def handle_call({:track, observer}, _from, state) do
    ref = Process.monitor(observer)
    {:reply, :ok, %{state | observers: Map.put(state.observers, ref, observer)}}
  end

  def handle_call({:track_command, worker}, _from, state) do
    ref = Process.monitor(worker)
    {:reply, :ok, %{state | command_workers: Map.put(state.command_workers, ref, worker)}}
  end

  def handle_call({:schedule, fun}, _from, state) do
    state = %{state | queued: :queue.in(fun, state.queued)}
    {:reply, :ok, launch_queued(state)}
  end

  def handle_call(:shutdown, _from, state), do: {:stop, :normal, :ok, state}

  def handle_call(:shutdown_confirmed, _from, state) do
    {result, state} = retire_workers(state)
    {:stop, :normal, result, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, launch_queued(%{state | running: Map.delete(state.running, ref)})}
  end

  def handle_info({:async_hook_command_settled, pid, result}, state) do
    if pid in Map.values(state.command_workers) do
      {:noreply, %{state | command_settlements: Map.put(state.command_settlements, pid, result)}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    failures =
      if Map.has_key?(state.command_workers, ref) do
        retain_failure(state.command_failures, pid, reason, state.command_settlements[pid])
      else
        state.command_failures
      end

    commands = Map.delete(state.command_workers, ref)

    settlements =
      if pid in Map.values(commands),
        do: state.command_settlements,
        else: Map.delete(state.command_settlements, pid)

    state = %{
      state
      | running: Map.delete(state.running, ref),
        observers: Map.delete(state.observers, ref),
        command_workers: commands,
        command_settlements: settlements,
        command_failures: failures
    }

    {:noreply, launch_queued(state)}
  end

  @impl true
  def terminate(_reason, %{retired: true}), do: :ok

  def terminate(_reason, state) do
    case retire_workers(state) do
      {{:error, cause}, _state} ->
        Logger.error("Async hook runtime cleanup is unconfirmed: #{inspect(cause)}")

      _ ->
        :ok
    end
  end

  defp retire_workers(state) do
    commands = state.command_workers |> Map.values() |> MapSet.new()

    Enum.each(state.observers, fn {_ref, pid} ->
      unless MapSet.member?(commands, pid), do: Process.exit(pid, :kill)
    end)

    Enum.each(state.running, fn {_ref, task} ->
      unless MapSet.member?(commands, task.pid), do: Task.shutdown(task, :brutal_kill)
    end)

    # Runner workers trap this exit and finish their managed OS cleanup. Killing
    # only the outer hook task leaves that cleanup running after our ACK.
    Enum.each(commands, &Process.exit(&1, :shutdown))

    {failures, settlements} =
      Enum.reduce(state.command_workers, {state.command_failures, state.command_settlements}, fn
        {ref, pid}, {failures, settlements} ->
          {reason, settlements} = join_command(ref, pid, commands, settlements)
          {retain_failure(failures, pid, reason, settlements[pid]), settlements}
      end)

    Enum.each(state.observers, fn {ref, pid} ->
      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      end
    end)

    result =
      if map_size(failures) == 0 do
        {:ok, %{status: :confirmed}}
      else
        causes =
          failures
          |> Enum.sort()
          |> Enum.map(fn {pid, reason} -> %{worker: pid, reason: reason} end)

        {:error, {:async_hook_cleanup_unconfirmed, causes}}
      end

    {result,
     %{
       state
       | running: %{},
         observers: %{},
         command_workers: %{},
         queued: :queue.new(),
         command_failures: failures,
         command_settlements: settlements,
         retired: true
     }}
  end

  defp join_command(ref, pid, commands, settlements) do
    receive do
      {:async_hook_command_settled, worker, result} ->
        settlements =
          if MapSet.member?(commands, worker),
            do: Map.put(settlements, worker, result),
            else: settlements

        join_command(ref, pid, commands, settlements)

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {reason, settlements}
    end
  end

  defp retain_failure(failures, _pid, :normal, {:ok, %{status: :confirmed}}), do: failures
  defp retain_failure(failures, pid, :normal, {:error, cause}), do: Map.put(failures, pid, cause)

  defp retain_failure(failures, pid, :normal, nil),
    do: Map.put(failures, pid, :command_cleanup_not_reported)

  defp retain_failure(failures, pid, :normal, other),
    do: Map.put(failures, pid, {:invalid_command_cleanup_report, other})

  defp retain_failure(failures, pid, reason, {:error, cause}),
    do: Map.put(failures, pid, %{termination: reason, cleanup: cause})

  defp retain_failure(failures, pid, reason, _settlement), do: Map.put(failures, pid, reason)

  defp launch_queued(state) when map_size(state.running) >= @max_concurrency, do: state

  defp launch_queued(state) do
    case :queue.out(state.queued) do
      {{:value, fun}, queued} ->
        task = Task.Supervisor.async_nolink(state.task_supervisor, fun)
        launch_queued(%{state | queued: queued, running: Map.put(state.running, task.ref, task)})

      {:empty, _queued} ->
        state
    end
  end
end
