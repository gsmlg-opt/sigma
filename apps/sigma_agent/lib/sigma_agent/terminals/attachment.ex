defmodule Sigma.Agent.Terminals.Attachment do
  @moduledoc "Per-observer bounded delivery relay."

  use GenServer, restart: :temporary

  def start(opts), do: GenServer.start(__MODULE__, opts)
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def deliver(relay, events), do: GenServer.cast(relay, {:deliver, List.wrap(events)})
  def deliver_snapshot(relay, snapshot), do: GenServer.cast(relay, {:deliver_snapshot, snapshot})
  def require_resync(relay, reason), do: GenServer.cast(relay, {:require_resync, reason})
  def reset(relay), do: GenServer.call(relay, :reset)
  def touch(relay), do: GenServer.call(relay, :touch)
  def acknowledge(relay, sequence), do: GenServer.call(relay, {:acknowledge, sequence})
  def stop(relay), do: GenServer.stop(relay, :normal)
  def status(relay), do: GenServer.call(relay, :status)

  @impl true
  def init(opts) do
    observer = Keyword.fetch!(opts, :observer)

    state =
      %{
        id: Keyword.fetch!(opts, :id),
        owner: Keyword.fetch!(opts, :owner),
        owner_ref: Process.monitor(Keyword.fetch!(opts, :owner)),
        run: Keyword.fetch!(opts, :run),
        observer: observer,
        observer_ref: Process.monitor(observer),
        maximum: Keyword.fetch!(opts, :maximum),
        pending: [],
        pending_bytes: 0,
        delivered_sequence: 0,
        rendered_sequence: Keyword.get(opts, :rendered_sequence, 0),
        paused?: false,
        inactivity_ms: Keyword.fetch!(opts, :inactivity_ms),
        inactivity_timer: nil,
        activity_epoch: 0
      }

    {:ok, schedule_expiry(state)}
  end

  @impl true
  def handle_cast({:deliver_snapshot, snapshot}, state) do
    event = %{sequence: snapshot.sequence, bytes: snapshot.bytes, snapshot: true}
    bytes = event_bytes(event)

    if state.pending_bytes + bytes > state.maximum do
      send(state.observer, {:terminal_stream, state.id, {:resync_required, :slow_observer}})
      {:noreply, %{state | paused?: true, pending: [], pending_bytes: 0}}
    else
      send(state.observer, {:terminal_stream, state.id, {:snapshot, snapshot}})

      state = %{
        state
        | pending: [event | state.pending],
          pending_bytes: state.pending_bytes + bytes,
          delivered_sequence: max(state.delivered_sequence, snapshot.sequence)
      }

      emit_buffered(state)
      {:noreply, state}
    end
  end

  def handle_cast({:require_resync, reason}, state) do
    send(state.observer, {:terminal_stream, state.id, {:resync_required, reason}})
    {:noreply, %{state | paused?: true, pending: [], pending_bytes: 0}}
  end

  def handle_cast({:deliver, _events}, %{paused?: true} = state), do: {:noreply, state}

  def handle_cast({:deliver, events}, state) do
    bytes = Enum.reduce(events, 0, &(event_bytes(&1) + &2))

    if state.pending_bytes + bytes > state.maximum do
      send(state.observer, {:terminal_stream, state.id, {:resync_required, :slow_observer}})
      {:noreply, %{state | paused?: true, pending: [], pending_bytes: 0}}
    else
      Enum.each(events, &send(state.observer, {:terminal_stream, state.id, {:event, &1}}))
      delivered = Enum.reduce(events, state.delivered_sequence, &max(&1.sequence, &2))

      state = %{
        state
        | pending: state.pending ++ events,
          pending_bytes: state.pending_bytes + bytes,
          delivered_sequence: delivered
      }

      emit_buffered(state)
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:reset, _from, state) do
    {:reply, :ok, touch_state(%{state | pending: [], pending_bytes: 0, paused?: false})}
  end

  def handle_call(:touch, _from, state), do: {:reply, :ok, touch_state(state)}

  def handle_call({:acknowledge, sequence}, _from, state)
      when is_integer(sequence) and sequence >= 0 do
    cond do
      sequence < state.rendered_sequence ->
        {:reply, {:error, :stale_acknowledgement}, state}

      sequence > state.delivered_sequence ->
        {:reply, {:error, :future_acknowledgement}, state}

      true ->
        {acked, pending} = Enum.split_while(state.pending, &(&1.sequence <= sequence))
        bytes = Enum.reduce(acked, 0, &(event_bytes(&1) + &2))

        state =
          touch_state(%{
            state
            | pending: pending,
              pending_bytes: state.pending_bytes - bytes,
              rendered_sequence: sequence
          })

        emit_buffered(state)
        {:reply, :ok, state}
    end
  end

  def handle_call(:status, _from, state), do: {:reply, Map.drop(state, [:observer_ref]), state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{observer_ref: ref} = state) do
    send(state.owner, {:terminal_attachment_down, self(), state.id, reason})
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:expire_inactive, epoch}, %{activity_epoch: epoch} = state) do
    send(state.owner, {:terminal_attachment_expired, self(), state.id})
    {:stop, :normal, %{state | inactivity_timer: nil}}
  end

  def handle_info({:expire_inactive, _old_epoch}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_reference(state.inactivity_timer), do: Process.cancel_timer(state.inactivity_timer)
    :ok
  end

  defp touch_state(state) do
    if is_reference(state.inactivity_timer), do: Process.cancel_timer(state.inactivity_timer)

    state
    |> Map.update!(:activity_epoch, &(&1 + 1))
    |> schedule_expiry()
  end

  defp schedule_expiry(state) do
    timer =
      Process.send_after(self(), {:expire_inactive, state.activity_epoch}, state.inactivity_ms)

    %{state | inactivity_timer: timer}
  end

  defp event_bytes(%{bytes: bytes}), do: byte_size(bytes)
  defp event_bytes(_event), do: 0

  defp emit_buffered(state) do
    run = state.run

    :telemetry.execute(
      [:sigma, :terminal, :buffer],
      %{buffered_bytes: state.pending_bytes},
      %{
        repository_id: run.terminal.session.repository_id,
        session_id: run.terminal.session.session_id,
        incarnation_id: run.terminal.session.incarnation_id,
        terminal_id: run.terminal.terminal_id,
        generation: run.generation,
        attachment_id: state.id
      }
    )
  end
end
