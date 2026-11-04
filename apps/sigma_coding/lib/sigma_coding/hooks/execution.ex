defmodule Sigma.Coding.Hooks.Execution do
  @moduledoc """
  Owns the pre-Runtime hook gate and observations for one Goal executor.

  Pending async hooks must pass this gate before launching. Sealing discards
  those pending starts and joins every actual effect worker and its cleanup.
  The enclosing session runtime owns this scope through its ordinary command
  retirement path; an accepted prompt releases async work to that lifetime.
  """

  use GenServer, restart: :temporary

  alias Sigma.Coding.Hooks.AsyncRuntime

  def start(owner, runtime, recipient, admission, control) do
    DynamicSupervisor.start_child(
      Sigma.Coding.Hooks.AsyncSupervisor,
      {__MODULE__, {owner, runtime, recipient, admission, control}}
    )
  end

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  def reserve(scope, id, kind) do
    GenServer.call(scope, {:reserve, id, kind}, :infinity)
  catch
    :exit, _ -> {:error, :closed}
  end

  def discard(scope, id), do: GenServer.call(scope, {:discard, id}, :infinity)

  def track(scope, id, worker) do
    GenServer.call(scope, {:track, id, worker}, :infinity)
  catch
    :exit, _ -> {:error, :closed}
  end

  def completed(scope, id, result, cleanup),
    do: send(scope, {:completed, self(), id, result, cleanup})

  def seal(scope, terminal), do: GenServer.call(scope, {:seal, terminal}, :infinity)
  def release(scope), do: GenServer.call(scope, :release, :infinity)

  @impl true
  def init({owner, runtime, recipient, admission, control}) do
    Process.flag(:trap_exit, true)

    case AsyncRuntime.track_command(runtime, self()) do
      :ok ->
        {:ok,
         %{
           owner: owner,
           owner_ref: Process.monitor(owner),
           runtime: runtime,
           recipient: recipient,
           admission: admission,
           control: control,
           mode: :open,
           terminal: nil,
           effects: %{},
           records: [],
           failures: []
         }}

      error ->
        {:stop, error}
    end
  end

  @impl true
  def handle_call({:reserve, id, kind}, _from, %{mode: :open} = state) do
    if Map.has_key?(state.effects, id) do
      {:reply, {:error, :duplicate_effect}, state}
    else
      effect = %{kind: kind, worker: nil, monitor: nil, report: nil}
      {:reply, :ok, %{state | effects: Map.put(state.effects, id, effect)}}
    end
  end

  def handle_call({:reserve, _id, _kind}, _from, state),
    do: {:reply, {:error, :closed}, state}

  def handle_call({:discard, id}, _from, state) do
    state =
      if match?(%{worker: nil}, state.effects[id]),
        do: %{state | effects: Map.delete(state.effects, id)},
        else: state

    {:reply, :ok, state}
  end

  def handle_call({:track, id, worker}, _from, %{mode: mode} = state)
      when mode in [:open, :released] do
    case state.effects[id] do
      %{worker: nil} = effect ->
        effect = %{effect | worker: worker, monitor: Process.monitor(worker)}
        {:reply, :ok, %{state | effects: Map.put(state.effects, id, effect)}}

      _ ->
        {:reply, {:error, :closed}, state}
    end
  end

  def handle_call({:track, _id, _worker}, _from, state),
    do: {:reply, {:error, :closed}, state}

  def handle_call({:seal, terminal}, _from, %{mode: :open} = state),
    do: reply_or_finish(seal_state(state, terminal))

  def handle_call({:seal, terminal}, _from, %{mode: :sealed, terminal: terminal} = state),
    do: {:reply, :ok, state}

  def handle_call(:release, _from, %{mode: :open} = state) do
    Process.demonitor(state.owner_ref, [:flush])
    reply_or_finish(%{state | mode: :released, owner_ref: nil})
  end

  @impl true
  def handle_info({:completed, worker, id, result, cleanup}, state) do
    case state.effects[id] do
      %{worker: ^worker, report: nil} = effect ->
        record = %{effect_id: id, kind: effect.kind, result: result}
        effect = %{effect | report: cleanup}

        {:noreply,
         %{
           state
           | records: state.records ++ [record],
             effects: Map.put(state.effects, id, effect)
         }}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, owner, cause}, %{owner_ref: ref, owner: owner} = state) do
    terminal =
      state.terminal ||
        case :atomics.get(state.control, 1) do
          5 -> %{"status" => "cancelled"}
          _ -> {:error, {:executor_exited_before_host_result, cause}}
        end

    state |> seal_state(terminal) |> noreply_or_finish()
  end

  def handle_info({:DOWN, ref, :process, worker, cause}, state) do
    case Enum.find(state.effects, fn {_id, effect} ->
           effect.monitor == ref and effect.worker == worker
         end) do
      {id, effect} ->
        failures =
          case {cause, effect.report} do
            {:normal, {:ok, %{status: :confirmed}}} -> state.failures
            other -> state.failures ++ [%{effect_id: id, observation: other}]
          end

        %{state | effects: Map.delete(state.effects, id), failures: failures}
        |> noreply_or_finish()

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, _sender, :shutdown}, state),
    do: state |> seal_state(state.terminal || {:error, :session_closed}) |> noreply_or_finish()

  defp seal_state(state, terminal) do
    effects = Map.reject(state.effects, fn {_id, effect} -> is_nil(effect.worker) end)
    Enum.each(effects, fn {_id, effect} -> Process.exit(effect.worker, :shutdown) end)
    %{state | mode: :sealed, terminal: terminal, effects: effects}
  end

  defp reply_or_finish(%{effects: effects, mode: mode} = state)
       when map_size(effects) == 0 and mode != :open do
    finish(state)
    {:stop, :normal, :ok, state}
  end

  defp reply_or_finish(state), do: {:reply, :ok, state}

  defp noreply_or_finish(%{effects: effects, mode: mode} = state)
       when map_size(effects) == 0 and mode != :open do
    finish(state)
    {:stop, :normal, state}
  end

  defp noreply_or_finish(state), do: {:noreply, state}

  defp finish(state) do
    cleanup = if state.failures == [], do: :confirmed, else: {:error, state.failures}

    if state.mode == :sealed do
      send(state.recipient, {
        :goal_host_hooks_settled,
        self(),
        state.admission,
        %{records: state.records, cleanup: cleanup},
        state.terminal
      })
    end

    report =
      if cleanup == :confirmed,
        do: {:ok, %{status: :confirmed}},
        else: {:error, {:host_hook_cleanup_unconfirmed, state.failures}}

    AsyncRuntime.command_settled(state.runtime, report)
  end
end
