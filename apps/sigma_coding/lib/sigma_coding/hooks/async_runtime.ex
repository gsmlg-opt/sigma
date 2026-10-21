defmodule Sigma.Coding.Hooks.AsyncRuntime do
  @moduledoc """
  Owns one session's queued and running async hooks, with at most eight running.

  The session owner is monitored. Owner exit and explicit shutdown discard queued
  hooks and cancel running tasks; normally completed hooks release their helpers.
  Model-request observers are tracked separately without consuming async slots.
  Shutdown kills and joins these observers before returning.
  """

  use GenServer, restart: :temporary

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

  @doc "Cancel hooks, kill and join registered observers, and stop the runtime."
  def shutdown(runtime) do
    ref = Process.monitor(runtime)

    try do
      GenServer.call(runtime, :shutdown, :infinity)
    catch
      :exit, _ -> :ok
    end

    # Join the runtime as well as the call: observer cleanup runs in terminate/2.
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
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
       queued: :queue.new()
     }}
  end

  @impl true
  def handle_call({:track, observer}, _from, state) do
    ref = Process.monitor(observer)
    {:reply, :ok, %{state | observers: Map.put(state.observers, ref, observer)}}
  end

  def handle_call({:schedule, fun}, _from, state) do
    state = %{state | queued: :queue.in(fun, state.queued)}
    {:reply, :ok, launch_queued(state)}
  end

  def handle_call(:shutdown, _from, state), do: {:stop, :normal, :ok, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, launch_queued(%{state | running: Map.delete(state.running, ref)})}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    state = %{
      state
      | running: Map.delete(state.running, ref),
        observers: Map.delete(state.observers, ref)
    }

    {:noreply, launch_queued(state)}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.observers, fn {_ref, pid} -> Process.exit(pid, :kill) end)
    Enum.each(state.running, fn {_ref, task} -> Task.shutdown(task, :brutal_kill) end)

    Enum.each(state.observers, fn {ref, pid} ->
      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      end
    end)

    :ok
  end

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
