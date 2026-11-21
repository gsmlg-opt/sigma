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

  @checkpoint_timeout_ms 2_000

  def start(worker), do: GenServer.call(worker, :start)

  def reply_when_ready(worker, from, request),
    do: GenServer.cast(worker, {:reply_when_ready, from, request})

  def complete_start(worker, resource \\ %{}),
    do: GenServer.call(worker, {:complete_start, resource})

  def begin_cleanup(worker, reply_to, token),
    do: GenServer.cast(worker, {:begin_cleanup, reply_to, token})

  def backend_events(worker), do: GenServer.call(worker, :backend_events)
  def retain(worker), do: GenServer.call(worker, :retain)

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

    backend_opts =
      if backend == Sigma.Coding.Terminal.Native,
        do: Keyword.put(backend_opts, :terminal_state, true),
        else: backend_opts

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
       checkpoint_timer: nil,
       pending_deliveries: %{},
       native_shell_exited?: false,
       native_cleanup_result: nil,
       native_cleanup_waiter: nil,
       limits: limits,
       stream: ScreenStream.new(Keyword.fetch!(opts, :run), limits),
       lease: ControllerLease.new(),
       attachments: %{},
       retained?: false,
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

  def handle_call(:retain, _from, state) do
    state = set_lease(state, ControllerLease.new())
    error = Error.new(:snapshot_unavailable, %{reason: :terminal_exited})
    state = state |> clear_checkpoint() |> fail_pending_deliveries(error)
    {:reply, :ok, %{state | retained?: true}}
  end

  def handle_call(
        {:attach, observer, attachment_id, catalog_revision, rendered_sequence, opts},
        from,
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
        recovery_id = recovery_id(attachment_id)

        {:ok, relay} =
          Attachment.start(
            id: attachment_id,
            owner: self(),
            run: state.run,
            recovery_id: recovery_id,
            observer: observer,
            maximum: state.limits.max_pending_output_bytes_per_attachment,
            inactivity_ms: state.limits.attachment_inactivity_ms,
            rendered_sequence: rendered_sequence
          )

        relay_ref = Process.monitor(relay)
        attachment = %{pid: relay, ref: relay_ref, observer: observer}
        state = put_in(state.attachments[attachment_id], attachment)

        {_control, state} =
          if Keyword.get(opts, :initial_control, false),
            do: grant_vacant(state, attachment_id),
            else: {control_status(state, attachment_id), state}

        pending = %{
          kind: :attach,
          from: from,
          recovery_id: recovery_id,
          catalog_revision: catalog_revision
        }

        deliver_or_wait(state, attachment_id, rendered_sequence, pending)
    end
  end

  def handle_call({:detach, attachment_id}, _from, state) do
    {found?, state} = drop_attachment(state, attachment_id)
    {:reply, if(found?, do: :ok, else: {:error, Error.new(:not_controller)}), state}
  end

  def handle_call({:acquire_control, attachment_id}, _from, state) do
    with false <- state.retained?,
         :ok <- attachment_exists(state, attachment_id),
         {:ok, lease} <-
           ControllerLease.acquire(state.lease, attachment_id, now_ms(state), state.limits) do
      state = set_lease(state, lease)
      {:reply, {:ok, control_status(state, attachment_id)}, state}
    else
      true ->
        {:reply, {:error, Error.new(:session_unavailable, %{reason: :terminal_exited})}, state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:takeover_control, attachment_id, expected_epoch}, _from, state) do
    with false <- state.retained?,
         :ok <- attachment_exists(state, attachment_id),
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
      true ->
        {:reply, {:error, Error.new(:session_unavailable, %{reason: :terminal_exited})}, state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:renew_control, attachment_id, epoch}, _from, state) do
    with false <- state.retained?,
         :ok <- attachment_exists(state, attachment_id),
         {:ok, lease} <-
           ControllerLease.renew(state.lease, attachment_id, epoch, now_ms(state), state.limits) do
      {:reply, {:ok, control_status(%{state | lease: lease}, attachment_id)},
       set_lease(state, lease)}
    else
      true ->
        {:reply, {:error, Error.new(:session_unavailable, %{reason: :terminal_exited})}, state}

      {:error, error} ->
        {:reply, {:error, error}, state}
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

    with false <- state.retained?,
         true <- is_binary(bytes) and byte_size(bytes) <= state.limits.max_input_frame_bytes,
         :ok <- attachment_exists(state, request.attachment_id),
         :ok <- ControllerLease.authorize(current, request, now_ms(state)),
         {:ok, backend_state} <- BackendAdapter.input(state.backend_state, state.run, bytes),
         :ok <- touch_relay(state, request.attachment_id) do
      {:reply, :ok, %{state | backend_state: backend_state}}
    else
      true ->
        {:reply, {:error, Error.new(:session_unavailable, %{reason: :terminal_exited})}, state}

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

    with false <- state.retained?,
         true <- Limits.valid_dimensions?(state.limits, columns, rows),
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
      true ->
        {:reply, {:error, Error.new(:session_unavailable, %{reason: :terminal_exited})}, state}

      false ->
        {:reply, {:error, Error.new(:invalid_dimensions)}, state}

      {:error, %Error{} = error} ->
        {:reply, {:error, error}, state}

      {:error, reason} ->
        {:reply, {:error, Error.new(:backend_missing, %{reason: reason})}, state}
    end
  end

  def handle_call({:output, run, bytes}, _from, %{run: run} = state) do
    if state.retained? do
      {:reply, {:error, Error.new(:session_unavailable, %{reason: :terminal_exited})}, state}
    else
      with {:ok, frame, responses, stream} <- ScreenStream.append_output(state.stream, bytes),
           {:ok, backend_state} <- send_device_responses(state, responses) do
        broadcast(state, frame)
        {:reply, {:ok, frame}, %{state | stream: stream, backend_state: backend_state}}
      else
        {:error, error} -> {:reply, {:error, error}, state}
      end
    end
  end

  def handle_call({:output, _old_run, _bytes}, _from, state),
    do: {:reply, {:error, Error.new(:stale_run_generation)}, state}

  def handle_call({:checkpoint, run, snapshot}, _from, %{run: run} = state) do
    if state.retained? do
      {:reply, {:error, Error.new(:session_unavailable, %{reason: :terminal_exited})}, state}
    else
      case ScreenStream.checkpoint(state.stream, snapshot) do
        {:ok, stream} -> {:reply, {:ok, stream.checkpoint}, %{state | stream: stream}}
        {:error, error} -> {:reply, {:error, error}, state}
      end
    end
  end

  def handle_call({:checkpoint, _old_run, _snapshot}, _from, state),
    do: {:reply, {:error, Error.new(:stale_run_generation)}, state}

  def handle_call({:request_checkpoint, request_id}, _from, state) when is_binary(request_id) do
    case ensure_checkpoint(state, request_id) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, error} -> {:reply, {:error, error}, state}
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

  def handle_call({:resync, attachment_id, rendered_sequence}, from, state) do
    with :ok <- attachment_exists(state, attachment_id),
         false <- Map.has_key?(state.pending_deliveries, attachment_id) do
      pending = %{kind: :resync, from: from, recovery_id: recovery_id(attachment_id)}
      deliver_or_wait(state, attachment_id, rendered_sequence, pending)
    else
      true ->
        error = Error.new(:snapshot_unavailable, %{reason: :checkpoint_pending}, retryable: true)
        {:reply, {:error, error}, state}

      {:error, error} ->
        {:reply, {:error, error}, state}
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
  def handle_cast({:reply_when_ready, from, request}, state) do
    case handle_call(request, from, state) do
      {:reply, reply, state} ->
        GenServer.reply(from, reply)
        {:noreply, state}

      {:noreply, state} ->
        {:noreply, state}
    end
  end

  def handle_cast(
        {:begin_cleanup, reply_to, token},
        %{backend: Sigma.Coding.Terminal.Native} = state
      ) do
    cond do
      state.native_cleanup_result != nil ->
        send(
          reply_to,
          {:terminal_cleanup_result, self(), state.run, token, state.native_cleanup_result}
        )

        {:noreply, state}

      state.native_shell_exited? ->
        {:noreply, %{state | native_cleanup_waiter: {reply_to, token}}}

      true ->
        cleanup(state, reply_to, token)
    end
  catch
    :exit, {:noproc, _call} ->
      {:noreply, %{state | native_cleanup_waiter: {reply_to, token}}}
  end

  def handle_cast({:begin_cleanup, reply_to, token}, state),
    do: cleanup(state, reply_to, token)

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

              {:noreply,
               maybe_checkpoint(%{state | stream: stream, backend_state: backend_state})}

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
    if process_backend?(adapter, backend) and
         (request_id == state.pending_checkpoint or request_id == "final") do
      healing? = not is_nil(state.stream.degraded)
      state = clear_checkpoint(state)

      case ScreenStream.accept_checkpoint(state.stream, sequence, columns, rows, bytes) do
        {:ok, stream} ->
          state = %{state | stream: stream}
          if healing?, do: deliver_recovery(state, stream.checkpoint)
          {:noreply, complete_pending_deliveries(state)}

        {:error, error} ->
          {:noreply, fail_pending_deliveries(state, error)}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:terminal_backend, backend, {:checkpoint_failed, request_id, reason, details}},
        %{backend_state: adapter} = state
      ) do
    if process_backend?(adapter, backend) and
         (request_id == state.pending_checkpoint or request_id == "final") do
      error = Error.new(:snapshot_unavailable, Map.put(details, :reason, reason))
      state = %{state | stream: %{state.stream | bytes_since_checkpoint: 0}}
      {:noreply, state |> clear_checkpoint() |> fail_pending_deliveries(error)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:checkpoint_timeout, request_id}, %{pending_checkpoint: request_id} = state) do
    error = Error.new(:snapshot_unavailable, %{reason: :checkpoint_timeout})
    {:noreply, state |> clear_checkpoint() |> fail_pending_deliveries(error)}
  end

  def handle_info({:checkpoint_timeout, _old_request}, state), do: {:noreply, state}

  def handle_info(
        {:terminal_backend, backend, {:shell_exit, status, _signal}},
        %{backend_state: adapter} = state
      ) do
    if process_backend?(adapter, backend) do
      send(state.manager, {:terminal_worker_shell_exited, self(), state.run, status})
      {:noreply, %{state | native_shell_exited?: state.backend == Sigma.Coding.Terminal.Native}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:terminal_backend, backend, {:backend_failed, reason}}, state) do
    if process_backend?(state.backend_state, backend) do
      send(state.manager, {:terminal_worker_backend_failed, self(), state.run, reason})
    end

    {:noreply, state}
  end

  def handle_info({:terminal_backend, backend, {:cleanup, result, _evidence}}, state) do
    if state.backend == Sigma.Coding.Terminal.Native and
         process_backend?(state.backend_state, backend) do
      case state.native_cleanup_waiter do
        {reply_to, token} ->
          send(reply_to, {:terminal_cleanup_result, self(), state.run, token, result})

        nil ->
          :ok
      end

      {:noreply, %{state | native_cleanup_result: result, native_cleanup_waiter: nil}}
    else
      {:noreply, state}
    end
  end

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

  defp cleanup(state, reply_to, token) do
    {result, backend_state} = BackendAdapter.cleanup(state.backend_state, state.run)
    send(reply_to, {:terminal_cleanup_result, self(), state.run, token, result})
    {:noreply, %{state | backend_state: backend_state}}
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
        state = cancel_pending_delivery(state, attachment_id)
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

  defp broadcast(state, event) do
    Enum.each(state.attachments, fn {id, attachment} ->
      unless Map.has_key?(state.pending_deliveries, id) do
        Attachment.deliver(attachment.pid, event)
      end
    end)
  end

  defp send_device_responses(%{backend: Sigma.Coding.Terminal.Native} = state, _responses),
    do: {:ok, state.backend_state}

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

    state = %{state | stream: stream}

    case ensure_checkpoint(state) do
      {:ok, state} -> state
      {:error, _error} -> state
    end
  end

  defp deliver_recovery(state, checkpoint) do
    Enum.each(state.attachments, fn {attachment_id, attachment} ->
      unless Map.has_key?(state.pending_deliveries, attachment_id) do
        recovery_id = recovery_id(attachment_id)
        delivery = %{snapshot: checkpoint, events: []}
        _ = Attachment.recover(attachment.pid, recovery_id, checkpoint.sequence, delivery)
      end
    end)
  end

  defp recovery_id(attachment_id),
    do: "#{attachment_id}:#{System.unique_integer([:positive, :monotonic])}"

  defp delivery_requires_render?(%{snapshot: _snapshot}), do: true
  defp delivery_requires_render?(%{events: events}), do: events != []

  defp delivery_boundary(%{events: events, snapshot: snapshot}) do
    Enum.reduce(events, snapshot.sequence, &max(&1.sequence, &2))
  end

  defp delivery_boundary(%{events: events, next_sequence: next}) do
    Enum.reduce(events, next - 1, &max(&1.sequence, &2))
  end

  defp delivery_boundary(%{events: events}) do
    Enum.reduce(events, 0, &max(&1.sequence, &2))
  end

  defp deliver_or_wait(state, attachment_id, rendered_sequence, pending) do
    case ScreenStream.delivery(state.stream, state.run, rendered_sequence) do
      {:ok, delivery} ->
        {reply, state} = deliver(state, attachment_id, pending, delivery)
        {:reply, reply, state}

      {:error, error} ->
        with false <- state.retained?,
             true <- BackendAdapter.process?(state.backend_state),
             {:ok, state} <- ensure_checkpoint(state) do
          state = cancel_pending_delivery(state, attachment_id)
          state = put_in(state.pending_deliveries[attachment_id], pending)
          {:noreply, state}
        else
          _unavailable ->
            state =
              if pending.kind == :attach,
                do: elem(drop_attachment(state, attachment_id), 1),
                else: state

            {:reply, {:error, error}, state}
        end
    end
  end

  defp deliver(state, attachment_id, pending, delivery) do
    attachment = state.attachments[attachment_id]
    boundary = delivery_boundary(delivery)

    case Attachment.recover(attachment.pid, pending.recovery_id, boundary, delivery) do
      :ok ->
        result = %{
          recovery_id: pending.recovery_id,
          recovery_boundary: boundary,
          dimensions: state.stream.dimensions,
          requires_render: delivery_requires_render?(delivery),
          resynced: not delivery_requires_render?(delivery)
        }

        result =
          if pending.kind == :attach do
            control_status(state, attachment_id)
            |> Map.merge(result)
            |> Map.merge(%{
              attachment_id: attachment_id,
              run: state.run,
              catalog_revision: pending.catalog_revision,
              delivery: delivery
            })
          else
            Map.merge(delivery, result)
          end

        {{:ok, result}, state}

      {:error, :observer_down} ->
        {_, state} = drop_attachment(state, attachment_id)
        {{:error, Error.new(:session_unavailable, %{reason: :observer_down})}, state}
    end
  end

  defp complete_pending_deliveries(state) do
    pending_deliveries = state.pending_deliveries
    state = %{state | pending_deliveries: %{}}
    delivery = %{mode: :snapshot_then_replay, snapshot: state.stream.checkpoint, events: []}

    Enum.reduce(pending_deliveries, state, fn {id, pending}, state ->
      {reply, state} = deliver(state, id, pending, delivery)
      GenServer.reply(pending.from, reply)
      state
    end)
  end

  defp fail_pending_deliveries(state, error) do
    pending_deliveries = state.pending_deliveries
    state = %{state | pending_deliveries: %{}}

    Enum.reduce(pending_deliveries, state, fn {id, pending}, state ->
      GenServer.reply(pending.from, {:error, error})
      if pending.kind == :attach, do: elem(drop_attachment(state, id), 1), else: state
    end)
  end

  defp cancel_pending_delivery(state, id) do
    case Map.pop(state.pending_deliveries, id) do
      {nil, _pending} ->
        state

      {pending, remaining} ->
        GenServer.reply(
          pending.from,
          {:error, Error.new(:session_unavailable, %{reason: :observer_down})}
        )

        %{state | pending_deliveries: remaining}
    end
  end

  defp maybe_checkpoint(state) do
    if BackendAdapter.process?(state.backend_state) and
         state.stream.bytes_since_checkpoint >= max(div(state.limits.max_raw_replay_bytes, 2), 1) do
      case ensure_checkpoint(state) do
        {:ok, state} -> state
        {:error, _error} -> state
      end
    else
      state
    end
  end

  defp ensure_checkpoint(state, request_id \\ nil)

  defp ensure_checkpoint(%{retained?: true}, _request_id),
    do: {:error, Error.new(:session_unavailable, %{reason: :terminal_exited})}

  defp ensure_checkpoint(%{pending_checkpoint: pending} = state, _request_id)
       when not is_nil(pending),
       do: {:ok, state}

  defp ensure_checkpoint(state, request_id) do
    request_id = request_id || "recovery-#{System.unique_integer([:positive])}"

    case BackendAdapter.checkpoint(state.backend_state, request_id) do
      :ok ->
        timer =
          Process.send_after(self(), {:checkpoint_timeout, request_id}, @checkpoint_timeout_ms)

        stream = %{state.stream | bytes_since_checkpoint: 0}
        {:ok, %{state | stream: stream, pending_checkpoint: request_id, checkpoint_timer: timer}}

      {:error, reason} ->
        {:error, Error.new(:snapshot_unavailable, %{reason: reason})}
    end
  catch
    :exit, _reason -> {:error, Error.new(:snapshot_unavailable, %{reason: :backend_unavailable})}
  end

  defp clear_checkpoint(state) do
    if state.checkpoint_timer, do: Process.cancel_timer(state.checkpoint_timer)
    %{state | pending_checkpoint: nil, checkpoint_timer: nil}
  end

  defp degradation_details(_state, %Error{details: details}) do
    {details[:expected], details[:actual], details[:reason]}
  end

  defp degradation_details(state, reason) do
    {state.stream.native_sequence + 1, nil, reason}
  end
end
