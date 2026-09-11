defmodule Sigma.Agent.Terminals.Manager do
  @moduledoc "Serialized retained catalog and terminal-run lifecycle coordinator."

  use GenServer

  alias Sigma.Agent.Terminals.{
    Catalog,
    Error,
    Identity,
    Limits,
    Operation,
    ResourceLedger,
    Worker
  }

  @max_label_bytes 80

  defmodule Drain do
    @moduledoc false
    @enforce_keys [:id, :session, :mode]
    defstruct [:id, :session, :mode]
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  def issue_operation(server, id, kind, payload \\ nil),
    do: GenServer.call(server, {:issue_operation, id, kind, payload})

  def list(server, cursor \\ nil), do: GenServer.call(server, {:list, cursor})
  def subscribe(server, observer \\ self()), do: GenServer.call(server, {:subscribe, observer})
  def resource_summary(server), do: GenServer.call(server, :resource_summary)
  def can_stop(server), do: GenServer.call(server, :can_stop)

  def begin_drain(server, mode, opts \\ []) when mode in [:delete, :identity_change, :stop],
    do: GenServer.call(server, {:begin_drain, mode, opts})

  def cleanup_all(server, %Drain{} = drain),
    do: GenServer.call(server, {:cleanup_all, drain})

  def release_drain(server, %Drain{} = drain),
    do: GenServer.call(server, {:release_drain, drain})

  def validate_incarnation(server, incarnation_id),
    do: GenServer.call(server, {:validate_incarnation, incarnation_id})

  def await_cleanup(server, terminal_id, generation, timeout \\ 5_000),
    do: GenServer.call(server, {:await_cleanup, terminal_id, generation}, timeout)

  def ensure_initial(server, %Operation{} = operation, attrs \\ %{}),
    do: GenServer.call(server, {:ensure_initial, operation, attrs})

  def create(server, %Operation{} = operation, attrs \\ %{}),
    do: GenServer.call(server, {:create, operation, attrs})

  def rename(server, terminal_id, label, expected_revision, %Operation{} = operation),
    do: GenServer.call(server, {:rename, terminal_id, label, expected_revision, operation})

  def close(server, terminal_id, expected_generation, %Operation{} = operation),
    do: GenServer.call(server, {:close, terminal_id, expected_generation, operation})

  def retry_cleanup(server, terminal_id, expected_generation, %Operation{} = operation),
    do: GenServer.call(server, {:retry_cleanup, terminal_id, expected_generation, operation})

  def restart(server, terminal_id, expected_generation, %Operation{} = operation, attrs \\ %{}),
    do: GenServer.call(server, {:restart, terminal_id, expected_generation, operation, attrs})

  def complete_start(server, terminal_id, resource \\ %{}),
    do: GenServer.call(server, {:complete_start, terminal_id, resource})

  def shell_exited(server, terminal_id, status),
    do: GenServer.call(server, {:shell_exited, terminal_id, status})

  def worker_pid(server, terminal_id), do: GenServer.call(server, {:worker_pid, terminal_id})

  def attach(server, terminal_id, generation, observer, rendered_sequence \\ 0, opts \\ []),
    do:
      GenServer.call(
        server,
        {:attach, terminal_id, generation, observer, rendered_sequence, opts}
      )

  def detach(server, terminal_id, generation, attachment_id),
    do: GenServer.call(server, {:detach, terminal_id, generation, attachment_id})

  def acquire_control(server, terminal_id, generation, attachment_id),
    do: GenServer.call(server, {:acquire_control, terminal_id, generation, attachment_id})

  def takeover_control(server, terminal_id, generation, attachment_id, expected_epoch),
    do:
      GenServer.call(
        server,
        {:takeover_control, terminal_id, generation, attachment_id, expected_epoch}
      )

  def renew_control(server, terminal_id, generation, attachment_id, epoch),
    do: GenServer.call(server, {:renew_control, terminal_id, generation, attachment_id, epoch})

  def release_control(server, terminal_id, generation, attachment_id, epoch),
    do: GenServer.call(server, {:release_control, terminal_id, generation, attachment_id, epoch})

  def input(server, terminal_id, generation, request, bytes),
    do: GenServer.call(server, {:terminal_input, terminal_id, generation, request, bytes})

  def resize(server, terminal_id, generation, request, columns, rows),
    do:
      GenServer.call(
        server,
        {:terminal_resize, terminal_id, generation, request, columns, rows}
      )

  def output(server, run, bytes), do: GenServer.call(server, {:terminal_output, run, bytes})

  def checkpoint(server, run, snapshot),
    do: GenServer.call(server, {:terminal_checkpoint, run, snapshot})

  def acknowledge(server, terminal_id, generation, attachment_id, sequence),
    do:
      GenServer.call(
        server,
        {:terminal_acknowledge, terminal_id, generation, attachment_id, sequence}
      )

  def resync(server, terminal_id, generation, attachment_id, rendered_sequence),
    do:
      GenServer.call(
        server,
        {:terminal_resync, terminal_id, generation, attachment_id, rendered_sequence}
      )

  def attachment_status(server, terminal_id, generation, attachment_id),
    do:
      GenServer.call(
        server,
        {:attachment_status, terminal_id, generation, attachment_id}
      )

  def touch_attachment(server, terminal_id, generation, attachment_id),
    do:
      GenServer.call(
        server,
        {:touch_attachment, terminal_id, generation, attachment_id}
      )

  @impl true
  def init(opts) do
    session = Keyword.fetch!(opts, :session)
    limits = Keyword.get(opts, :limits, Limits.new())

    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)

    {:ok,
     %{
       session: session,
       catalog: Catalog.new(session, limits),
       limits: limits,
       ledger: Keyword.get(opts, :ledger, ResourceLedger),
       worker_supervisor: Keyword.fetch!(opts, :worker_supervisor),
       backend: Keyword.get(opts, :backend),
       backend_opts: Keyword.get(opts, :backend_opts, []),
       id_generator: Keyword.get(opts, :id_generator, &default_id/0),
       attachment_id_generator: Keyword.get(opts, :attachment_id_generator, &default_id/0),
       clock: clock,
       clock_origin: clock.(),
       workers: %{},
       cleanups: %{},
       cleanup_waiters: %{},
       operation_results: %{},
       subscribers: %{},
       drain: nil
     }}
  end

  @impl true
  def handle_call({:issue_operation, id, kind, payload}, _from, state) do
    {:reply, Operation.issue(id, kind, now_ms(state), payload), state}
  end

  def handle_call({:list, cursor}, _from, state) do
    {:reply, Catalog.snapshot(state.catalog, cursor), state}
  end

  def handle_call({:subscribe, observer}, _from, state) when is_pid(observer) do
    if Process.alive?(observer) do
      ref = Process.monitor(observer)
      {:reply, {:ok, state.catalog.session}, put_in(state.subscribers[ref], observer)}
    else
      {:reply, {:error, Error.new(:session_unavailable, %{reason: :observer_down})}, state}
    end
  end

  def handle_call({:validate_incarnation, incarnation_id}, _from, state) do
    expected = state.session.incarnation_id

    reply =
      if incarnation_id == expected,
        do: :ok,
        else:
          {:error,
           Error.new(:stale_session_incarnation, %{expected: expected, actual: incarnation_id})}

    {:reply, reply, state}
  end

  def handle_call(:can_stop, _from, %{drain: %Drain{mode: mode}} = state) do
    {:reply, {:error, Error.new(:session_draining, %{reason: mode}, retryable: true)}, state}
  end

  def handle_call(:can_stop, _from, state) do
    case stop_admission(state) do
      :ok ->
        {:reply,
         {:ok,
          %{
            session: state.session,
            retained_history?: Catalog.retained_count(state.catalog) > 0
          }}, state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:begin_drain, _mode, _opts}, _from, %{drain: %Drain{mode: mode}} = state) do
    {:reply, {:error, Error.new(:session_draining, %{reason: mode}, retryable: true)}, state}
  end

  def handle_call({:begin_drain, mode, opts}, _from, state) do
    with :ok <- drain_admission(state, mode, opts) do
      drain = %Drain{id: make_ref(), session: state.session, mode: mode}
      {:reply, {:ok, drain}, %{state | drain: drain}}
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:cleanup_all, %Drain{} = drain}, _from, state) do
    if state.drain == drain do
      {runs, state} = begin_drain_cleanups(state)
      {:reply, {:ok, runs}, state}
    else
      {:reply, {:error, Error.new(:session_draining, %{reason: :invalid_drain_token})}, state}
    end
  end

  def handle_call({:release_drain, %Drain{} = drain}, _from, state) do
    if state.drain == drain do
      {:reply, :ok, %{state | drain: nil}}
    else
      {:reply, {:error, Error.new(:session_draining, %{reason: :invalid_drain_token})}, state}
    end
  end

  def handle_call(:resource_summary, _from, state) do
    reply =
      try do
        ledger = ResourceLedger.summary(state.ledger, state.session)

        Map.merge(ledger, %{
          available?: true,
          retained_count: Catalog.retained_count(state.catalog),
          state_counts: Catalog.state_counts(state.catalog),
          resource_pin?: Catalog.resource_pin?(state.catalog) or ledger.resource_pin?
        })
      catch
        :exit, _reason ->
          {:error,
           Error.new(:session_unavailable, %{reason: :ledger_unavailable}, retryable: true),
           unknown_resource_summary()}
      end

    {:reply, reply, state}
  end

  def handle_call({kind, operation, attrs}, _from, state)
      when kind in [:ensure_initial, :create] do
    execute_operation(state, operation, kind, fn state ->
      create_or_ensure(state, kind, operation, attrs)
    end)
  end

  def handle_call({:rename, terminal_id, label, expected_revision, operation}, _from, state) do
    execute_operation(state, operation, :rename, fn state ->
      with :ok <- expected_revision(state, expected_revision),
           :ok <- valid_label(label),
           {:ok, terminal} <- fetch_terminal(state, terminal_id) do
        terminal = %{terminal | label: String.trim(label)}
        state = replace_terminal(state, terminal)
        {{:ok, terminal}, state}
      else
        {:error, error} -> {{:error, error}, state}
      end
    end)
  end

  def handle_call({:close, terminal_id, generation, operation}, _from, state) do
    execute_operation(state, operation, :close, fn state ->
      close_terminal(state, terminal_id, generation, false, operation.id)
    end)
  end

  def handle_call({:retry_cleanup, terminal_id, generation, operation}, _from, state) do
    execute_operation(state, operation, :retry_cleanup, fn state ->
      close_terminal(state, terminal_id, generation, true, operation.id)
    end)
  end

  def handle_call({:restart, terminal_id, generation, operation, attrs}, _from, state) do
    execute_operation(state, operation, :restart, fn state ->
      with {:ok, terminal} <- fetch_run(state, terminal_id, generation),
           {:ok, restarted} <- Catalog.transition(terminal, :restart),
           old_run <- run(terminal),
           new_run <- run(restarted),
           :ok <-
             ResourceLedger.reserve_restart(
               state.ledger,
               old_run,
               new_run,
               operation.id,
               state.limits
             ) do
        state = replace_terminal(state, restarted)
        start_run(state, restarted, attrs)
      else
        {:error, error} -> {{:error, error}, state}
      end
    end)
  end

  def handle_call({:complete_start, terminal_id, resource}, _from, state) do
    with {:ok, terminal} <- fetch_terminal(state, terminal_id),
         %{pid: pid, attrs: attrs} <- state.workers[terminal_id],
         :ok <- safe_worker_call(fn -> Worker.complete_start(pid, resource) end),
         {:ok, running} <- Catalog.transition(terminal, :started),
         :ok <- ResourceLedger.mark_managed(state.ledger, run(running)) do
      state = replace_terminal(state, running)
      state = maybe_attach_creator(state, running, attrs, pid)
      state = put_in(state.workers[terminal_id].attrs, nil)
      {:reply, {:ok, running}, state}
    else
      nil ->
        {:reply, {:error, Error.new(:terminal_not_found)}, state}

      {:error, error} when is_struct(error, Error) ->
        {:reply, {:error, error}, state}

      {:error, reason} ->
        {:reply, {:error, Error.new(:startup_failed, %{reason: reason})}, state}

      {:worker_exit, reason} ->
        state = drop_worker(state, terminal_id)
        {:ok, terminal} = fetch_terminal(state, terminal_id)
        state = retain_worker_loss(state, terminal, reason)

        {:reply, {:error, Error.new(:cleanup_unconfirmed, %{}, retryable: true)}, state}
    end
  end

  def handle_call({:shell_exited, terminal_id, status}, _from, state) do
    with {:ok, terminal} <- fetch_terminal(state, terminal_id),
         {:ok, stopping} <- Catalog.transition(terminal, {:shell_exited, status}) do
      state = replace_terminal(state, stopping)
      {{:ok, :stopping}, state} = begin_cleanup(state, stopping, false, nil)
      {:reply, {:ok, :stopping}, state}
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:worker_pid, terminal_id}, _from, state) do
    {:reply, get_in(state.workers, [terminal_id, :pid]), state}
  end

  def handle_call(
        {:attach, terminal_id, generation, observer, rendered_sequence, opts},
        _from,
        state
      ) do
    with {:ok, worker} <- fetch_worker(state, terminal_id, generation) do
      attachment_id = state.attachment_id_generator.()

      {:reply,
       Worker.attach(
         worker,
         observer,
         attachment_id,
         state.catalog.revision,
         rendered_sequence,
         opts
       ), state}
    else
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:detach, terminal_id, generation, attachment_id}, _from, state) do
    worker_reply(state, terminal_id, generation, &Worker.detach(&1, attachment_id))
  end

  def handle_call({:acquire_control, terminal_id, generation, attachment_id}, _from, state) do
    worker_reply(state, terminal_id, generation, &Worker.acquire_control(&1, attachment_id))
  end

  def handle_call(
        {:takeover_control, terminal_id, generation, attachment_id, expected_epoch},
        _from,
        state
      ) do
    worker_reply(state, terminal_id, generation, fn worker ->
      Worker.takeover_control(worker, attachment_id, expected_epoch)
    end)
  end

  def handle_call({:renew_control, terminal_id, generation, attachment_id, epoch}, _from, state) do
    worker_reply(state, terminal_id, generation, fn worker ->
      Worker.renew_control(worker, attachment_id, epoch)
    end)
  end

  def handle_call({:release_control, terminal_id, generation, attachment_id, epoch}, _from, state) do
    worker_reply(state, terminal_id, generation, fn worker ->
      Worker.release_control(worker, attachment_id, epoch)
    end)
  end

  def handle_call({:terminal_input, terminal_id, generation, request, bytes}, _from, state) do
    worker_reply(state, terminal_id, generation, fn worker ->
      Worker.input(worker, request, state.catalog.revision, bytes)
    end)
  end

  def handle_call(
        {:terminal_resize, terminal_id, generation, request, columns, rows},
        _from,
        state
      ) do
    worker_reply(state, terminal_id, generation, fn worker ->
      Worker.resize(worker, request, state.catalog.revision, columns, rows)
    end)
  end

  def handle_call({:terminal_output, run, bytes}, _from, state) do
    worker_reply(state, run.terminal.terminal_id, run.generation, &Worker.output(&1, run, bytes))
  end

  def handle_call({:terminal_checkpoint, run, snapshot}, _from, state) do
    worker_reply(
      state,
      run.terminal.terminal_id,
      run.generation,
      &Worker.checkpoint(&1, run, snapshot)
    )
  end

  def handle_call(
        {:terminal_acknowledge, terminal_id, generation, attachment_id, sequence},
        _from,
        state
      ) do
    worker_reply(state, terminal_id, generation, fn worker ->
      Worker.acknowledge(worker, attachment_id, sequence)
    end)
  end

  def handle_call(
        {:terminal_resync, terminal_id, generation, attachment_id, rendered_sequence},
        _from,
        state
      ) do
    worker_reply(state, terminal_id, generation, fn worker ->
      Worker.resync(worker, attachment_id, rendered_sequence)
    end)
  end

  def handle_call(
        {:attachment_status, terminal_id, generation, attachment_id},
        _from,
        state
      ) do
    worker_reply(state, terminal_id, generation, fn worker ->
      Worker.attachment_status(worker, attachment_id)
    end)
  end

  def handle_call({:touch_attachment, terminal_id, generation, attachment_id}, _from, state) do
    worker_reply(state, terminal_id, generation, &Worker.touch_attachment(&1, attachment_id))
  end

  def handle_call({:await_cleanup, terminal_id, generation}, from, state) do
    case fetch_run(state, terminal_id, generation) do
      {:error, %Error{code: :terminal_not_found}} ->
        {:reply, {:ok, :closed}, state}

      {:error, error} ->
        {:reply, {:error, error}, state}

      {:ok, %{state: state_name} = terminal} when state_name in [:exited, :failed] ->
        {:reply, {:ok, terminal}, state}

      {:ok, %{state: :cleanup_failed} = terminal} ->
        {:reply, cleanup_error(terminal), state}

      {:ok, %{state: :stopping}} ->
        key = {terminal_id, generation}
        waiters = Map.get(state.cleanup_waiters, key, [])
        {:noreply, put_in(state.cleanup_waiters[key], [from | waiters])}

      {:ok, terminal} ->
        {:reply, {:error, Error.new(:invalid_transition, %{state: terminal.state})}, state}
    end
  end

  @impl true
  def handle_info({:terminal_worker_started, pid, run, _resource}, state) do
    terminal_id = run.terminal.terminal_id

    with %{pid: ^pid, attrs: attrs} <- state.workers[terminal_id],
         {:ok, terminal} <- fetch_run(state, terminal_id, run.generation),
         {:ok, running} <- Catalog.transition(terminal, :started),
         :ok <- ResourceLedger.mark_managed(state.ledger, run) do
      state = replace_terminal(state, running)
      state = maybe_attach_creator(state, running, attrs, pid)
      {:noreply, put_in(state.workers[terminal_id].attrs, nil)}
    else
      _stale_or_invalid -> {:noreply, state}
    end
  end

  def handle_info({:terminal_worker_shell_exited, pid, run, status}, state) do
    terminal_id = run.terminal.terminal_id

    with %{pid: ^pid} <- state.workers[terminal_id],
         {:ok, terminal} <- fetch_run(state, terminal_id, run.generation),
         {:ok, stopping} <- Catalog.transition(terminal, {:shell_exited, status}) do
      state = replace_terminal(state, stopping)
      {_reply, state} = begin_cleanup(state, stopping, false, nil)
      {:noreply, state}
    else
      _stale_or_invalid -> {:noreply, state}
    end
  end

  def handle_info({:terminal_worker_backend_failed, pid, run, reason}, state) do
    terminal_id = run.terminal.terminal_id

    case {state.workers[terminal_id], fetch_run(state, terminal_id, run.generation)} do
      {%{pid: ^pid}, {:ok, %{state: :starting} = terminal}} ->
        {:ok, stopping} = Catalog.transition(terminal, {:startup_failed, reason})
        state = replace_terminal(state, stopping)
        {_reply, state} = begin_cleanup(state, stopping, false, nil)
        {:noreply, state}

      {%{pid: ^pid}, {:ok, %{state: :running} = terminal}} ->
        {:ok, stopping} = Catalog.transition(terminal, {:shell_exited, nil})
        state = replace_terminal(state, %{stopping | failure_reason: reason})
        {_reply, state} = begin_cleanup(state, stopping, false, nil)
        {:noreply, state}

      _stale_or_invalid ->
        {:noreply, state}
    end
  end

  def handle_info({:terminal_cleanup_result, pid, run, token, result}, state) do
    terminal_id = run.terminal.terminal_id

    case state.cleanups[terminal_id] do
      %{
        pid: ^pid,
        run: ^run,
        token: ^token,
        remove_after?: remove_after?,
        operation_id: operation_id,
        started_at_ms: started_at_ms
      } ->
        emit_cleanup(state, run, result, started_at_ms)
        state = %{state | cleanups: Map.delete(state.cleanups, terminal_id)}
        {:ok, terminal} = fetch_run(state, terminal_id, run.generation)
        {reply, state} = finish_cleanup_result(state, terminal, remove_after?, result)
        state = update_operation_reply(state, operation_id, reply)
        {:noreply, reply_cleanup_waiters(state, terminal_id, run.generation, reply)}

      _stale_or_unknown ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.subscribers, ref) do
      {_observer, subscribers} when map_size(subscribers) < map_size(state.subscribers) ->
        {:noreply, %{state | subscribers: subscribers}}

      {nil, _subscribers} ->
        handle_worker_down(ref, reason, state)
    end
  end

  defp handle_worker_down(ref, reason, state) do
    case Enum.find(state.workers, fn {_id, worker} -> worker.ref == ref end) do
      nil ->
        {:noreply, state}

      {terminal_id, _worker} ->
        cleanup = state.cleanups[terminal_id]

        state = %{
          state
          | workers: Map.delete(state.workers, terminal_id),
            cleanups: Map.delete(state.cleanups, terminal_id)
        }

        state =
          case fetch_terminal(state, terminal_id) do
            {:ok, terminal} -> retain_worker_loss(state, terminal, reason)
            {:error, _error} -> state
          end

        state =
          case cleanup do
            %{run: run, operation_id: operation_id} ->
              reply = {:error, Error.new(:cleanup_unconfirmed, %{}, retryable: true)}

              state
              |> update_operation_reply(operation_id, reply)
              |> reply_cleanup_waiters(terminal_id, run.generation, reply)

            nil ->
              state
          end

        {:noreply, state}
    end
  end

  defp create_or_ensure(state, kind, operation, attrs) do
    if state.drain do
      {{:error, Error.new(:session_draining, %{reason: state.drain.mode}, retryable: true)},
       state}
    else
      do_create_or_ensure(state, kind, operation, attrs)
    end
  end

  defp do_create_or_ensure(state, kind, operation, attrs) do
    terminal_id = state.id_generator.()
    now_ms = now_ms(state)

    result =
      case kind do
        :ensure_initial -> Catalog.ensure_initial(state.catalog, operation, terminal_id, now_ms)
        :create -> Catalog.create(state.catalog, operation, terminal_id, now_ms)
      end

    case result do
      {:ok, terminal, catalog, :applied} ->
        run = run(terminal)

        case ResourceLedger.reserve_new(state.ledger, run, operation.id, state.limits) do
          :ok -> start_run(%{state | catalog: catalog}, terminal, attrs)
          {:error, error} -> {{:error, error}, state}
        end

      {:ok, terminal, _catalog, disposition} when disposition in [:converged, :replayed] ->
        {{:ok, terminal}, state}

      {:error, error} ->
        {{:error, error}, state}
    end
  end

  defp drain_admission(state, :delete, _opts), do: ledger_trustworthy(state)

  defp drain_admission(state, :stop, _opts) do
    with :ok <- ledger_trustworthy(state), do: stop_admission(state)
  end

  defp drain_admission(state, :identity_change, opts) do
    terminals = state.catalog.terminals

    cond do
      Enum.any?(terminals, &(&1.resource_state != :released)) ->
        {:error,
         Error.new(:session_draining, %{
           reason: :terminal_resources_require_close,
           terminal_ids: terminal_ids(terminals, &(&1.resource_state != :released))
         })}

      terminals != [] and not Keyword.get(opts, :discard_terminal_history, false) ->
        {:error,
         Error.new(:session_draining, %{
           reason: :terminal_history_acknowledgement_required,
           terminal_ids: terminal_ids(terminals, fn _terminal -> true end)
         })}

      true ->
        ledger_trustworthy(state)
    end
  end

  defp stop_admission(state) do
    with :ok <- ledger_trustworthy(state) do
      pinned = Enum.filter(state.catalog.terminals, &(&1.resource_state != :released))

      if pinned == [] do
        :ok
      else
        {:error,
         Error.new(:session_draining, %{
           reason: :terminal_resources_present,
           terminal_ids: Enum.map(pinned, & &1.identity.terminal_id),
           states: Enum.map(pinned, & &1.state)
         })}
      end
    end
  end

  defp ledger_trustworthy(state) do
    case ResourceLedger.summary(state.ledger, state.session) do
      %{trustworthy?: true} ->
        :ok

      %{trustworthy?: false} ->
        {:error, Error.new(:cleanup_unconfirmed, %{reason: :ledger_untrusted}, retryable: true)}
    end
  catch
    :exit, _reason ->
      {:error, Error.new(:session_unavailable, %{reason: :ledger_unavailable}, retryable: true)}
  end

  defp terminal_ids(terminals, predicate) do
    terminals
    |> Enum.filter(predicate)
    |> Enum.map(& &1.identity.terminal_id)
  end

  defp begin_drain_cleanups(state) do
    Enum.reduce(state.catalog.terminals, {[], state}, fn terminal, {runs, state} ->
      run = run(terminal)

      state =
        case state.cleanups[terminal.identity.terminal_id] do
          %{run: ^run} = cleanup ->
            put_in(state.cleanups[terminal.identity.terminal_id], %{
              cleanup
              | remove_after?: true
            })

          _ ->
            {:ok, stopping} = drain_close_transition(terminal)
            state = replace_terminal(state, stopping)
            {{:ok, :stopping}, state} = begin_cleanup(state, stopping, true, nil)
            state
        end

      {[run | runs], state}
    end)
    |> then(fn {runs, state} -> {Enum.reverse(runs), state} end)
  end

  defp drain_close_transition(%Catalog.Terminal{state: state} = terminal)
       when state in [:exited, :failed],
       do: {:ok, %{terminal | cleanup_disposition: :close}}

  defp drain_close_transition(%Catalog.Terminal{state: :cleanup_failed} = terminal),
    do: Catalog.transition(terminal, :retry_cleanup)

  defp drain_close_transition(%Catalog.Terminal{state: :stopping} = terminal), do: {:ok, terminal}
  defp drain_close_transition(terminal), do: Catalog.transition(terminal, :close_requested)

  defp start_run(%{backend: nil} = state, terminal, _attrs) do
    failed_start(state, terminal, :backend_missing, :backend_missing)
  end

  defp start_run(state, terminal, attrs) do
    child =
      {Worker,
       run: run(terminal),
       backend: state.backend,
       backend_opts: state.backend_opts,
       attrs: attrs,
       limits: state.limits}

    case DynamicSupervisor.start_child(state.worker_supervisor, child) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        state =
          put_in(state.workers[terminal.identity.terminal_id], %{pid: pid, ref: ref, attrs: attrs})

        :ok = ResourceLedger.observe_owner(state.ledger, run(terminal), pid)

        case safe_worker_call(fn -> Worker.start(pid) end) do
          :ok ->
            {:ok, running} = Catalog.transition(terminal, :started)
            :ok = ResourceLedger.mark_managed(state.ledger, run(running))
            state = replace_terminal(state, running)
            state = maybe_attach_creator(state, running, attrs, pid)
            state = put_in(state.workers[terminal.identity.terminal_id].attrs, nil)
            {{:ok, running}, state}

          {:pending, _ref} ->
            {{:ok, terminal}, notify_catalog(state)}

          {:error, reason} ->
            failed_start(state, terminal, reason)

          {:worker_exit, reason} ->
            uncertain_start(state, terminal, reason)
        end

      {:error, reason} ->
        failed_start(state, terminal, reason)
    end
  end

  defp failed_start(state, terminal, reason, error_code \\ :startup_failed) do
    {:ok, stopping} = Catalog.transition(terminal, {:startup_failed, reason})
    {:ok, failed} = Catalog.transition(stopping, :cleanup_confirmed)
    :ok = ResourceLedger.mark_released(state.ledger, run(terminal))
    state = state |> drop_worker(terminal.identity.terminal_id) |> replace_terminal(failed)
    {{:error, Error.new(error_code, %{reason: reason})}, state}
  end

  defp uncertain_start(state, terminal, reason) do
    {:ok, stopping} = Catalog.transition(terminal, {:startup_failed, {:worker_exit, reason}})
    {:ok, failed} = Catalog.transition(stopping, {:cleanup_failed, :cleanup_unconfirmed})
    :ok = ResourceLedger.mark_unconfirmed(state.ledger, run(terminal))
    state = state |> drop_worker(terminal.identity.terminal_id) |> replace_terminal(failed)
    {{:error, Error.new(:cleanup_unconfirmed, %{}, retryable: true)}, state}
  end

  defp close_terminal(state, terminal_id, generation, retry?, operation_id) do
    with {:ok, terminal} <- fetch_run(state, terminal_id, generation),
         {:ok, stopping} <- close_transition(terminal, retry?) do
      remove_after? = not retry? or terminal.cleanup_disposition == :close
      state = replace_terminal(state, stopping)
      begin_cleanup(state, stopping, remove_after?, operation_id)
    else
      {:error, error} -> {{:error, error}, state}
    end
  end

  defp close_transition(%Catalog.Terminal{state: state} = terminal, false)
       when state in [:exited, :failed] do
    {:ok, %{terminal | cleanup_disposition: :close}}
  end

  defp close_transition(terminal, false), do: Catalog.transition(terminal, :close_requested)
  defp close_transition(terminal, true), do: Catalog.transition(terminal, :retry_cleanup)

  defp begin_cleanup(state, terminal, remove_after?, operation_id) do
    terminal_id = terminal.identity.terminal_id
    token = make_ref()
    run = run(terminal)

    cleanup =
      case state.workers[terminal_id] do
        %{pid: pid} ->
          Worker.begin_cleanup(pid, self(), token)

          %{
            pid: pid,
            run: run,
            token: token,
            remove_after?: remove_after?,
            operation_id: operation_id,
            started_at_ms: System.monotonic_time(:millisecond)
          }

        nil ->
          result =
            if terminal.resource_state == :released,
              do: {:ok, :confirmed},
              else: {:error, :cleanup_unconfirmed}

          send(self(), {:terminal_cleanup_result, nil, run, token, result})

          %{
            pid: nil,
            run: run,
            token: token,
            remove_after?: remove_after?,
            operation_id: operation_id,
            started_at_ms: System.monotonic_time(:millisecond)
          }
      end

    {{:ok, :stopping}, put_in(state.cleanups[terminal_id], cleanup)}
  end

  defp finish_cleanup_result(state, terminal, remove_after?, cleanup_result) do
    terminal_id = terminal.identity.terminal_id

    case cleanup_result do
      {:ok, :confirmed} when remove_after? or terminal.cleanup_disposition == :close ->
        :ok = ResourceLedger.mark_released(state.ledger, run(terminal))
        :ok = ResourceLedger.remove(state.ledger, run(terminal))
        state = state |> drop_worker(terminal_id) |> remove_terminal(terminal_id)
        {{:ok, :closed}, state}

      {:ok, :confirmed} ->
        {:ok, retained} = Catalog.transition(terminal, :cleanup_confirmed)
        :ok = ResourceLedger.mark_released(state.ledger, run(terminal))
        state = state |> drop_worker(terminal_id) |> replace_terminal(retained)
        {{:ok, retained}, state}

      {:error, reason} ->
        {:ok, failed} = Catalog.transition(terminal, {:cleanup_failed, reason})
        :ok = ResourceLedger.mark_unconfirmed(state.ledger, run(terminal))
        state = replace_terminal(state, failed)
        {{:error, Error.new(reason, %{terminal_id: terminal_id}, retryable: true)}, state}
    end
  end

  defp retain_worker_loss(state, terminal, reason) do
    terminal =
      case terminal.state do
        :starting ->
          {:ok, stopping} =
            Catalog.transition(terminal, {:startup_failed, {:worker_down, reason}})

          stopping

        :running ->
          {:ok, stopping} = Catalog.transition(terminal, {:shell_exited, {:worker_down, reason}})
          stopping

        _ ->
          terminal
      end

    terminal =
      if terminal.state == :stopping do
        {:ok, failed} = Catalog.transition(terminal, {:cleanup_failed, :cleanup_unconfirmed})
        failed
      else
        terminal
      end

    :ok = ResourceLedger.mark_unconfirmed(state.ledger, run(terminal))
    replace_terminal(state, terminal)
  end

  defp execute_operation(state, operation, expected_kind, function) do
    now_ms = now_ms(state)
    state = prune_operations(state, now_ms)

    case operation_status(state, operation, expected_kind, now_ms) do
      {:replay, reply} ->
        {:reply, reply, state}

      {:error, error} ->
        {:reply, {:error, error}, state}

      :new ->
        {reply, state} = function.(state)
        state = remember_operation(state, operation, reply)
        {:reply, reply, state}
    end
  end

  defp operation_status(state, operation, expected_kind, now_ms) do
    expires_at = operation.issued_at_ms + state.limits.mutation_dedup_window_ms

    cond do
      operation.kind != expected_kind ->
        {:error,
         Error.new(:invalid_operation_ticket, %{
           expected_kind: expected_kind,
           actual_kind: operation.kind
         })}

      operation.issued_at_ms > now_ms ->
        {:error, Error.new(:invalid_operation_ticket)}

      now_ms >= expires_at ->
        {:error, Error.new(:operation_expired, %{operation_id: operation.id})}

      record = state.operation_results[operation.id] ->
        if record.fingerprint == operation.fingerprint and record.kind == operation.kind,
          do: {:replay, record.reply},
          else: {:error, Error.new(:operation_conflict, %{operation_id: operation.id})}

      map_size(state.operation_results) >= state.limits.max_operation_records ->
        {:error, Error.new(:operation_history_full, %{}, retryable: true)}

      true ->
        :new
    end
  end

  defp remember_operation(state, operation, reply) do
    record = %{
      kind: operation.kind,
      fingerprint: operation.fingerprint,
      reply: reply,
      expires_at_ms: operation.issued_at_ms + state.limits.mutation_dedup_window_ms
    }

    put_in(state.operation_results[operation.id], record)
  end

  defp prune_operations(state, now_ms) do
    results =
      Map.reject(state.operation_results, fn {_id, record} -> now_ms >= record.expires_at_ms end)

    %{state | operation_results: results}
  end

  defp expected_revision(%{catalog: %{revision: revision}}, revision), do: :ok

  defp expected_revision(%{catalog: %{revision: actual}}, expected),
    do: {:error, Error.new(:stale_catalog_revision, %{expected: expected, actual: actual})}

  defp valid_label(label) when is_binary(label) do
    trimmed = String.trim(label)

    if trimmed != "" and byte_size(trimmed) <= @max_label_bytes,
      do: :ok,
      else: {:error, Error.new(:invalid_label)}
  end

  defp valid_label(_label), do: {:error, Error.new(:invalid_label)}

  defp fetch_run(state, terminal_id, generation) do
    with {:ok, terminal} <- fetch_terminal(state, terminal_id),
         true <- terminal.run_generation == generation do
      {:ok, terminal}
    else
      false -> {:error, Error.new(:stale_run_generation)}
      {:error, error} -> {:error, error}
    end
  end

  defp fetch_terminal(state, terminal_id) do
    case Enum.find(state.catalog.terminals, &(&1.identity.terminal_id == terminal_id)) do
      nil -> {:error, Error.new(:terminal_not_found, %{terminal_id: terminal_id})}
      terminal -> {:ok, terminal}
    end
  end

  defp fetch_worker(state, terminal_id, generation) do
    with {:ok, _terminal} <- fetch_run(state, terminal_id, generation),
         %{pid: pid} <- state.workers[terminal_id] do
      {:ok, pid}
    else
      nil -> {:error, Error.new(:terminal_not_found, %{terminal_id: terminal_id})}
      {:error, error} -> {:error, error}
    end
  end

  defp worker_reply(state, terminal_id, generation, function) do
    reply =
      with {:ok, worker} <- fetch_worker(state, terminal_id, generation),
           do: function.(worker)

    {:reply, reply, state}
  end

  defp maybe_attach_creator(state, terminal, attrs, worker) do
    case attrs do
      %{creator: %{observer: observer}} when is_pid(observer) ->
        attachment_id = state.attachment_id_generator.()

        result =
          Worker.attach(
            worker,
            observer,
            attachment_id,
            state.catalog.revision,
            0,
            initial_control: true
          )

        send(observer, {:terminal_creator_attachment, run(terminal), result})
        state

      _ ->
        state
    end
  end

  defp replace_terminal(state, terminal) do
    terminals =
      Enum.map(state.catalog.terminals, fn current ->
        if current.identity == terminal.identity, do: terminal, else: current
      end)

    state = %{
      state
      | catalog: %{state.catalog | terminals: terminals, revision: state.catalog.revision + 1}
    }

    notify_catalog(state)
  end

  defp remove_terminal(state, terminal_id) do
    terminals = Enum.reject(state.catalog.terminals, &(&1.identity.terminal_id == terminal_id))

    state = %{
      state
      | catalog: %{state.catalog | terminals: terminals, revision: state.catalog.revision + 1}
    }

    notify_catalog(state)
  end

  defp notify_catalog(state) do
    message = {:terminal_catalog_changed, state.session, state.catalog.revision}
    Enum.each(state.subscribers, fn {_ref, observer} -> send(observer, message) end)

    states = Catalog.state_counts(state.catalog)

    :telemetry.execute(
      [:sigma, :terminal, :catalog],
      %{
        retained_count: Catalog.retained_count(state.catalog),
        live_count: Map.get(states, :running, 0),
        reserved_count: Map.get(states, :starting, 0)
      },
      %{
        repository_id: state.session.repository_id,
        session_id: state.session.session_id,
        incarnation_id: state.session.incarnation_id,
        revision: state.catalog.revision
      }
    )

    state
  end

  defp emit_cleanup(state, run, result, started_at_ms) do
    :telemetry.execute(
      [:sigma, :terminal, :cleanup],
      %{duration_ms: max(System.monotonic_time(:millisecond) - started_at_ms, 0), count: 1},
      %{
        repository_id: state.session.repository_id,
        session_id: state.session.session_id,
        incarnation_id: state.session.incarnation_id,
        terminal_id: run.terminal.terminal_id,
        generation: run.generation,
        outcome: if(match?({:ok, :confirmed}, result), do: :ok, else: :error)
      }
    )
  end

  defp drop_worker(state, terminal_id) do
    case Map.pop(state.workers, terminal_id) do
      {nil, _workers} ->
        state

      {%{pid: pid, ref: ref}, workers} ->
        Process.demonitor(ref, [:flush])

        if Process.alive?(pid),
          do: DynamicSupervisor.terminate_child(state.worker_supervisor, pid)

        %{state | workers: workers}
    end
  end

  defp reply_cleanup_waiters(state, terminal_id, generation, reply) do
    key = {terminal_id, generation}
    {waiters, cleanup_waiters} = Map.pop(state.cleanup_waiters, key, [])
    Enum.each(waiters, &GenServer.reply(&1, reply))
    %{state | cleanup_waiters: cleanup_waiters}
  end

  defp cleanup_error(terminal) do
    code = terminal.cleanup_error || :cleanup_unconfirmed
    {:error, Error.new(code, %{terminal_id: terminal.identity.terminal_id}, retryable: true)}
  end

  defp update_operation_reply(state, nil, _reply), do: state

  defp update_operation_reply(state, operation_id, reply) do
    case state.operation_results[operation_id] do
      nil -> state
      record -> put_in(state.operation_results[operation_id], %{record | reply: reply})
    end
  end

  defp unknown_resource_summary do
    %{
      available?: false,
      trustworthy?: false,
      retained_count: :unknown,
      managed_run_count: :unknown,
      resource_pin?: :unknown,
      entries: :unknown
    }
  end

  defp safe_worker_call(function) do
    function.()
  catch
    :exit, reason -> {:worker_exit, reason}
  end

  defp run(terminal), do: Identity.run(terminal.identity, terminal.run_generation)
  defp now_ms(state), do: max(state.clock.() - state.clock_origin, 0)
  defp default_id, do: Integer.to_string(System.unique_integer([:positive, :monotonic]), 36)
end
