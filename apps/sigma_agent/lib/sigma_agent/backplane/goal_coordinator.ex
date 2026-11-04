defmodule Sigma.Agent.Backplane.GoalCoordinator do
  @moduledoc """
  Per-thread owner of the public Backplane Goal process.

  The immutable journal header selects identity. Binding acknowledgement follows
  the durable pre-admission index; a reopened index requires recovery before
  further admission or Goal mutation. Goal idle reserves ordinary admission
  first and releases it only after the public Goal call returns. Callbacks must
  not synchronously reenter this coordinator.
  """

  use GenServer

  alias Backplane.AgentRuntime.{Error, Goal, GoalBridge, Kernel}
  alias Backplane.AgentRuntime.Store, as: RuntimeStore
  alias Sigma.Coding.Hooks.Execution, as: HookExecution

  alias Sigma.Agent.Backplane.{
    GoalDescendants,
    GoalHost,
    GoalRuns,
    LifetimeEvidence,
    GoalStore,
    RunRecovery,
    Store
  }

  def start_link(opts) do
    with {:ok, writer} <- resolve_writer(opts[:writer]),
         :ok <- validate_runtime_store(opts),
         {:ok, store} <- open_goal_store(opts),
         {:ok, thread_id} <- journal_identity(writer, opts[:cwd]) do
      root = Path.expand(opts[:root])

      name =
        {:via, Registry, {Sigma.Agent.RepositoryRegistry, {:goal_coordinator, root, thread_id}}}

      GenServer.start_link(
        __MODULE__,
        {Keyword.put(opts, :writer, writer), root, thread_id, store},
        name: name
      )
    end
  end

  def identity(coordinator), do: GenServer.call(coordinator, :identity, :infinity)
  def runtime_context(coordinator), do: GenServer.call(coordinator, :runtime_context, :infinity)
  def get(coordinator), do: GenServer.call(coordinator, :get, :infinity)
  def bind(coordinator, attrs), do: GenServer.call(coordinator, {:bind, attrs}, :infinity)

  def unbind(coordinator, binding),
    do: GenServer.call(coordinator, {:unbind, binding}, :infinity)

  def clear(coordinator, instruction),
    do: GenServer.call(coordinator, {:clear, instruction}, :infinity)

  def fork(coordinator, target_writer, cwd, target_transcript),
    do: GenServer.call(coordinator, {:fork, target_writer, cwd, target_transcript}, :infinity)

  def recover(coordinator), do: GenServer.call(coordinator, :recover, :infinity)

  @doc "Retries only a sealed no-start settlement before fresh work or host Goal mutation."
  def prepare_admission(coordinator),
    do: GenServer.call(coordinator, :prepare_admission, :infinity)

  @doc "Rescans indexed work after the live host has confirmed its retirement."
  def recover_retired(coordinator), do: GenServer.call(coordinator, :recover_retired, :infinity)

  @doc "Withdraws an admission only after the caller has atomically prevented its host release."
  def withdraw_admission(coordinator, admission, reason),
    do: GenServer.call(coordinator, {:withdraw_admission, admission, reason}, :infinity)

  @doc "Opens the exact monitored executor's first effect boundary. No-start settlement ends here."
  def start_executor(coordinator, admission),
    do: GenServer.call(coordinator, {:start_executor, admission}, :infinity)

  def fail_executor(coordinator, admission, reason),
    do: GenServer.call(coordinator, {:fail_executor, admission, reason}, :infinity)

  @doc "Seals actual host hook results before joining the released executor's DOWN."
  def stop_host_executor(coordinator, admission, terminal),
    do: GenServer.call(coordinator, {:stop_host_executor, admission, terminal}, :infinity)

  def open_host_hooks(coordinator, admission, runtime),
    do: GenServer.call(coordinator, {:open_host_hooks, admission, runtime}, :infinity)

  def start_runtime(coordinator, admission),
    do: GenServer.call(coordinator, {:start_runtime, admission}, :infinity)

  def set(coordinator, mutation, instruction),
    do: GenServer.call(coordinator, {:set, mutation, instruction}, :infinity)

  def idle(coordinator, generation),
    do: GenServer.call(coordinator, {:idle, generation}, :infinity)

  @impl true
  def init({opts, root, thread_id, goal_store}) do
    Process.flag(:trap_exit, true)

    with {:ok, runs} <- GoalRuns.list(root, thread_id),
         {:ok, host_admissions} <- GoalStore.host_admissions(goal_store, thread_id),
         {:ok, goal_record} <- GoalStore.load(goal_store, thread_id),
         {:ok, runtime_store, owns_runtime_store?} <- open_runtime_store(opts) do
      host_context = Keyword.get(opts, :host_context, %{})
      host_error = host_admission_recovery(host_admissions, goal_record, runs)

      case Goal.start_link(
             thread_id: thread_id,
             owner_pid: self(),
             store: GoalStore,
             store_context: goal_store,
             host: GoalHost,
             host_context: host_context
           ) do
        {:ok, goal} ->
          {:ok,
           %{
             root: root,
             thread_id: thread_id,
             goal: goal,
             goal_store: goal_store,
             runtime_store: runtime_store,
             owns_runtime_store?: owns_runtime_store?,
             host_context: host_context,
             writer: opts[:writer],
             transcript_path: opts[:transcript_path],
             writer_ref: Process.monitor(opts[:writer]),
             owner: opts[:owner_pid],
             owner_ref: if(is_pid(opts[:owner_pid]), do: Process.monitor(opts[:owner_pid])),
             status: if(runs == [] and is_nil(host_error), do: :ready, else: :recovery_required),
             recovery_kind:
               if(host_error,
                 do: :host_admissions,
                 else: if(runs == [], do: nil, else: :indexed_runs)
               ),
             recovery_error: host_error,
             admissions: %{}
           }}

        {:error, reason} ->
          if owns_runtime_store?, do: stop(runtime_store)
          {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:identity, _from, state),
    do: {:reply, {:ok, Map.take(state, [:root, :thread_id, :status, :recovery_error])}, state}

  def handle_call(:runtime_context, _from, state),
    do: {:reply, {:ok, Map.take(state, [:root, :goal, :thread_id, :runtime_store])}, state}

  def handle_call(:get, _from, state), do: {:reply, Goal.get(state.goal), state}

  def handle_call(:prepare_admission, _from, %{status: :ready} = state),
    do: {:reply, {:ok, %{status: :ready, recovered_runs: 0}}, state}

  def handle_call(:prepare_admission, _from, %{recovery_kind: kind} = state)
      when kind in [:unstarted_settlement, :host_settlement],
      do: recover_unstarted(state)

  def handle_call(:prepare_admission, _from, state) do
    result =
      if state.recovery_error, do: {:error, state.recovery_error}, else: recovery_required()

    {:reply, result, state}
  end

  def handle_call(:recover, _from, %{status: :ready} = state),
    do: {:reply, {:ok, %{status: :ready, recovered_runs: 0}}, state}

  def handle_call(:recover, _from, %{recovery_kind: :indexed_runs} = state) do
    recover_indexed_runs(state)
  end

  def handle_call(:recover, _from, %{recovery_kind: kind} = state)
      when kind in [:unstarted_settlement, :host_settlement],
      do: recover_unstarted(state)

  def handle_call(:recover_retired, _from, state)
      when state.status == :ready or state.recovery_kind == :indexed_runs do
    recover_indexed_runs(%{state | status: :recovery_required, recovery_kind: :indexed_runs})
  end

  def handle_call(:recover_retired, _from, %{recovery_kind: kind} = state)
      when kind in [:unstarted_settlement, :host_settlement],
      do: recover_unstarted(state)

  def handle_call(:recover_retired, _from, state),
    do: {:reply, {:error, state.recovery_error}, state}

  def handle_call(:recover, _from, state),
    do: {:reply, {:error, state.recovery_error}, state}

  def handle_call({:withdraw_admission, admission, reason}, _from, state) do
    case Goal.withdraw_admission(state.goal, admission, reason) do
      {:error, error} = result ->
        {:reply, result, require_recovery(state, :withdrawal_unknown, error)}

      result ->
        {:reply, result, state}
    end
  end

  def handle_call({:start_executor, admission}, {caller, _}, state) do
    case state.admissions[admission.reservation_token] do
      %{admission: ^admission, executor: ^caller, stage: :preparing} = entry
      when state.status == :ready ->
        case :atomics.compare_exchange(entry.control, 1, 0, 1) do
          :ok ->
            entry = %{entry | stage: :effects_possible}
            {:reply, :ok, put_admission(state, entry)}

          _sealed ->
            {:reply,
             {:error, Error.new(:cancelled, "Goal continuation was fenced before effects")},
             state}
        end

      _ ->
        {:reply, {:error, Error.new(:resource_conflict, "Goal executor admission is sealed")},
         state}
    end
  end

  def handle_call({:fail_executor, admission, reason}, {caller, _}, state)
      when reason in [:preparation_failed, :cancelled, :superseded] do
    case state.admissions[admission.reservation_token] do
      %{admission: ^admission, executor: ^caller, stage: :preparing} = entry ->
        {:reply, :ok, put_admission(state, %{entry | reason: reason})}

      _ ->
        {:reply, {:error, Error.new(:resource_conflict, "Goal executor admission is sealed")},
         state}
    end
  end

  def handle_call({:open_host_hooks, admission, runtime}, {caller, _}, state) do
    case state.admissions[admission.reservation_token] do
      %{admission: ^admission, hook_scope: _scope} ->
        {:reply, {:error, Error.new(:resource_conflict, "Goal hook scope already exists")}, state}

      %{admission: ^admission, executor: ^caller, stage: :effects_possible} = entry
      when state.status == :ready ->
        result =
          with :ok <- persist_host_admission(state, entry, :hooks_pending),
               do: HookExecution.start(caller, runtime, self(), admission, entry.control)

        case result do
          {:ok, scope} ->
            entry = Map.merge(entry, %{hook_scope: scope, hook_monitor: Process.monitor(scope)})
            {:reply, {:ok, scope}, put_admission(state, entry)}

          {:error, _} = error ->
            {:reply, error, require_recovery(state, :host_admissions, elem(error, 1))}
        end

      _ ->
        {:reply, {:error, Error.new(:resource_conflict, "Goal hook executor is unavailable")},
         state}
    end
  end

  def handle_call({:start_runtime, admission}, {caller, _}, state) do
    case state.admissions[admission.reservation_token] do
      %{admission: ^admission, executor: ^caller, stage: :effects_possible, hook_scope: scope} =
          entry
      when state.status == :ready ->
        case :atomics.compare_exchange(entry.control, 1, 1, 6) do
          :ok ->
            result =
              with :ok <- persist_host_admission(state, entry, :runtime_released),
                   do: hook_scope_call(scope, :release)

            case result do
              :ok ->
                {:reply, :ok, put_admission(state, %{entry | stage: :runtime})}

              {:error, error} ->
                # Runtime is still unopened. The executor returns its actual
                # failure and seals/joins the hooks through the ordinary path.
                entry = Map.put(entry, :host_start_error, error)
                {:reply, {:error, error}, put_admission(state, entry)}
            end

          _ ->
            {:reply,
             {:error, Error.new(:cancelled, "Goal continuation cancelled before Runtime")}, state}
        end

      _ ->
        {:reply, {:error, Error.new(:resource_conflict, "Goal Runtime admission is sealed")},
         state}
    end
  end

  def handle_call({:stop_host_executor, admission, terminal}, {caller, _}, state) do
    case state.admissions[admission.reservation_token] do
      %{admission: ^admission, executor: ^caller, stage: :effects_possible} = entry ->
        previous = :atomics.exchange(entry.control, 1, 4)
        reason = if previous == 5, do: :cancelled, else: :host_stopped
        result = hook_scope_call(entry.hook_scope, {:seal, terminal})
        entry = Map.merge(entry, %{stage: :host_stopped, reason: reason})

        entry =
          if result == :ok, do: entry, else: Map.put(entry, :host_start_error, elem(result, 1))

        {:reply, result, put_admission(state, entry)}

      _ ->
        {:reply, {:error, Error.new(:resource_conflict, "Goal host executor is unavailable")},
         state}
    end
  end

  def handle_call({:set, _mutation, _instruction}, _from, %{status: :recovery_required} = state),
    do: {:reply, recovery_required(), state}

  def handle_call({:clear, _instruction}, _from, %{status: :recovery_required} = state),
    do: {:reply, recovery_required(), state}

  def handle_call({:fork, _writer, _cwd, _path}, _from, %{status: :recovery_required} = state),
    do: {:reply, recovery_required(), state}

  def handle_call({:set, mutation, instruction}, _from, state),
    do: {:reply, Goal.set(state.goal, mutation, instruction), state}

  def handle_call({:clear, instruction}, _from, state),
    do: {:reply, Goal.clear(state.goal, instruction), state}

  def handle_call({:fork, writer, cwd, target_transcript}, _from, state) do
    result =
      with {:ok, writer} <- resolve_writer(writer),
           {:ok, thread_id} <- journal_identity(writer, cwd),
           {:ok, target_store} <-
             open_goal_store(root: Path.join(target_transcript <> ".subagents", "goal")),
           {:ok, snapshot} <- Goal.fork_snapshot(state.goal, thread_id),
           {:ok, ^snapshot} <- GoalStore.import_fork(target_store, thread_id, snapshot) do
        {:ok, %{thread_id: thread_id, snapshot: snapshot}}
      end

    {:reply, result, state}
  end

  def handle_call({:unbind, binding}, _from, state),
    do: {:reply, Goal.unbind(state.goal, binding), state}

  def handle_call({operation, _attrs}, _from, %{status: :recovery_required} = state)
      when operation in [:bind, :idle],
      do: {:reply, recovery_required(), state}

  def handle_call({:bind, attrs}, _from, state) do
    result =
      with :ok <- trusted_thread(attrs, state.thread_id),
           :ok <- preparing_host_admission(state, attrs),
           {:ok, binding} <- Goal.bind(state.goal, Map.put(attrs, :thread_id, state.thread_id)) do
        identity =
          binding
          |> Map.take([:thread_id, :run_id, :incarnation, :mode, :usage_authoritative])
          |> Map.put(:goal_id, binding.expected_goal_id)

        result =
          with :ok <- GoalRuns.record(state.root, state.thread_id, identity),
               do: persist_bound_host_admission(state, attrs)

        case result do
          :ok ->
            {:ok, %{goal: state.goal, goal_binding: binding, thread_id: state.thread_id}}

          {:error, _} = error ->
            Goal.unbind(state.goal, binding)
            error
        end
      end

    {:reply, result, state}
  end

  def handle_call({:idle, generation}, _from, state) do
    case Goal.idle(state.goal, generation) do
      {:ok, {:started, admission}} = result ->
        case GoalHost.release_turn(state.host_context, state.thread_id, admission) do
          :ok ->
            {:reply, result, state}

          {:ok, %{executor: executor, control: control}} when is_pid(executor) ->
            entry = %{
              admission: admission,
              executor: executor,
              control: control,
              monitor: Process.monitor(executor),
              stage: :preparing,
              reason: :preparation_failed
            }

            state = put_admission(state, entry)
            send(executor, {:goal_executor_release, self(), admission})
            {:reply, result, state}

          {:ok, {:not_submitted, reason}} when reason in [:cancelled, :superseded] ->
            case Goal.withdraw_admission(state.goal, admission, reason) do
              {:ok, {:withdrawn, ^reason}} ->
                {:reply, {:ok, {:not_submitted, reason}}, state}

              {:error, error} = result ->
                {:reply, result, require_recovery(state, :withdrawal_unknown, error)}

              disposition ->
                error =
                  Error.new(:unknown_outcome, "goal admission withdrawal was not confirmed",
                    details: %{disposition: disposition}
                  )

                {:reply, {:error, error}, require_recovery(state, :withdrawal_unknown, error)}
            end

          {:error, error} = result ->
            {:reply, result, require_recovery(state, :release_unknown, error)}

          _ ->
            error = Error.new(:malformed_result, "invalid goal release acknowledgement")
            {:reply, {:error, error}, require_recovery(state, :release_unknown, error)}
        end

      result ->
        {:reply, result, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{writer_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, executor, cause}, state) do
    case Enum.find(state.admissions, fn {_token, entry} ->
           entry.monitor == ref and entry.executor == executor
         end) do
      {_token, %{stage: :preparing} = entry} ->
        # Only this monitored executor can open the effect boundary. DOWN
        # seals its complete token/generation before any Store acknowledgement;
        # it can no longer start hooks, startup children or Runtime work.
        reason =
          case :atomics.exchange(entry.control, 1, 4) do
            2 -> :cancelled
            3 -> :superseded
            _preparing -> entry.reason
          end

        entry = Map.merge(entry, %{stage: :sealed, down: cause, reason: reason})
        {:noreply, settle_unstarted(put_admission(state, entry), entry)}

      {_token, %{stage: :host_stopped} = entry} ->
        entry = Map.put(entry, :down, cause)
        {:noreply, settle_host_if_ready(put_admission(state, entry), entry)}

      {_token, %{stage: :effects_possible, hook_scope: _scope} = entry} ->
        previous = :atomics.compare_exchange(entry.control, 1, 1, 4)
        reason = if previous == 5, do: :cancelled, else: :host_stopped
        entry = Map.merge(entry, %{stage: :host_stopped, down: cause, reason: reason})
        {:noreply, settle_host_if_ready(put_admission(state, entry), entry)}

      {token, _entry} ->
        # Runtime work keeps its ordinary binding, receipts and recovery path.
        {:noreply, %{state | admissions: Map.delete(state.admissions, token)}}

      nil ->
        case Enum.find(state.admissions, fn {_token, entry} ->
               entry[:hook_monitor] == ref and entry[:hook_scope] == executor
             end) do
          {_token, %{stage: stage} = entry} when stage != :runtime ->
            entry = Map.put(entry, :hook_down, cause)
            {:noreply, settle_host_if_ready(put_admission(state, entry), entry)}

          _ ->
            {:noreply, state}
        end
    end
  end

  def handle_info({:goal_host_hooks_settled, scope, admission, evidence, terminal}, state) do
    case state.admissions[admission.reservation_token] do
      %{hook_scope: ^scope, admission: ^admission} = entry ->
        entry = Map.merge(entry, %{hook_evidence: evidence, host_terminal: terminal})
        {:noreply, settle_host_if_ready(put_admission(state, entry), entry)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, pid, reason}, state) do
    if pid == state.goal or pid == state.runtime_store,
      do: {:stop, {:owned_process_exit, reason}, state},
      else: {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    stop(state.goal)
    if state.owns_runtime_store?, do: stop(state.runtime_store)
    :ok
  end

  defp stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp resolve_writer(writer) do
    case GenServer.whereis(writer) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: writer_unavailable()

      _ ->
        writer_unavailable()
    end
  rescue
    ArgumentError -> writer_unavailable()
  end

  defp writer_unavailable,
    do: {:error, Error.new(:unsupported_capability, "persistent Goal requires a session writer")}

  defp require_recovery(state, kind, error),
    do: %{state | status: :recovery_required, recovery_kind: kind, recovery_error: error}

  defp put_admission(state, entry),
    do: %{state | admissions: Map.put(state.admissions, entry.admission.reservation_token, entry)}

  defp hook_scope_call(scope, operation) do
    case operation do
      :release -> HookExecution.release(scope)
      {:seal, terminal} -> HookExecution.seal(scope, terminal)
    end
  catch
    :exit, cause ->
      {:error, Error.new(:unknown_outcome, "Goal hook scope is unavailable", cause: cause)}
  end

  defp settle_host_if_ready(state, %{stage: :host_stopped, down: _, hook_down: _} = entry) do
    case {entry.hook_down, entry[:hook_evidence], entry[:host_terminal]} do
      {:normal, %{cleanup: :confirmed, records: records}, terminal} when is_map(terminal) ->
        :atomics.exchange(entry.control, 1, 4)

        entry =
          case records do
            [] ->
              reason =
                if entry.reason in [:cancelled, :superseded],
                  do: entry.reason,
                  else: :preparation_failed

              Map.merge(entry, %{stage: :sealed, reason: reason})

            _ ->
              effects = %{
                kind: :host_pre_runtime,
                records: records,
                result: terminal,
                cleanup: :confirmed
              }

              Map.merge(entry, %{stage: :sealed, effects: effects})
          end

        settle_unstarted(put_admission(state, entry), entry)

      observation ->
        error =
          Error.new(:unknown_outcome, "Goal host hook cleanup/result is unconfirmed",
            cause: %{observation: observation, boundary_error: entry[:host_start_error]}
          )

        notify_settlement(state, entry, {:error, error})
        require_recovery(state, :host_effects_unconfirmed, error)
    end
  end

  defp settle_host_if_ready(state, _entry), do: state

  defp settle_unstarted(state, entry) do
    identity =
      Map.take(entry.admission, [
        :run_id,
        :turn_id,
        :incarnation,
        :host_generation,
        :reservation_token
      ])

    attestation = %{
      admission: identity,
      executor: :confirmed_down,
      runtime_admission: :never_started,
      future_start: :fenced,
      effects: Map.get(entry, :effects, :none_dispatched)
    }

    operation =
      if Map.has_key?(entry, :effects),
        do: :settle_host_admission,
        else: :settle_unstarted_admission

    recovery_kind =
      if operation == :settle_host_admission, do: :host_settlement, else: :unstarted_settlement

    result =
      with :ok <- persist_host_settlement(state, entry, attestation),
           do: apply(Goal, operation, [state.goal, entry.admission, entry.reason, attestation])

    case result do
      {:ok, {:settled, reason}} when reason == entry.reason ->
        notify_settlement(state, entry, {:ok, {:settled, reason}})
        %{state | admissions: Map.delete(state.admissions, entry.admission.reservation_token)}

      {:error, error} ->
        notify_settlement(state, entry, {:error, error})
        require_recovery(state, recovery_kind, error)

      disposition ->
        error =
          Error.new(:unknown_outcome, "Goal admission settlement was not confirmed",
            details: %{disposition: disposition, executor_down: entry.down}
          )

        notify_settlement(state, entry, {:error, error})
        require_recovery(state, recovery_kind, error)
    end
  end

  defp persist_host_admission(state, entry, stage, settlement \\ nil) do
    GoalStore.put_host_admission(state.goal_store, state.thread_id, %{
      admission:
        Map.take(
          entry.admission,
          ~w(run_id turn_id incarnation host_generation reservation_token)a
        ),
      stage: stage,
      settlement: settlement
    })
  end

  defp persist_host_settlement(state, %{hook_scope: _} = entry, attestation),
    do:
      persist_host_admission(state, entry, :sealed, %{
        reason: entry.reason,
        attestation: attestation
      })

  defp persist_host_settlement(_state, _entry, _attestation), do: :ok

  defp preparing_host_admission(state, %{admission: admission}) do
    case state.admissions[admission.reservation_token] do
      %{admission: ^admission, stage: :effects_possible, control: control} ->
        if :atomics.get(control, 1) == 1,
          do: :ok,
          else: {:error, Error.new(:cancelled, "Goal continuation cancelled before binding")}

      %{admission: ^admission, stage: :runtime} ->
        :ok

      _ ->
        {:error, Error.new(:resource_conflict, "Goal host admission changed before binding")}
    end
  end

  defp preparing_host_admission(_state, _attrs), do: :ok

  defp persist_bound_host_admission(state, %{admission: admission}) do
    case state.admissions[admission.reservation_token] do
      %{admission: ^admission, stage: :effects_possible, hook_scope: _scope} ->
        # The exact executor still owns pre-Runtime preparation. The durable
        # run index is not evidence that Runtime startup has been released.
        :ok

      %{admission: ^admission, stage: :runtime} = entry ->
        persist_host_admission(state, entry, :runtime_bound)

      _ ->
        {:error, Error.new(:resource_conflict, "Goal host admission changed before binding")}
    end
  end

  defp persist_bound_host_admission(_state, _attrs), do: :ok

  defp host_admission_recovery(entries, record, runs) do
    Enum.find_value(entries, fn {token, entry} ->
      settled? =
        case {entry, record.admission_settlements[token]} do
          {%{stage: :sealed, settlement: settlement}, %{attestation: attestation, reason: reason}} ->
            settlement === %{attestation: attestation, reason: reason}

          _ ->
            false
        end

      indexed? =
        entry.stage in [:runtime_released, :runtime_bound] and
          Enum.any?(
            runs,
            &(&1.run_id == entry.admission.run_id and
                &1.incarnation == entry.admission.incarnation)
          )

      unless settled? or indexed? do
        Error.new(:unknown_outcome, "Goal host admission requires retained execution evidence",
          details: %{admission: entry.admission, stage: entry.stage}
        )
      end
    end)
  end

  defp notify_settlement(%{owner: owner}, entry, result) when is_pid(owner),
    do:
      send(owner, {
        :goal_executor_settled,
        self(),
        entry.executor,
        entry.control,
        entry.admission,
        result
      })

  defp notify_settlement(_state, _entry, _result), do: :ok

  defp recover_unstarted(state) do
    ready = %{state | status: :ready, recovery_kind: nil, recovery_error: nil}

    next =
      Enum.reduce_while(state.admissions, ready, fn
        {_token, %{stage: :sealed} = entry}, acc ->
          next = settle_unstarted(acc, entry)
          if next.status == :ready, do: {:cont, next}, else: {:halt, next}

        _, acc ->
          {:cont, acc}
      end)

    if next.status == :ready,
      do: {:reply, {:ok, %{status: :ready, recovered_runs: 0}}, next},
      else: {:reply, {:error, next.recovery_error}, next}
  end

  defp recover_indexed_runs(state) do
    case recover_runs(state) do
      {:ok, count} ->
        {:reply, {:ok, %{status: :ready, recovered_runs: count}},
         %{state | status: :ready, recovery_kind: nil, recovery_error: nil}}

      {:error, error} = result ->
        {:reply, result, %{state | recovery_error: error}}
    end
  end

  defp recover_runs(state) do
    with {:ok, identities} <- GoalRuns.list(state.root, state.thread_id),
         {:ok, record} <- Goal.snapshot(state.goal),
         {:ok, runs} <- load_recoverable_runs(state, identities, record),
         {:ok, children} <-
           GoalDescendants.load(
             state.writer,
             state.transcript_path,
             identities,
             if(record.goal, do: record.goal.goal_id)
           ),
         {:ok, _} <- Goal.restore(state.goal) do
      result =
        Enum.reduce_while(runs, {:ok, 0}, fn {identity, snapshot}, {:ok, count} ->
          attrs =
            identity
            |> Map.delete(:goal_id)
            |> Map.put(:authority, %{run_id: identity.run_id, grants: []})

          with {:ok, binding} <- Goal.bind(state.goal, attrs) do
            delivered =
              with {:ok, _} <- GoalBridge.redeliver(state.goal, binding, snapshot.run),
                   :ok <- acknowledge_terminal_outbox(state.runtime_store, snapshot.run),
                   do: {:ok, :reconciled}

            unbound = Goal.unbind(state.goal, binding)

            case {delivered, unbound} do
              {{:ok, _}, {:ok, :unbound}} -> {:cont, {:ok, count + 1}}
              {{:error, _} = error, _} -> {:halt, error}
              {_, {:error, _} = error} -> {:halt, error}
            end
          else
            error -> {:halt, error}
          end
        end)

      with {:ok, count} <- result,
           {:ok, total} <- recover_descendants(state, children, count),
           :ok <- LifetimeEvidence.refresh(state.transcript_path, state.thread_id),
           do: {:ok, total}
    end
  end

  defp recover_descendants(state, children, count) do
    Enum.reduce_while(children, {:ok, count}, fn child, {:ok, total} ->
      attrs =
        child.parent
        |> Map.delete(:goal_id)
        |> Map.put(:authority, %{run_id: child.parent.run_id, grants: []})

      case Goal.bind(state.goal, attrs) do
        {:ok, parent} ->
          result =
            case Goal.delegate(state.goal, parent, child.identity) do
              {:ok, binding} ->
                delivered =
                  with {:ok, _} <- GoalBridge.redeliver(state.goal, binding, child.snapshot.run),
                       do: GoalDescendants.acknowledge(child)

                unbound = Goal.unbind(state.goal, binding)

                case {delivered, unbound} do
                  {:ok, {:ok, :unbound}} -> :ok
                  {{:error, _} = error, _} -> error
                  {_, {:error, _} = error} -> error
                end

              {:error, _} = error ->
                error
            end

          unbound = Goal.unbind(state.goal, parent)

          case {result, unbound} do
            {:ok, {:ok, :unbound}} -> {:cont, {:ok, total + 1}}
            {{:error, _} = error, _} -> {:halt, error}
            {_, {:error, _} = error} -> {:halt, error}
          end

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp acknowledge_terminal_outbox(store, run) do
    case get_in(run, [:context, :conversation, :goal_outbox]) do
      [_ | _] = receipts ->
        case RuntimeStore.store(Store, store, run, %{
               command:
                 {:goal_outbox_acknowledged, System.system_time(:millisecond),
                  %{run_id: run.run_id, incarnation: run.incarnation, receipts: receipts}}
             }) do
          {:ok, _} -> :ok
          {:error, _} = error -> error
        end

      _ ->
        :ok
    end
  end

  defp load_recoverable_runs(state, identities, record) do
    goal_id = if record.goal, do: record.goal.goal_id

    Enum.reduce_while(identities, {:ok, []}, fn identity, {:ok, runs} ->
      with {:ok, snapshot} <- Store.load(state.runtime_store, identity.run_id),
           {:ok, snapshot} <- RunRecovery.reconcile_root(state.runtime_store, identity, snapshot),
           :ok <- recoverable_run(state, identity, snapshot, goal_id) do
        # A confirmed terminal run without retained receipts has nothing to
        # attribute to a later Goal. Keep its index and snapshot as history,
        # without minting a binding against the current Goal.
        if recoverable_goal_id(identity, snapshot.run) == goal_id,
          do: {:cont, {:ok, runs ++ [{identity, snapshot}]}},
          else: {:cont, {:ok, runs}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp recoverable_run(state, identity, %{run: %{state: :unknown_outcome}} = snapshot, goal_id) do
    if get_in(snapshot.run, [:context, :conversation, :goal_outbox]) not in [nil, []] and
         recoverable_goal_id(identity, snapshot.run) != goal_id,
       do: recovery_conflict(identity, "indexed Goal identity changed with retained receipts"),
       else:
         LifetimeEvidence.allow_root(
           state.runtime_store,
           identity,
           snapshot,
           state.transcript_path
         )
  end

  defp recoverable_run(_state, identity, snapshot, goal_id) do
    run = snapshot.run
    work = Kernel.cleanup_requirements(run)
    intents = Map.get(run, :execution_intents, %{})

    cond do
      # Recovery fences advance the current run, while its original Goal index
      # and retained receipts keep the admitted incarnation used for attribution.
      run.run_id != identity.run_id or not is_integer(run.incarnation) or
          run.incarnation < identity.incarnation ->
        recovery_conflict(identity, "indexed Goal run identity changed")

      run.state not in [:completed, :failed, :cancelled, :timed_out] ->
        recovery_conflict(identity, "indexed Goal run is not confirmed terminal")

      work != %{provider: nil, tools: [], children: [], dependencies: []} or
        snapshot.effects != [] or snapshot.outbox != [] or not is_map(intents) or
          not Enum.all?(intents, fn {_id, intent} ->
            is_map(intent) and intent[:status] in [:consumed, :cancelled]
          end) ->
        recovery_conflict(identity, "indexed Goal run has unreconciled effects")

      get_in(run, [:context, :conversation, :goal_outbox]) not in [nil, []] and
          recoverable_goal_id(identity, run) != goal_id ->
        recovery_conflict(identity, "indexed Goal identity changed with retained receipts")

      true ->
        :ok
    end
  end

  # A root can create its first Goal through a native tool after its ordinary
  # run was indexed. The public Runtime then attributes later receipts to that
  # new Goal. Its exact durable receipt identity fills this initial nil only;
  # an indexed older Goal never changes identity during recovery.
  defp recoverable_goal_id(%{goal_id: nil}, run) do
    case get_in(run, [:context, :conversation, :goal_outbox]) do
      [%{expected_goal_id: goal_id} | _] = receipts when is_binary(goal_id) ->
        if Enum.all?(receipts, &(&1[:expected_goal_id] == goal_id)), do: goal_id

      _ ->
        nil
    end
  end

  defp recoverable_goal_id(identity, _run), do: identity.goal_id

  defp recovery_conflict(identity, message),
    do: {:error, Error.new(:resource_conflict, message, details: %{run_id: identity.run_id})}

  defp validate_runtime_store(opts) do
    case opts[:runtime_store] do
      pid when is_pid(pid) ->
        if Process.alive?(pid),
          do: :ok,
          else: {:error, Error.new(:execution_failure, "runtime store is unavailable")}

      nil ->
        path = opts[:runtime_store_path]

        if is_binary(path) and Path.type(path) == :absolute,
          do: :ok,
          else: {:error, Error.new(:validation, "runtime store path must be absolute")}

      _ ->
        {:error, Error.new(:validation, "invalid runtime store")}
    end
  end

  defp open_goal_store(opts) do
    case DynamicSupervisor.start_child(
           Sigma.Agent.DynamicSupervisor,
           {GoalStore, [path: opts[:root]]}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp open_runtime_store(opts) do
    case opts[:runtime_store] do
      pid when is_pid(pid) ->
        if Process.alive?(pid),
          do: {:ok, pid, false},
          else: {:error, Error.new(:execution_failure, "runtime store is unavailable")}

      nil ->
        case Store.start_link(path: opts[:runtime_store_path]) do
          {:ok, pid} ->
            {:ok, pid, true}

          {:error, {:already_started, _pid}} ->
            {:error, Error.new(:resource_conflict, "runtime store already has an owner")}

          {:error, _} = error ->
            error
        end

      _ ->
        {:error, Error.new(:validation, "invalid runtime store")}
    end
  end

  defp journal_identity(writer, cwd) do
    with {:ok, selected} <- apply(Sigma.Session.Writer, :selected_journal, [writer]) do
      case header(selected) do
        {:ok, id} ->
          {:ok, id}

        :missing ->
          with {:ok, _} <- apply(Sigma.Session.Writer, :append, [writer, {:agent_start, cwd}]),
               {:ok, selected} <- apply(Sigma.Session.Writer, :selected_journal, [writer]) do
            case header(selected) do
              {:ok, id} -> {:ok, id}
              _ -> {:error, Error.new(:malformed_result, "session header is unavailable")}
            end
          end

        error ->
          error
      end
    end
  catch
    :exit, _ -> {:error, Error.new(:execution_failure, "session writer is unavailable")}
  end

  defp header(%{entries: entries}) when is_list(entries) do
    case Enum.filter(entries, &(&1["type"] == "session")) do
      [] -> :missing
      [%{"id" => id}] when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, Error.new(:malformed_result, "session requires one immutable header")}
    end
  end

  defp header(_), do: {:error, Error.new(:malformed_result, "invalid selected journal")}

  defp trusted_thread(attrs, thread_id) when is_map(attrs) do
    if attrs[:thread_id] in [nil, thread_id],
      do: :ok,
      else: {:error, Error.new(:forbidden, "foreign Goal thread identity")}
  end

  defp trusted_thread(_attrs, _thread_id),
    do: {:error, Error.new(:validation, "invalid goal binding")}

  defp recovery_required,
    do:
      {:error,
       Error.new(:resource_conflict, "Goal runtime recovery is required before admission")}
end
