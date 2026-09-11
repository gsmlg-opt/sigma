defmodule Sigma.Agent.Terminals.Worker do
  @moduledoc "Temporary owner for one explicit terminal run."

  use GenServer, restart: :temporary

  alias Sigma.Agent.Terminals.{
    Attachment,
    BackendAdapter,
    ControllerLease,
    Error,
    Limits,
    ScreenStream
  }

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def start(worker), do: GenServer.call(worker, :start)

  def complete_start(worker, resource \\ %{}),
    do: GenServer.call(worker, {:complete_start, resource})

  def begin_cleanup(worker, reply_to, token),
    do: GenServer.cast(worker, {:begin_cleanup, reply_to, token})

  def backend_events(worker), do: GenServer.call(worker, :backend_events)

  def attach(worker, observer, attachment_id, catalog_revision, rendered_sequence, opts \\ []),
    do:
      GenServer.call(
        worker,
        {:attach, observer, attachment_id, catalog_revision, rendered_sequence, opts}
      )

  def detach(worker, attachment_id), do: GenServer.call(worker, {:detach, attachment_id})

  def acquire_control(worker, attachment_id),
    do: GenServer.call(worker, {:acquire_control, attachment_id})

  def takeover_control(worker, attachment_id, expected_epoch),
    do: GenServer.call(worker, {:takeover_control, attachment_id, expected_epoch})

  def renew_control(worker, attachment_id, epoch),
    do: GenServer.call(worker, {:renew_control, attachment_id, epoch})

  def release_control(worker, attachment_id, epoch),
    do: GenServer.call(worker, {:release_control, attachment_id, epoch})

  def input(worker, request, catalog_revision, bytes),
    do: GenServer.call(worker, {:input, request, catalog_revision, bytes})

  def resize(worker, request, catalog_revision, columns, rows),
    do: GenServer.call(worker, {:resize, request, catalog_revision, columns, rows})

  def output(worker, run, bytes), do: GenServer.call(worker, {:output, run, bytes})
  def checkpoint(worker, run, snapshot), do: GenServer.call(worker, {:checkpoint, run, snapshot})

  def request_checkpoint(worker, request_id),
    do: GenServer.call(worker, {:request_checkpoint, request_id})

  def acknowledge(worker, attachment_id, sequence),
    do: GenServer.call(worker, {:acknowledge, attachment_id, sequence})

  def resync(worker, attachment_id, rendered_sequence),
    do: GenServer.call(worker, {:resync, attachment_id, rendered_sequence})

  def attachment_status(worker, attachment_id),
    do: GenServer.call(worker, {:attachment_status, attachment_id})

  def touch_attachment(worker, attachment_id),
    do: GenServer.call(worker, {:touch_attachment, attachment_id})

  @impl true
  def init(opts) do
    backend = Keyword.fetch!(opts, :backend)
    backend_opts = Keyword.get(opts, :backend_opts, [])

    limits = Keyword.get(opts, :limits, Limits.new())
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)

    {:ok,
     %{
       backend: backend,
       backend_state: BackendAdapter.new(backend, backend_opts),
       manager: nil,
       run: Keyword.fetch!(opts, :run),
       attrs: Keyword.get(opts, :attrs, %{}),
       start_ref: nil,
       pending_checkpoint: nil,
       limits: limits,
       stream: ScreenStream.new(Keyword.fetch!(opts, :run), limits),
       lease: ControllerLease.new(),
       attachments: %{},
       clock: clock,
       clock_origin: clock.()
     }}
  end

  @impl true
  def handle_call(:start, {manager, _tag}, state) do
    case BackendAdapter.start(state.backend_state, state.run, state.attrs) do
      {:ok, backend_state} ->
        {:reply, :ok, %{state | backend_state: backend_state, manager: manager}}

      {:pending, ref, backend_state} ->
        {:reply, {:pending, ref},
         %{state | backend_state: backend_state, start_ref: ref, manager: manager}}

      {:error, reason, backend_state} ->
        {:reply, {:error, reason}, %{state | backend_state: backend_state, manager: manager}}
    end
  end

  def handle_call({:complete_start, resource}, _from, %{start_ref: ref} = state)
      when is_integer(ref) do
    case BackendAdapter.complete_start(state.backend_state, ref, resource) do
      {:ok, backend_state} ->
        {:reply, :ok, %{state | backend_state: backend_state, start_ref: nil}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:backend_events, _from, state) do
    {:reply, BackendAdapter.events(state.backend_state), state}
  end

  def handle_call(
        {:attach, observer, attachment_id, catalog_revision, rendered_sequence, opts},
        _from,
        state
      ) do
    cond do
      not is_pid(observer) or not Process.alive?(observer) ->
        {:reply, {:error, Error.new(:session_unavailable, %{reason: :observer_down})}, state}

      map_size(state.attachments) >= state.limits.max_observers_per_terminal ->
        {:reply, {:error, Error.new(:capacity_exhausted, %{resource: :terminal_observers})},
         state}

      Map.has_key?(state.attachments, attachment_id) ->
        {:reply, {:error, Error.new(:capacity_exhausted, %{resource: :attachment_id})}, state}

      true ->
        {:ok, relay} =
          Attachment.start(
            id: attachment_id,
            owner: self(),
            run: state.run,
            observer: observer,
            maximum: state.limits.max_pending_output_bytes_per_attachment,
            inactivity_ms: state.limits.attachment_inactivity_ms,
            rendered_sequence: rendered_sequence
          )

        relay_ref = Process.monitor(relay)
        attachment = %{pid: relay, ref: relay_ref, observer: observer}
        state = put_in(state.attachments[attachment_id], attachment)

        {control, state} =
          if Keyword.get(opts, :initial_control, false),
            do: grant_vacant(state, attachment_id),
            else: {control_status(state, attachment_id), state}

        case ScreenStream.delivery(state.stream, state.run, rendered_sequence) do
          {:ok, delivery} ->
            deliver_initial(relay, delivery)

            reply =
              Map.merge(control, %{
                attachment_id: attachment_id,
                run: state.run,
                catalog_revision: catalog_revision,
                dimensions: state.stream.dimensions,
                delivery: delivery
              })

            {:reply, {:ok, reply}, state}

          {:error, error} ->
            {_, state} = drop_attachment(state, attachment_id)
            {:reply, {:error, error}, state}
        end
    end
  end

  def handle_call({:detach, attachment_id}, _from, state) do
    {found?, state} = drop_attachment(state, attachment_id)
    {:reply, if(found?, do: :ok, else: {:error, Error.new(:not_controller)}), state}
  end

  def handle_call({:acquire_control, attachment_id}, _from, state) do
    with :ok <- attachment_exists(state, attachment_id),
         {:ok, lease} <-
           ControllerLease.acquire(state.lease, attachment_id, now_ms(state), state.limits) do
      state = set_lease(state, lease)
      {:reply, {:ok, control_status(state, attachment_id)}, state}
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:takeover_control, attachment_id, expected_epoch}, _from, state) do
    with :ok <- attachment_exists(state, attachment_id),
         {:ok, lease} <-
           ControllerLease.takeover(
             state.lease,
             attachment_id,
             expected_epoch,
             now_ms(state),
             state.limits
           ) do
      state = set_lease(state, lease)
      {:reply, {:ok, control_status(state, attachment_id)}, state}
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:renew_control, attachment_id, epoch}, _from, state) do
    with :ok <- attachment_exists(state, attachment_id),
         {:ok, lease} <-
           ControllerLease.renew(state.lease, attachment_id, epoch, now_ms(state), state.limits) do
      {:reply, {:ok, control_status(%{state | lease: lease}, attachment_id)},
       set_lease(state, lease)}
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:release_control, attachment_id, epoch}, _from, state) do
    case ControllerLease.release(state.lease, attachment_id, epoch) do
      {:ok, lease} -> {:reply, :ok, set_lease(state, lease)}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:input, request, catalog_revision, bytes}, _from, state) do
    current = %{run: state.run, catalog_revision: catalog_revision, lease: state.lease}

    with true <- is_binary(bytes) and byte_size(bytes) <= state.limits.max_input_frame_bytes,
         :ok <- attachment_exists(state, request.attachment_id),
         :ok <- ControllerLease.authorize(current, request, now_ms(state)),
         {:ok, backend_state} <- BackendAdapter.input(state.backend_state, state.run, bytes),
         :ok <- touch_relay(state, request.attachment_id) do
      {:reply, :ok, %{state | backend_state: backend_state}}
    else
      false ->
        {:reply, {:error, Error.new(:capacity_exhausted, %{resource: :input_frame})}, state}

      {:error, %Error{} = error} ->
        {:reply, {:error, error}, state}

      {:error, reason} ->
        {:reply, {:error, Error.new(:backend_missing, %{reason: reason})}, state}
    end
  end

  def handle_call({:resize, request, catalog_revision, columns, rows}, _from, state) do
    current = %{run: state.run, catalog_revision: catalog_revision, lease: state.lease}

    with true <- Limits.valid_dimensions?(state.limits, columns, rows),
         :ok <- attachment_exists(state, request.attachment_id),
         :ok <- ControllerLease.authorize(current, request, now_ms(state)),
         {:ok, backend_state} <-
           BackendAdapter.resize(state.backend_state, state.run, columns, rows, state.limits),
         :ok <- touch_relay(state, request.attachment_id) do
      if BackendAdapter.process?(backend_state) do
        {:reply, :ok, %{state | backend_state: backend_state}}
      else
        {:ok, event, stream} = ScreenStream.append_resize(state.stream, columns, rows)
        broadcast(state, event)
        {:reply, {:ok, event}, %{state | backend_state: backend_state, stream: stream}}
      end
    else
      false ->
        {:reply, {:error, Error.new(:invalid_dimensions)}, state}

      {:error, %Error{} = error} ->
        {:reply, {:error, error}, state}

      {:error, reason} ->
        {:reply, {:error, Error.new(:backend_missing, %{reason: reason})}, state}
    end
  end

  def handle_call({:output, run, bytes}, _from, %{run: run} = state) do
    with {:ok, frame, responses, stream} <- ScreenStream.append_output(state.stream, bytes),
         {:ok, backend_state} <- send_device_responses(state, responses) do
      broadcast(state, frame)
      {:reply, {:ok, frame}, %{state | stream: stream, backend_state: backend_state}}
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:output, _old_run, _bytes}, _from, state),
    do: {:reply, {:error, Error.new(:stale_run_generation)}, state}

  def handle_call({:checkpoint, run, snapshot}, _from, %{run: run} = state) do
    case ScreenStream.checkpoint(state.stream, snapshot) do
      {:ok, stream} -> {:reply, {:ok, stream.checkpoint}, %{state | stream: stream}}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:checkpoint, _old_run, _snapshot}, _from, state),
    do: {:reply, {:error, Error.new(:stale_run_generation)}, state}

  def handle_call({:request_checkpoint, request_id}, _from, state) when is_binary(request_id) do
    case BackendAdapter.checkpoint(state.backend_state, request_id) do
      :ok -> {:reply, :ok, %{state | pending_checkpoint: request_id}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:acknowledge, attachment_id, sequence}, _from, state) do
    with {:ok, relay} <- attachment_pid(state, attachment_id),
         :ok <- Attachment.acknowledge(relay, sequence) do
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:touch_attachment, attachment_id}, _from, state) do
    case touch_relay(state, attachment_id) do
      :ok -> {:reply, :ok, state}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:resync, attachment_id, rendered_sequence}, _from, state) do
    with {:ok, relay} <- attachment_pid(state, attachment_id),
         :ok <- Attachment.reset(relay),
         {:ok, delivery} <- ScreenStream.delivery(state.stream, state.run, rendered_sequence) do
      deliver_initial(relay, delivery)
      {:reply, {:ok, delivery}, state}
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:attachment_status, attachment_id}, _from, state) do
    with {:ok, relay} <- attachment_pid(state, attachment_id) do
      {:reply, {:ok, Attachment.status(relay)}, state}
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_cast({:begin_cleanup, reply_to, token}, state) do
    {result, backend_state} = BackendAdapter.cleanup(state.backend_state, state.run)
    send(reply_to, {:terminal_cleanup_result, self(), state.run, token, result})
    {:noreply, %{state | backend_state: backend_state}}
  end

  @impl true
  def handle_info({:terminal_attachment_down, relay, attachment_id, _reason}, state) do
    case state.attachments[attachment_id] do
      %{pid: ^relay} ->
        {_, state} = drop_attachment(state, attachment_id)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:terminal_attachment_expired, relay, attachment_id}, state) do
    case state.attachments[attachment_id] do
      %{pid: ^relay} ->
        {_, state} = drop_attachment(state, attachment_id)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:terminal_backend, backend, {:started, resource}},
        %{backend_state: adapter} = state
      ) do
    if process_backend?(adapter, backend) and not is_nil(state.start_ref) do
      send(state.manager, {:terminal_worker_started, self(), state.run, resource})
      {:noreply, %{state | start_ref: nil}}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:terminal_backend, backend, {:output, sequence, bytes}},
        %{backend_state: adapter} = state
      ) do
    if process_backend?(adapter, backend) do
      case ScreenStream.append_output(state.stream, sequence, bytes) do
        {:ok, frame, responses, stream} ->
          case send_device_responses(state, responses) do
            {:ok, backend_state} ->
              broadcast(state, frame)
              {:noreply, %{state | stream: stream, backend_state: backend_state}}

            {:error, _error} ->
              {:noreply, degrade_stream(state, :device_response_failed)}
          end

        {:error, %Error{} = error} ->
          {:noreply, degrade_stream(state, error)}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:terminal_backend, backend, {:resized, columns, rows}},
        %{backend_state: adapter} = state
      ) do
    if process_backend?(adapter, backend) do
      {:ok, event, stream} = ScreenStream.append_resize(state.stream, columns, rows)
      broadcast(state, event)
      {:noreply, %{state | stream: stream}}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:terminal_backend, backend, {:checkpoint, request_id, sequence, columns, rows, bytes}},
        %{backend_state: adapter} = state
      ) do
    if process_backend?(adapter, backend) do
      healing? = not is_nil(state.stream.degraded)

      case ScreenStream.accept_checkpoint(state.stream, sequence, columns, rows, bytes) do
        {:ok, stream} ->
          if healing?, do: deliver_recovery(state, stream.checkpoint)

          {:noreply,
           %{state | stream: stream, pending_checkpoint: clear_request(state, request_id)}}

        {:error, _error} ->
          {:noreply, degrade_stream(state, :stale_checkpoint)}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:terminal_backend, backend, {:checkpoint_failed, request_id, reason, details}},
        %{backend_state: adapter} = state
      ) do
    if process_backend?(adapter, backend) do
      error = Error.new(:snapshot_unavailable, Map.put(details, :reason, reason))

      Enum.each(state.attachments, fn {_id, attachment} ->
        Attachment.require_resync(attachment.pid, error)
      end)

      {:noreply,
       %{
         state
         | stream: %{state.stream | checkpoint: nil, degraded: error},
           pending_checkpoint: clear_request(state, request_id)
       }}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:terminal_backend, backend, {:shell_exit, status, _signal}},
        %{backend_state: adapter} = state
      ) do
    if process_backend?(adapter, backend) do
      send(state.manager, {:terminal_worker_shell_exited, self(), state.run, status})
    end

    {:noreply, state}
  end

  def handle_info({:terminal_backend, backend, {:backend_failed, reason}}, state) do
    if process_backend?(state.backend_state, backend) do
      send(state.manager, {:terminal_worker_backend_failed, self(), state.run, reason})
    end

    {:noreply, state}
  end

  def handle_info({:terminal_backend, _backend, {:cleanup, _result, _evidence}}, state),
    do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.attachments, fn {_id, attachment} -> attachment.ref == ref end) do
      {attachment_id, _attachment} ->
        {_, state} = drop_attachment(state, attachment_id)
        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:expire_control, epoch}, state) do
    if state.lease.epoch == epoch do
      lease = ControllerLease.expire(state.lease, now_ms(state))
      {:noreply, set_lease(state, lease)}
    else
      {:noreply, state}
    end
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :run)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  defp grant_vacant(state, attachment_id) do
    case ControllerLease.acquire(state.lease, attachment_id, now_ms(state), state.limits) do
      {:ok, lease} ->
        state = set_lease(state, lease)
        {control_status(state, attachment_id), state}

      {:error, _error} ->
        {control_status(state, attachment_id), state}
    end
  end

  defp set_lease(state, lease) do
    if is_integer(lease.expires_at_ms) do
      delay = max(lease.expires_at_ms - now_ms(state), 0)
      Process.send_after(self(), {:expire_control, lease.epoch}, delay)
    end

    state = %{state | lease: lease}

    Enum.each(state.attachments, fn {attachment_id, attachment} ->
      send(
        attachment.observer,
        {:terminal_control, attachment_id, control_status(state, attachment_id)}
      )
    end)

    state
  end

  defp control_status(state, attachment_id) do
    lease = ControllerLease.expire(state.lease, now_ms(state))
    %{controller: lease.controller_id == attachment_id, control_epoch: lease.epoch}
  end

  defp drop_attachment(state, attachment_id) do
    case Map.pop(state.attachments, attachment_id) do
      {nil, _attachments} ->
        {false, state}

      {%{pid: relay, ref: ref}, attachments} ->
        Process.demonitor(ref, [:flush])
        if Process.alive?(relay), do: Attachment.stop(relay)
        state = %{state | attachments: attachments}

        state =
          if state.lease.controller_id == attachment_id do
            {:ok, lease} =
              ControllerLease.release(state.lease, attachment_id, state.lease.epoch)

            set_lease(state, lease)
          else
            state
          end

        {true, state}
    end
  end

  defp attachment_exists(state, attachment_id) do
    if Map.has_key?(state.attachments, attachment_id),
      do: :ok,
      else: {:error, Error.new(:not_controller, %{reason: :attachment_not_found})}
  end

  defp attachment_pid(state, attachment_id) do
    case state.attachments[attachment_id] do
      %{pid: pid} -> {:ok, pid}
      nil -> {:error, Error.new(:not_controller, %{reason: :attachment_not_found})}
    end
  end

  defp deliver_initial(relay, %{snapshot: snapshot, events: events}) do
    Attachment.deliver_snapshot(relay, snapshot)
    Attachment.deliver(relay, events)
  end

  defp deliver_initial(relay, %{events: events}), do: Attachment.deliver(relay, events)

  defp broadcast(state, event) do
    Enum.each(state.attachments, fn {_id, attachment} ->
      Attachment.deliver(attachment.pid, event)
    end)
  end

  defp send_device_responses(state, responses) do
    Enum.reduce_while(responses, {:ok, state.backend_state}, fn response, {:ok, backend_state} ->
      case BackendAdapter.device_response(backend_state, state.run, response) do
        {:ok, backend_state} -> {:cont, {:ok, backend_state}}
        {:error, reason} -> {:halt, {:error, Error.new(:backend_missing, %{reason: reason})}}
      end
    end)
  end

  defp now_ms(state), do: max(state.clock.() - state.clock_origin, 0)

  defp touch_relay(state, attachment_id) do
    with {:ok, relay} <- attachment_pid(state, attachment_id), do: Attachment.touch(relay)
  end

  defp process_backend?(adapter, pid) do
    BackendAdapter.process?(adapter) and BackendAdapter.process_pid(adapter) == pid
  end

  defp degrade_stream(state, error_or_reason) do
    {expected, actual, reason} = degradation_details(state, error_or_reason)

    Enum.each(state.attachments, fn {_id, attachment} ->
      Attachment.require_resync(attachment.pid, reason)
    end)

    stream = ScreenStream.mark_gap(state.stream, expected, actual)

    request_id = state.pending_checkpoint || "recovery-#{System.unique_integer([:positive])}"
    _ = BackendAdapter.checkpoint(state.backend_state, request_id)
    %{state | stream: stream, pending_checkpoint: request_id}
  end

  defp deliver_recovery(state, checkpoint) do
    Enum.each(state.attachments, fn {_id, attachment} ->
      :ok = Attachment.reset(attachment.pid)
      Attachment.deliver_snapshot(attachment.pid, checkpoint)
    end)
  end

  defp clear_request(%{pending_checkpoint: request_id}, request_id), do: nil
  defp clear_request(state, _request_id), do: state.pending_checkpoint

  defp degradation_details(_state, %Error{details: details}) do
    {details[:expected], details[:actual], details[:reason]}
  end

  defp degradation_details(state, reason) do
    {state.stream.native_sequence + 1, nil, reason}
  end
end
