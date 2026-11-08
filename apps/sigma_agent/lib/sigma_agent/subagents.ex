defmodule Sigma.Agent.Subagents do
  @moduledoc "Session-owned bridge to Backplane's nested collaboration runtime."
  use GenServer

  require Logger

  alias Backplane.AgentRuntime.{Error, Codex.MultiAgent, Codex.Session}

  alias Sigma.Agent.Backplane.{
    ChildArchiveEvidence,
    ChildIO,
    ChildInteractionResponder,
    CodexResources,
    LifetimeEvidence,
    LifetimeRecovery,
    Store,
    UserInput
  }

  alias Sigma.Session.{Subagents, Writer}

  @collaboration ~w(spawn_agent send_message followup_task interrupt_agent list_agents wait_agent)
  @configuration ~w(model provider provider_options system_prompt session_context context_limit cwd tools mcp_servers hook_specs dispatcher_opts policy task_supervisor native_tools native_memory_root native_plugins)a
  @terminal [:completed, :errored, :interrupted, :shutdown]

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, shutdown: 10_000}
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  def prepare_root(host, context), do: GenServer.call(host, {:prepare_root, context}, :infinity)
  def snapshot(host), do: GenServer.call(host, :snapshot, :infinity)
  def archive_sources(host), do: GenServer.call(host, :archive_sources, :infinity)

  def message_board_context(host, agent_name, operation),
    do: GenServer.call(host, {:message_board_context, agent_name, operation}, :infinity)

  def can_stop(host), do: GenServer.call(host, :can_stop)
  def close(host), do: GenServer.call(host, :close, :infinity)

  @doc "Confirms execution retirement while retaining owners needed for Goal ACK and archive export."
  def close_execution(host), do: GenServer.call(host, :close_execution, :infinity)

  @doc "Persists public export stages before orderly shutdown; does not confirm full closure."
  def stage_shutdown(host), do: GenServer.call(host, :stage_shutdown, :infinity)

  def origin(host, operation), do: GenServer.call(host, {:origin, operation})

  def rejected_before_start?(host, error),
    do: GenServer.call(host, {:rejected_before_start, error})

  def pending(host), do: GenServer.call(host, :pending)
  def answer(host, id, reply), do: GenServer.call(host, {:answer, id, reply})

  def ask(host, identity, request, opts \\ []) do
    timeout = request[:timeout_ms] || Keyword.get(opts, :timeout, :infinity)

    with {:ok, id, request} <- GenServer.call(host, {:ask, identity, request, self()}, :infinity) do
      try do
        resolution =
          case Keyword.get(opts, :resolver) do
            nil -> :ok
            resolver -> answer(host, id, resolver.(request))
          end

        with :ok <- resolution do
          receive do
            {:subagent_answer, ^id, reply} -> reply
          after
            timeout -> {:error, :timeout}
          end
        end
      after
        GenServer.cast(host, {:forget_question, id})
      end
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    writer = Keyword.get(opts, :writer)
    evidence = evidence_from_writer(writer)
    projection = apply(Subagents, :recover, [evidence.roster])
    roster = apply(Subagents, :snapshot, [projection])

    unresolved =
      Enum.any?(evidence.admissions, fn {_id, attempt} ->
        attempt.receipts == [] or
          (List.last(attempt.receipts).process_started and
             not Enum.any?(roster.agents, &(&1.agent_id == attempt.intent.agent_id)))
      end)

    uncertain =
      Enum.filter(roster.agents, &(&1.status == :unknown_outcome or &1.closure == :unknown))

    retired =
      uncertain != [] and retired_roster?(writer, Keyword.get(opts, :transcript_path), uncertain)

    recovery_required = unresolved or (uncertain != [] and not retired)

    {:ok,
     %{
       writer: writer,
       enabled: Keyword.get(opts, :enabled, true),
       repo_path: Keyword.fetch!(opts, :repo_path),
       session_id: Keyword.fetch!(opts, :session_id),
       transcript_path: Keyword.get(opts, :transcript_path),
       max_threads: Keyword.get(opts, :max_concurrent_threads_per_session, 4),
       projection: projection,
       roster: roster,
       root_session_id: projection.root_session_id || Keyword.fetch!(opts, :session_id),
       recovered_admissions: evidence.admissions,
       generation: nil,
       session: nil,
       codex_resources: nil,
       lifetime_recovery: nil,
       generation_closed: false,
       execution_closed: false,
       execution_result: nil,
       archive_result: :not_started,
       completion_stage: :pending,
       manager: nil,
       interaction_responder: nil,
       contracts: [],
       root: nil,
       root_binding: nil,
       children: %{},
       child_retirements: %{},
       archive_aliases: %{},
       restored_children: %{},
       attempts: %{},
       origins: %{},
       pending: %{},
       jobs: %{},
       manager_revision: 0,
       manager_id: nil,
       observer_buffer: [],
       preparing: false,
       closing: false,
       close_waiters: [],
       execution_close_waiters: [],
       shutdown_stage_waiters: [],
       error: if(recovery_required, do: :recovery_required)
     }}
  end

  @impl true
  def handle_call(:archive_sources, _from, state) do
    {:reply,
     {:ok,
      %{
        root: %{
          writer: state.writer,
          transcript_path: state.transcript_path,
          host_lifetime_id:
            get_in(state.root, [:config, :host_retirement, :identity, :host_lifetime_id])
        },
        error: state.error,
        generation_closed: state.generation_closed,
        execution_closed: state.execution_closed,
        execution_result: state.execution_result,
        archive_result: state.archive_result,
        completion_stage: state.completion_stage,
        roster: state.projection,
        children:
          Enum.map(state.children, fn {_id, child} -> Map.take(child, [:identity, :io]) end)
      }}, state}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply,
     {:ok,
      %{
        available: state.enabled and state.writer != nil and state.error == nil,
        subagents: state.roster
      }}, state}
  end

  def handle_call({:message_board_context, name, operation}, _from, state) do
    caller =
      cond do
        name == "/root" and is_map(state.root_binding) and
          state.root_binding.run_id == operation.run_id and
            state.root_binding.run_incarnation == operation.incarnation ->
          %{agent_id: state.root_session_id, agent_path: "/root"}

        true ->
          Enum.find_value(state.children, fn {_id, child} ->
            identity = child.identity

            if identity.agent_path == name and identity.run_id == operation.run_id and
                 identity.incarnation == operation.incarnation,
               do: Map.take(identity, [:agent_id, :agent_path])
          end)
      end

    result =
      if caller && state.writer && is_binary(state.transcript_path) do
        agents =
          state.roster.agents
          |> Enum.sort_by(& &1.revision)
          |> Map.new(&{&1.agent_path, &1.agent_id})
          |> Map.merge(
            Map.new(state.children, fn {_id, child} ->
              {child.identity.agent_path, child.identity.agent_id}
            end)
          )
          |> Map.put("/root", state.root_session_id)

        {:ok,
         %{
           writer: state.writer,
           root_transcript: state.transcript_path,
           caller: caller,
           agents: agents,
           manager: state.manager,
           root_agent_id: state.root_session_id,
           root_binding: state.root_binding
         }}
      else
        failure(:resource_conflict, "message-board caller is no longer in the current run tree")
      end

    {:reply, result, state}
  end

  def handle_call(:can_stop, _from, state) do
    unknown = Enum.filter(state.roster.agents, &(&1.status == :unknown_outcome))
    retired = unknown != [] and closed_roster?(state.writer, state.transcript_path, unknown)

    active =
      state.roster.counts.executing + state.roster.counts.pending +
        if(retired, do: 0, else: state.roster.counts.unknown)

    uncertain = Enum.any?(state.roster.agents, &(&1.closure == :unknown))
    unresolved = Enum.any?(state.attempts, fn {_id, attempt} -> attempt.status == :reserved end)

    result =
      if active == 0 and not uncertain and not unresolved and map_size(state.pending) == 0 and
           not state.preparing and not state.closing and state.error == nil,
         do: :ok,
         else: {:error, :subagent_resources_active}

    {:reply, result, state}
  end

  def handle_call(
        {:prepare_root, %{config: %{native_tools: false}}},
        _from,
        %{writer: nil} = state
      ),
      do: {:reply, {:ok, %{contracts: [], binding: nil, native_context: nil}}, state}

  def handle_call({:prepare_root, context}, _from, %{writer: nil} = state)
      when not is_map_key(context.config, :native_tools),
      do: {:reply, {:ok, %{contracts: [], binding: nil, native_context: nil}}, state}

  def handle_call(
        {:prepare_root, %{config: %{native_tools: false}}},
        _from,
        %{enabled: false} = state
      ),
      do: {:reply, {:ok, %{contracts: [], binding: nil, native_context: nil}}, state}

  def handle_call({:prepare_root, context}, _from, %{enabled: false} = state)
      when not is_map_key(context.config, :native_tools),
      do: {:reply, {:ok, %{contracts: [], binding: nil, native_context: nil}}, state}

  def handle_call({:prepare_root, context}, from, state) do
    state = refresh_recovery_gate(state)

    if state.preparing or state.closing or state.error != nil or
         (state.execution_closed and not state.generation_closed) do
      {:reply, failure(:resource_conflict, "subagent host is unavailable"), state}
    else
      host = self()
      # Preparation may retire a confirmed-closed generation. The host owns
      # these links; unlink here before the control task stops the old owners.
      Enum.each([state.session, state.manager, state.codex_resources], fn pid ->
        if is_pid(pid), do: Process.unlink(pid)
      end)

      state = %{state | root: context, preparing: true}
      job(state, from, :prepare, fn -> prepare_generation(host, state, context) end)
    end
  end

  def handle_call({:origin, operation}, _from, state) do
    key = operation.run_id
    value = %{tool_call_id: operation.tool_call_id, arguments: operation.arguments}
    {:reply, :ok, %{state | origins: Map.put(state.origins, key, value)}}
  end

  def handle_call({:rejected_before_start, error}, _from, state) do
    attempt = state.attempts[error.details[:attempt_id]]

    {:reply, attempt != nil and attempt.status == :rejected and not attempt.process_started,
     state}
  end

  # These callbacks run inside MultiAgent's serialized admission. Nothing they
  # call may synchronously call the manager or Codex.Session.
  def handle_call({:child_options, generation, request, run_id, parent}, _from, state) do
    if generation != state.generation or state.closing or state.error != nil do
      {:reply, failure(:resource_conflict, "subagent admission is closed"), state}
    else
      {result, state} = prepare_child(state, request, run_id, parent)
      {:reply, result, state}
    end
  end

  def handle_call({:receipt, generation, receipt}, _from, state) do
    if generation != state.generation do
      {:reply, failure(:forbidden, "stale subagent admission receipt"), state}
    else
      {result, state} = commit_receipt(state, receipt)
      {:reply, result, state}
    end
  end

  def handle_call(:pending, _from, state),
    do: {:reply, Enum.map(state.pending, fn {_id, item} -> item.request end), state}

  def handle_call({:native_interaction_handler, correlation, kind}, _from, state) do
    child = state.children[qualify(state, correlation.agent_id)]

    if (child && correlation.manager_id == state.manager_id) and
         correlation.run_id == child.identity.run_id and
         correlation.incarnation == child.identity.incarnation and
         current_child?(state, child.identity) do
      {:reply, native_interaction_handler(state, child.identity, kind), state}
    else
      {:reply, {:error, :stale_subagent_request}, state}
    end
  end

  def handle_call({:ask, identity, request, waiter}, _from, state) do
    if current_child?(state, identity) and not state.closing do
      id = "subagent_question_" <> unique()

      source =
        Map.take(identity, [
          :agent_id,
          :agent_path,
          :child_session_id,
          :public_run_id,
          :incarnation
        ])

      request = Map.merge(request, %{id: id, source: source})

      item = %{
        request: request,
        identity: identity,
        waiter: waiter,
        monitor: Process.monitor(waiter)
      }

      notify(state, {:ask_user_question, id, request})
      state = child_activity(state, identity, :waiting_approval)
      {:reply, {:ok, id, request}, %{state | pending: Map.put(state.pending, id, item)}}
    else
      {:reply, {:error, :stale_subagent_request}, state}
    end
  end

  def handle_call({:answer, id, reply}, _from, state) do
    case state.pending[id] do
      nil ->
        {:reply, {:error, :question_not_found}, state}

      item ->
        if current_child?(state, item.identity) and not state.closing do
          send(item.waiter, {:subagent_answer, id, reply})
          {:reply, :ok, forget_question(state, id)}
        else
          {:reply, {:error, :stale_subagent_request}, forget_question(state, id)}
        end
    end
  end

  def handle_call(:close, _from, %{generation_closed: true, error: nil} = state),
    do: {:reply, {:ok, %{status: :confirmed}}, state}

  def handle_call(:close_execution, _from, %{execution_closed: true} = state),
    do: {:reply, state.execution_result, state}

  def handle_call(:close_execution, from, state) do
    request_close(state, :execution_close_waiters, from)
  end

  def handle_call(:close, from, state) do
    request_close(state, :close_waiters, from)
  end

  def handle_call(:stage_shutdown, from, state) do
    state = %{state | shutdown_stage_waiters: [from | state.shutdown_stage_waiters]}
    {:noreply, drain_shutdown_stages(state)}
  end

  defp drain_shutdown_stages(%{shutdown_stage_waiters: []} = state), do: state

  defp drain_shutdown_stages(state)
       when state.preparing or state.closing or map_size(state.jobs) != 0,
       do: state

  defp drain_shutdown_stages(state) do
    result =
      cond do
        not state.execution_closed or
            not match?({:ok, %{status: :confirmed}}, state.execution_result) ->
          failure(:unknown_outcome, "shutdown staging requires confirmed execution retirement")

        state.generation_closed ->
          :ok

        true ->
          runtime_call(fn ->
            ChildArchiveEvidence.stage(state.lifetime_recovery, state.manager)
          end)
      end

    # Join all existing control and observer jobs before checking the actual
    # execution acknowledgement. A stage never changes the archive outcome.
    Enum.each(state.shutdown_stage_waiters, &GenServer.reply(&1, result))
    %{state | shutdown_stage_waiters: []}
  end

  defp finish_shutdown_stages({:noreply, state}),
    do: {:noreply, drain_shutdown_stages(state)}

  defp request_close(state, waiters, from) do
    was_closing = state.closing

    state =
      invalidate_questions(
        state |> Map.put(:closing, true) |> Map.update!(waiters, &[from | &1]),
        fn _ -> true end
      )

    cond do
      was_closing or state.preparing ->
        {:noreply, state}

      state.session ->
        start_close(state)

      true ->
        result =
          if state.error,
            do: failure(:unknown_outcome, "subagent recovery is required"),
            else: :ok

        {:noreply, reply_closes(state, result)}
    end
  end

  @impl true
  def handle_cast({:forget_question, id}, state), do: {:noreply, forget_question(state, id)}

  @impl true
  def handle_info(
        {:generation_completion, generation, stage},
        %{generation: generation} = state
      )
      when state.closing or state.preparing do
    {:noreply, %{state | completion_stage: stage}}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    finished =
      case Map.pop(state.jobs, ref) do
        {nil, _} ->
          {:noreply, state}

        {{from, :prepare}, jobs} ->
          Process.demonitor(ref, [:flush])
          state = %{state | jobs: jobs}

          case result do
            {:ok, runtime} ->
              Enum.each(
                [
                  runtime.session,
                  runtime.manager,
                  runtime.codex_resources,
                  runtime.lifetime_recovery
                ],
                fn pid ->
                  if is_pid(pid), do: Process.link(pid)
                end
              )

              state = adopt_generation(state, runtime)

              if state.closing do
                GenServer.reply(
                  from,
                  failure(:resource_conflict, "subagent admission is closing")
                )

                start_close(%{state | preparing: false})
              else
                job(state, from, :bind, fn ->
                  recorded =
                    if state.lifetime_recovery,
                      do:
                        LifetimeRecovery.register_root(
                          state.lifetime_recovery,
                          state.root.authority.run_id,
                          1
                        ),
                      else: :ok

                  with :ok <- recorded do
                    if state.codex_resources,
                      do:
                        CodexResources.bind(state.codex_resources, state.root.authority,
                          incarnation: 1
                        ),
                      else: Session.bind(state.session, state.root.authority, incarnation: 1)
                  end
                end)
              end

            {:error, _} = error ->
              Enum.each([state.session, state.manager, state.codex_resources], fn pid ->
                if is_pid(pid) and Process.alive?(pid), do: Process.link(pid)
              end)

              GenServer.reply(from, error)
              state = %{state | preparing: false}

              state =
                if state.closing,
                  do:
                    reply_closes(
                      %{state | error: :preparation_failed},
                      failure(:unknown_outcome, "subagent preparation failed while closing")
                    ),
                  else: state

              {:noreply, state}
          end

        {{from, :bind}, jobs} ->
          Process.demonitor(ref, [:flush])
          state = %{state | jobs: jobs, preparing: false}

          state =
            case result do
              {:ok, binding} -> %{state | root_binding: binding}
              _ -> %{state | root_binding: nil}
            end

          reply =
            with {:ok, binding} <- result do
              contracts =
                Enum.map(state.contracts, fn contract ->
                  %{
                    contract
                    | backend_context:
                        Map.put(contract.backend_context, :session_binding, binding)
                  }
                end)

              with {:ok, native_context} <- native_context(state, binding) do
                {:ok, %{contracts: contracts, binding: binding, native_context: native_context}}
              end
            end

          if state.closing do
            GenServer.reply(from, failure(:resource_conflict, "subagent admission is closing"))
            start_close(state)
          else
            GenServer.reply(from, reply)
            {:noreply, state}
          end

        {{nil, kind}, jobs} when kind in [:close, :close_execution] ->
          Process.demonitor(ref, [:flush])
          {execution, result, snapshot, retirements} = result
          state = %{state | jobs: jobs, closing: false, child_retirements: retirements}
          state = if state.manager, do: reconcile_snapshot(state, snapshot), else: state
          retired = child_retirement_result(retirements)

          state =
            if match?({:ok, %{status: :confirmed}}, execution) and retired == :ok,
              do: %{
                state
                | execution_closed: true,
                  execution_result: execution,
                  archive_result:
                    if(kind == :close, do: result, else: pending_archive(state.archive_result)),
                  generation_closed:
                    state.generation_closed or
                      (kind == :close and match?({:ok, %{status: :confirmed}}, result)),
                  error: if(state.error == :cleanup_unconfirmed, do: nil, else: state.error)
              },
              else: mark_unknown(%{state | error: :cleanup_unconfirmed}, "cleanup_unconfirmed")

          execution_reply =
            if(match?({:ok, %{status: :confirmed}}, execution) and retired == :ok,
              do: execution,
              else:
                if(state.error,
                  do:
                    {:error,
                     Error.new(:unknown_outcome, "subagent cleanup requires reconciliation",
                       cause: %{generation: execution, child_retirements: retirements}
                     )},
                  else: execution
                )
            )

          state =
            reply_execution_closes(%{state | execution_result: execution_reply}, execution_reply)

          reply =
            if(state.error,
              do:
                {:error,
                 Error.new(:unknown_outcome, "subagent cleanup requires reconciliation",
                   cause: %{generation: result, child_retirements: retirements}
                 )},
              else: result
            )

          cond do
            kind == :close -> {:noreply, reply_closes(state, reply)}
            not state.execution_closed -> {:noreply, reply_closes(state, execution_reply)}
            state.close_waiters != [] -> start_close(%{state | closing: true})
            true -> {:noreply, state}
          end

        {{nil, :resync}, jobs} ->
          Process.demonitor(ref, [:flush])
          state = %{state | jobs: jobs}
          state = reconcile_snapshot(state, result)
          if state.observer_buffer == [], do: {:noreply, state}, else: resync(state)
      end

    finish_shutdown_stages(finished)
  end

  def handle_info(
        {:codex_collaboration, %{manager_id: manager_id} = event},
        %{preparing: true, manager_id: previous_manager_id} = state
      )
      when manager_id != previous_manager_id,
      do: {:noreply, %{state | observer_buffer: [event | state.observer_buffer]}}

  def handle_info({:codex_collaboration, event}, state) do
    cond do
      state.manager_id != nil and event.manager_id != state.manager_id ->
        {:noreply, state}

      event.revision <= state.manager_revision ->
        {:noreply, state}

      event.revision != state.manager_revision + 1 ->
        resync(%{state | observer_buffer: [event | state.observer_buffer]})

      true ->
        state = %{state | manager_id: event.manager_id, manager_revision: event.revision}
        {:noreply, observe(state, event)}
    end
  end

  def handle_info({:upstream_cancel_result, scope, result}, state) do
    notify(state, {:upstream_cancel_status, scope, result})
    {:noreply, state}
  end

  def handle_info({:subagent_activity, identity, activity}, state) do
    activity =
      case activity do
        :streaming_provider ->
          :waiting_model

        :running_tools ->
          :waiting_tool

        :waiting_permission ->
          :waiting_approval

        :waiting_user_input ->
          :waiting_approval

        phase when phase in [:waiting_model, :waiting_tool, :waiting_approval, :waiting_agent] ->
          phase

        _ ->
          :unknown
      end

    # Activity is optional observation; roster revisions still come only from
    # acknowledged lifecycle facts, never from provider text or tool guesses.
    {:noreply, child_activity(state, identity, activity)}
  end

  def handle_info({:child_interaction_error, correlation, reason}, state) do
    Logger.warning("[Sigma.Agent.Subagents] Native child interaction failed: #{inspect(reason)}")

    notify(state, {:subagent_interaction_error, correlation, reason})
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    finished =
      case Map.pop(state.jobs, ref) do
        {{nil, :close}, jobs} when state.execution_closed ->
          result =
            {:error,
             Error.new(:unknown_outcome, "subagent archive completion did not acknowledge",
               cause: reason
             )}

          state = %{state | jobs: jobs, archive_result: result}
          {:noreply, reply_closes(state, result)}

        {{from, kind}, jobs} ->
          Logger.error(
            "[Sigma.Agent.Subagents] Control job #{inspect(kind)} crashed: #{inspect(reason)}"
          )

          if from,
            do:
              GenServer.reply(
                from,
                failure(:execution_failure, "subagent control operation failed", cause: reason)
              )

          state = %{state | jobs: jobs, preparing: false, error: :control_failed}

          state =
            if kind == :close or state.closing,
              do:
                reply_closes(
                  state,
                  failure(:unknown_outcome, "subagent control operation failed")
                ),
              else: state

          {:noreply, state}

        {nil, _} ->
          ids = for {id, item} <- state.pending, item.monitor == ref, do: id
          {:noreply, Enum.reduce(ids, state, &forget_question(&2, &1))}
      end

    finish_shutdown_stages(finished)
  end

  def handle_info({:EXIT, pid, :normal}, %{closing: true, lifetime_recovery: pid} = state),
    do: {:noreply, state}

  def handle_info({:EXIT, pid, _reason}, state)
      when pid == state.manager or pid == state.session or pid == state.lifetime_recovery,
      do: {:noreply, mark_unknown(%{state | error: :runtime_down}, "runtime_down")}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_pid(state.session) and not state.generation_closed do
      task = Task.async(fn -> runtime_call(fn -> close_generation(state) end) end)
      result = Task.yield(task, 6_000) || Task.shutdown(task, :brutal_kill)

      unless match?({:ok, {:ok, %{status: :confirmed}}}, result) do
        Logger.error(
          "[Sigma.Agent.Subagents] Shutdown cleanup is unconfirmed: #{inspect(result)}"
        )
      end
    end

    owners =
      [
        state.interaction_responder,
        state.codex_resources,
        state.session,
        state.manager,
        state.lifetime_recovery
      ] ++
        Enum.map(state.children, fn {_id, child} -> child.io end)

    deadline = System.monotonic_time(:millisecond) + 2_500

    Enum.reduce_while(owners, :ok, fn pid, :ok ->
      remaining = deadline - System.monotonic_time(:millisecond)

      cond do
        not is_pid(pid) or not Process.alive?(pid) ->
          {:cont, :ok}

        remaining <= 0 ->
          Logger.error("[Sigma.Agent.Subagents] Shutdown owner stop failed: deadline exceeded")
          {:halt, :ok}

        true ->
          case runtime_call(fn -> GenServer.stop(pid, :shutdown, remaining) end) do
            :ok ->
              :ok

            error ->
              Logger.error(
                "[Sigma.Agent.Subagents] Shutdown owner stop failed: #{inspect(error)}"
              )
          end

          {:cont, :ok}
      end
    end)
  end

  defp job(state, from, kind, fun) do
    task = Task.async(fun)
    {:noreply, %{state | jobs: Map.put(state.jobs, task.ref, {from, kind})}}
  end

  defp start_close(state) do
    if state.codex_resources, do: Process.unlink(state.session)
    if state.lifetime_recovery, do: Process.unlink(state.lifetime_recovery)

    # Publish execution acknowledgements before starting any archive work, even
    # when the first caller requested full closure. Concurrent execution-only
    # callers must never depend on a later archive or owner-retirement result.
    kind = if state.execution_closed, do: :close, else: :close_execution
    host = self()

    job(state, nil, kind, fn ->
      {execution, retirements} =
        if state.execution_closed do
          {state.execution_result, state.child_retirements}
        else
          initial = runtime_call(fn -> close_generation(state) end)
          retirements = retire_children(state)

          execution =
            with :ok <- child_retirement_result(retirements) do
              if state.lifetime_recovery,
                do: reconcile_generation(state, initial),
                else: initial
            end

          {execution, retirements}
        end

      result =
        if kind == :close,
          do: complete_generation(host, state, execution),
          else: execution

      snapshot = if state.manager, do: runtime_call(fn -> MultiAgent.snapshot(state.manager) end)
      {execution, result, snapshot, retirements}
    end)
  end

  defp pending_archive({:error, _} = error), do: error
  defp pending_archive(_previous), do: :pending

  defp complete_generation(_host, %{lifetime_recovery: nil}, result), do: result

  defp complete_generation(host, state, {:ok, %{status: :confirmed}} = execution) do
    case state.completion_stage do
      :pending ->
        with :ok <- LifetimeEvidence.finalize(state.lifetime_recovery, state.manager),
             :ok <- refresh_root_session(state),
             :ok <- ChildArchiveEvidence.finalize(state.lifetime_recovery, state.manager) do
          completion_advanced(host, state, :archived, execution)
        end

      :archived ->
        with :ok <- stop_retained_session(state),
             do: completion_advanced(host, state, :session_stopped, execution)

      :session_stopped ->
        with :ok <- LifetimeRecovery.retire(state.lifetime_recovery),
             do: completion_advanced(host, state, :completed, execution)

      :completed ->
        execution
    end
  end

  defp complete_generation(_host, _state, execution), do: execution

  defp completion_advanced(host, state, stage, execution) do
    # A later owner failure must not erase an already acknowledged archive or
    # make a retry read a Session that this job has successfully stopped.
    send(host, {:generation_completion, state.generation, stage})
    complete_generation(host, %{state | completion_stage: stage}, execution)
  end

  defp refresh_root_session(%{root_binding: nil}), do: :ok

  defp refresh_root_session(state) do
    with {:ok, manifests} <- LifetimeRecovery.manifests(state.lifetime_recovery) do
      captured? =
        Enum.any?(manifests, fn {_reference, manifest} ->
          manifest["subject"]["kind"] == "session" and
            Enum.any?(manifest["run_refs"], fn reference ->
              reference["store_ref"] == "root" and
                reference["run_id"] == state.root_binding.run_id
            end)
        end)

      if captured?, do: capture_root_session(state), else: :ok
    end
  end

  # A normal public close remains sufficient for ordinary and genuinely
  # pre-execution generations. It is not a Reconciliation receipt and does not
  # authorize recovery of an unknown historical run. In particular, a failed
  # Goal preparation has no Conversation record for a Session manifest.
  defp reconcile_generation(state, {:ok, %{status: :confirmed}} = initial) do
    with {:ok, required?} <- unknown_root?(state) do
      if required? do
        # A cancelled provider-only Conversation may leave a terminal unknown
        # run even when native Session.close itself succeeded. Capture its
        # public ownership ACKs while this exact Session is still available.
        with :ok <- LifetimeEvidence.finalize(state.lifetime_recovery, state.manager),
             :ok <- capture_root_session(state),
             do: initial
      else
        initial
      end
    end
  end

  defp reconcile_generation(state, _initial) do
    with :ok <- LifetimeEvidence.finalize(state.lifetime_recovery, state.manager),
         :ok <- capture_root_session(state),
         do: close_generation(state)
  end

  defp unknown_root?(%{lifetime_recovery: nil}), do: {:ok, false}
  defp unknown_root?(%{root_binding: nil}), do: {:ok, false}

  defp unknown_root?(state) do
    case Store.load(state.root.store, state.root_binding.run_id) do
      {:ok, %{run: run}} -> {:ok, run.state == :unknown_outcome}
      {:error, %Error{class: :not_found}} -> {:ok, false}
      {:error, _} = error -> error
    end
  end

  defp stop_retained_session(%{session: session}) do
    if is_pid(session) and Process.alive?(session),
      do: GenServer.stop(session, :normal),
      else: :ok
  end

  defp capture_root_session(%{codex_resources: resources}) when is_pid(resources),
    do: resources |> CodexResources.retirement_context() |> LifetimeEvidence.capture_session()

  defp capture_root_session(_state), do: :ok

  defp retire_children(state) do
    Map.new(state.children, fn {id, child} ->
      result =
        case state.child_retirements[id] do
          {:ok, %{status: :confirmed}} = confirmed -> confirmed
          _ -> retire_child(child.io)
        end

      {id, result}
    end)
  end

  defp retire_child(io) do
    case ChildIO.retire(io) do
      {:ok, %{status: :confirmed}} = confirmed ->
        GenServer.stop(io, :normal)
        confirmed

      error ->
        error
    end
  catch
    :exit, reason -> {:error, {:child_retirement_unconfirmed, reason}}
  end

  defp child_retirement_result(retirements) do
    failed =
      Map.reject(retirements, fn {_id, result} ->
        match?({:ok, %{status: :confirmed}}, result)
      end)

    if map_size(failed) == 0,
      do: :ok,
      else:
        {:error,
         Error.new(:unknown_outcome, "child host retirement requires reconciliation",
           cause: failed
         )}
  end

  defp close_generation(%{codex_resources: resources}) when is_pid(resources),
    do: CodexResources.close(resources)

  defp close_generation(state), do: Session.close(state.session)

  defp native_context(%{codex_resources: nil}, _binding), do: {:ok, nil}
  defp native_context(state, binding), do: CodexResources.context(state.codex_resources, binding)

  defp runtime_call(fun) do
    fun.()
  catch
    :exit, _ -> failure(:unknown_outcome, "subagent owner is unavailable")
  end

  defp reply_closes(state, result) do
    Enum.each(state.close_waiters, &GenServer.reply(&1, result))
    reply_execution_closes(%{state | close_waiters: [], closing: false}, result)
  end

  defp reply_execution_closes(state, result) do
    Enum.each(state.execution_close_waiters, &GenServer.reply(&1, result))
    %{state | execution_close_waiters: []}
  end

  defp prepare_generation(host, state, context) do
    Process.flag(:trap_exit, true)
    runtime_generation(host, state, context)
  end

  defp runtime_generation(host, %{generation_closed: true} = state, context) do
    with :ok <- retire_generation(state), do: new_generation(host, state, context)
  end

  defp runtime_generation(host, %{session: session} = state, context) when is_pid(session) do
    case Session.status(session) do
      %{phase: :idle} ->
        {:ok,
         Map.take(state, [
           :generation,
           :session,
           :manager,
           :contracts,
           :codex_resources,
           :lifetime_recovery,
           :archive_aliases,
           :restored_children
         ])}

      %{phase: :closed, cleanup: {:ok, %{status: :confirmed}}} ->
        case close_generation(state) do
          {:ok, %{status: :confirmed}} = closed ->
            with {:ok, %{status: :confirmed}} <- complete_generation(host, state, closed),
                 :ok <- retire_generation(state),
                 do: new_generation(host, state, context)

          error ->
            error
        end

      _ ->
        failure(:unknown_outcome, "previous subagent generation is not settled")
    end
  end

  defp runtime_generation(host, state, context), do: new_generation(host, state, context)

  defp new_generation(host, state, context) do
    generation = unique()

    with {:ok, recovery} <- start_lifetime_recovery(state, context),
         {:ok, session, resources} <- start_lifetime_session(host, context, recovery) do
      result =
        if state.enabled and state.writer != nil do
          start_manager(host, state, context, generation, session, recovery)
        else
          {:ok,
           %{
             generation: generation,
             session: session,
             manager: nil,
             contracts: [],
             interaction_responder: nil,
             manager_id: nil,
             archive_aliases: %{},
             restored_children: %{}
           }}
        end

      result =
        if match?({:error, _}, result) do
          stop_owner(resources || session)

          case if(recovery, do: LifetimeRecovery.retire(recovery), else: :ok) do
            :ok -> result
            {:error, _} = error -> error
          end
        else
          result
        end

      case result do
        {:ok, runtime} ->
          {:ok,
           Map.merge(runtime, %{
             codex_resources: resources,
             lifetime_recovery: recovery,
             generation_closed: false,
             execution_closed: false,
             execution_result: nil,
             archive_result: :not_started,
             completion_stage: :pending
           })}

        error ->
          error
      end
    end
  end

  defp start_lifetime_recovery(%{writer: writer, transcript_path: path} = state, %{
         config: %{native_tools: true} = config
       })
       when not is_nil(writer) and is_binary(path) do
    with {:ok, header} <- root_header_id(writer, config.cwd),
         {:ok, recovery} <-
           LifetimeRecovery.start_link(
             transcript: state.transcript_path,
             # The journal header survives rename/adopt. Route session names
             # belong to each manager's admission, not the transcript writer.
             root_header_id: header
           ) do
      Process.unlink(recovery)
      {:ok, recovery}
    end
  end

  defp start_lifetime_recovery(_state, _context), do: {:ok, nil}

  defp start_lifetime_session(host, context, recovery) do
    case start_generation_session(host, context, recovery) do
      {:ok, _, _} = result ->
        result

      {:error, _} = failure ->
        case if(recovery, do: LifetimeRecovery.retire(recovery), else: :ok) do
          :ok -> failure
          {:error, _} = error -> error
        end
    end
  end

  defp start_generation_session(host, %{config: %{native_tools: true} = config}, recovery) do
    with {:ok, resources} <-
           CodexResources.start_link(
             workspace: config.cwd,
             owner_pid: host,
             plugins: config[:native_plugins],
             archive: config[:native_archive],
             host_retirement: config[:host_retirement],
             lifetime_recovery: if(recovery, do: %{writer: recovery, store_ref: "root"}),
             memory_root:
               Map.get(config, :native_memory_root) ||
                 Path.join(apply(Sigma.Session.ConfigManager, :agent_dir, []), "memories")
           ) do
      Process.unlink(resources)
      {:ok, CodexResources.session(resources), resources}
    end
  end

  defp start_generation_session(host, _context, _recovery) do
    with {:ok, session} <- Session.start_link(owner_pid: host) do
      Process.unlink(session)
      {:ok, session, nil}
    end
  end

  defp retire_generation(state) do
    with :ok <- child_retirement_result(retire_children(state)) do
      stop_owner(state.interaction_responder)
      stop_owner(state.manager)
      stop_owner(state.codex_resources || state.session)
      :ok
    end
  end

  defp start_manager(host, state, context, generation, session, recovery) do
    recovery_options =
      if recovery,
        do: [
          recovery: LifetimeRecovery.configuration(recovery),
          recovery_scope_id: LifetimeRecovery.scope(recovery),
          root_agent_id: state.root_session_id
        ],
        else: []

    case MultiAgent.start_link(
           [
             parent_run_id: context.authority.run_id,
             parent_name: "/root",
             parent_authority: context.authority,
             subscriber: host,
             max_concurrent_threads_per_session: state.max_threads,
             child_options: fn request, run_id, parent ->
               GenServer.call(
                 host,
                 {:child_options, generation, request, run_id, parent},
                 :infinity
               )
             end,
             admission_receipt: fn receipt ->
               GenServer.call(host, {:receipt, generation, receipt}, :infinity)
             end
           ] ++ recovery_options
         ) do
      {:ok, manager} ->
        Process.unlink(manager)

        result =
          try do
            # Cache before exposing the generation; admission callbacks cannot
            # synchronously call back into the manager.
            contracts =
              Enum.map(MultiAgent.contracts(:v2, manager), fn contract ->
                %{
                  contract
                  | backend: Sigma.Agent.Backplane.CollaborationBackend,
                    backend_context: Map.put(contract.backend_context, :host, host)
                }
              end)

            with {:ok, restored} <-
                   ChildArchiveEvidence.restore(recovery, manager, state.roster.agents),
                 {:ok, snapshot} <- MultiAgent.snapshot(manager),
                 {:ok, responder} <- start_interaction_responder(host, state, manager) do
              {:ok,
               %{
                 generation: generation,
                 session: session,
                 manager: manager,
                 interaction_responder: responder,
                 contracts: contracts,
                 manager_id: snapshot.manager_id,
                 initial_snapshot: snapshot,
                 restored_children: restored,
                 archive_aliases:
                   Map.new(restored, fn {_name, archive} ->
                     {archive["child_identity"]["agent_id"], archive["host_metadata"]["agent_id"]}
                   end)
               }}
            end
          catch
            :exit, _ -> failure(:execution_failure, "subagent manager startup failed")
          end

        if match?({:error, _}, result), do: stop_owner(manager)
        result

      error ->
        error
    end
  end

  defp stop_owner(pid) when is_pid(pid) do
    Process.unlink(pid)
    if Process.alive?(pid), do: GenServer.stop(pid, :shutdown)
  catch
    :exit, _ -> :ok
  end

  defp stop_owner(_pid), do: :ok

  defp start_interaction_responder(host, state, manager) do
    if Map.get(state.root.config, :native_tools, false) or
         Keyword.get(state.root.config.dispatcher_opts, :native_child_interactions, false) do
      request = fn correlation, request, current? ->
        with true <- current?.(),
             {:ok, handler} <-
               GenServer.call(
                 host,
                 {:native_interaction_handler, correlation, request.kind}
               ) do
          handler.(request, current?)
        else
          false -> {:error, :stale_subagent_request}
          {:error, _} = error -> error
        end
      end

      with {:ok, responder} <-
             ChildInteractionResponder.start_link(
               owner_pid: host,
               subscriber: host,
               request_fn: request
             ) do
        case ChildInteractionResponder.attach(responder, manager) do
          :ok ->
            Process.unlink(responder)
            {:ok, responder}

          error ->
            GenServer.stop(responder, :normal)
            error
        end
      end
    else
      {:ok, nil}
    end
  end

  defp native_interaction_handler(state, identity, :request_user_input) do
    case child_callbacks(state)[:ask_user_question_fn] do
      callback when is_function(callback, 3) ->
        {:ok, UserInput.resolver(fn request, opts -> callback.(identity, request, opts) end)}

      _ ->
        {:error, :user_input_handler_unavailable}
    end
  end

  defp native_interaction_handler(state, identity, :sigma_tool_permission) do
    case child_callbacks(state)[:permission_request_fn] do
      callback when is_function(callback, 2) ->
        {:ok, fn %{tool_call: call}, _current? -> callback.(identity, call) end}

      _ ->
        {:error, :permission_handler_unavailable}
    end
  end

  defp native_interaction_handler(state, identity, :permission) do
    case Keyword.get(state.root.config.dispatcher_opts, :runtime_permission_request_fn) do
      callback when is_function(callback, 2) ->
        source =
          Map.take(
            identity,
            [:agent_id, :agent_path, :child_session_id, :public_run_id, :incarnation]
          )

        {:ok, fn request, current? -> callback.(Map.put(request, :source, source), current?) end}

      _ ->
        {:error, :runtime_permission_handler_unavailable}
    end
  end

  defp native_interaction_handler(_state, _identity, _kind),
    do: {:error, :unsupported_interaction_request}

  defp adopt_generation(%{generation: generation} = state, %{generation: generation}), do: state

  defp adopt_generation(state, runtime) do
    if is_pid(state.interaction_responder), do: stop_owner(state.interaction_responder)

    buffered = Enum.filter(state.observer_buffer, &(&1.manager_id == runtime.manager_id))

    state =
      Map.merge(state, runtime)
      |> Map.merge(%{
        children: %{},
        child_retirements: %{},
        attempts: %{},
        manager_revision: 0,
        observer_buffer: buffered,
        origins: %{},
        root_binding: nil,
        error: nil
      })

    state =
      Enum.reduce(state.roster.agents, state, fn row, acc ->
        row =
          if row.status in @terminal or
               (row.status == :unknown_outcome and
                  retired_roster?(state.writer, state.transcript_path, [row])),
             do: row,
             else: %{
               row
               | status: :unknown_outcome,
                 activity: nil,
                 closure: :unknown,
                 reason: "owner_restart"
             }

        commit_fact(acc, :recovered, row)
      end)

    case runtime[:initial_snapshot] do
      nil -> state
      snapshot -> reconcile_snapshot(state, {:ok, snapshot})
    end
  end

  defp prepare_child(state, request, run_id, parent) do
    child = parent.child
    agent_id = qualify(state, child.agent_id)
    existing = state.children[agent_id]
    restored = state.restored_children[child.name]
    original = if restored, do: restored["host_metadata"]["sigma_identity"], else: %{}

    child_session =
      cond do
        existing -> existing.identity.child_session_id
        restored -> restored["host_metadata"]["child_session_id"]
        true -> "child_" <> unique()
      end

    parent_id =
      if parent.name == "/root",
        do: state.root_session_id,
        else: parent_identity(state, parent.name)

    origin = state.origins[parent.run_id] || %{tool_call_id: "admission_" <> child.attempt_id}

    identity = %{
      agent_id: agent_id,
      agent_type: request.options["agent_type"] || "default",
      parent_transcript_path: parent_transcript_path(state, parent.name),
      agent_path: child.name,
      child_session_id: child_session,
      root_session_id: state.root_session_id,
      parent_agent_id: parent_id,
      observer_incarnation: state.generation,
      run_id: run_id,
      public_run_id: qualify(state, run_id),
      incarnation: child.incarnation,
      origin_turn_id:
        if(existing,
          do: existing.identity.origin_turn_id,
          else: original["origin_turn_id"] || root_turn(state, parent)
        ),
      origin_tool_call_id:
        if(existing,
          do: existing.identity.origin_tool_call_id,
          else: original["origin_tool_call_id"] || origin.tool_call_id
        ),
      depth: length(String.split(child.name, "/", trim: true)) - 1
    }

    attempt = %{
      identity: identity,
      runtime: child,
      request: request,
      status: :reserved,
      process_started: false
    }

    attrs = admission(state, attempt, :intent)

    case apply(Writer, :append, [state.writer, {:subagent_admission, attrs}]) do
      {:ok, _} ->
        state = %{state | attempts: Map.put(state.attempts, child.attempt_id, attempt)}

        with :ok <- child_configuration(request, state.root.config),
             {:ok, messages} <- fork_messages(state, request, parent, existing),
             {:ok, io, prepared} <-
               prepare_child_io(state, identity, existing, messages, parent.authority) do
          item = %{identity: identity, io: io}
          state = %{state | children: Map.put(state.children, agent_id, item)}
          {:ok, metadata} = ChildIO.metadata(io)

          options =
            Keyword.put(prepared.options, :host_metadata, %{
              child_session_id: child_session,
              agent_id: agent_id,
              transcript_path: metadata.transcript_path,
              sigma_identity: identity
            })

          with {:ok, options} <- lifetime_child_options(state, child, request, options, metadata) do
            state =
              update_in(
                state.attempts[child.attempt_id],
                &Map.put(&1, :executor_name, options[:name])
              )

            {{:ok, options}, state}
          else
            {:error, _} = error -> {error, state}
          end
        else
          {:error, %Error{}} = error ->
            {error, state}

          {:error, cause} ->
            {{:error, Error.new(:execution_failure, "child IO preparation failed", cause: cause)},
             state}
        end

      {:error, _} ->
        {failure(:execution_failure, "subagent intent could not be persisted"),
         %{state | error: :storage_failed}}
    end
  end

  defp refresh_recovery_gate(%{error: :recovery_required} = state) do
    uncertain =
      Enum.filter(state.roster.agents, &(&1.status == :unknown_outcome or &1.closure == :unknown))

    complete =
      Enum.all?(state.recovered_admissions, fn {_id, attempt} ->
        attempt.receipts != [] and
          (not List.last(attempt.receipts).process_started or
             Enum.any?(state.roster.agents, &(&1.agent_id == attempt.intent.agent_id)))
      end)

    if complete and uncertain != [] and
         retired_roster?(state.writer, state.transcript_path, uncertain),
       do: %{state | error: nil},
       else: state
  end

  defp refresh_recovery_gate(state), do: state

  defp lifetime_child_options(%{lifetime_recovery: nil}, _child, _request, options, _metadata),
    do: {:ok, options}

  defp lifetime_child_options(state, child, request, options, metadata) do
    configuration = %{
      provider: to_string(state.root.config.provider),
      model: model_id(state.root.config.model),
      cwd: state.root.config.cwd,
      system_prompt: state.root.config.system_prompt,
      request_options: request.options
    }

    with {:ok, reference} <-
           LifetimeRecovery.admit(
             state.lifetime_recovery,
             child.recovery_identity,
             request,
             options,
             metadata,
             configuration
           ),
         do: {:ok, Keyword.put(options, :recovery_admission_ref, reference)}
  end

  defp retired_roster?(writer, transcript, rows)
       when not is_nil(writer) and is_binary(transcript) do
    with {:ok, %{entries: entries}} <- apply(Writer, :selected_journal, [writer]),
         %{"id" => header} <- Enum.find(entries, &(&1["type"] == "session")),
         do: LifetimeEvidence.retired_roster?(transcript, header, rows),
         else: (_ -> false)
  end

  defp retired_roster?(_writer, _transcript, _rows), do: false

  defp closed_roster?(writer, transcript, rows)
       when not is_nil(writer) and is_binary(transcript) do
    with {:ok, %{entries: entries}} <- apply(Writer, :selected_journal, [writer]),
         %{"id" => header} <- Enum.find(entries, &(&1["type"] == "session")),
         do: LifetimeEvidence.closed_roster?(transcript, header, rows),
         else: (_ -> false)
  end

  defp closed_roster?(_writer, _transcript, _rows), do: false

  defp parent_transcript_path(state, "/root"), do: state.transcript_path

  defp parent_transcript_path(state, name) do
    Enum.find_value(state.children, fn {_id, child} ->
      if child.identity.agent_path == name do
        {:ok, metadata} = ChildIO.metadata(child.io)
        metadata.transcript_path
      end
    end)
  end

  defp prepare_child_io(state, identity, existing, messages, authority) do
    with {:ok, io} <- child_io(state, identity, existing, messages) do
      opts =
        [messages: messages, config: state.root.config]
        |> Keyword.merge(child_callbacks(state))

      case ChildIO.prepare(io, identity, authority, state.contracts, opts) do
        {:ok, prepared} ->
          {:ok, io, prepared}

        error ->
          if is_nil(existing), do: GenServer.stop(io, :normal)
          error
      end
    end
  end

  defp child_io(_state, _identity, %{io: io}, _messages), do: {:ok, io}

  defp child_io(state, identity, nil, messages) do
    root_config = state.root.config
    directory = Path.join(state.transcript_path <> ".subagents", identity.child_session_id)
    host = self()

    with :ok <- File.mkdir_p(directory),
         {:ok, root_header_id} <- root_header_id(state.writer, root_config.cwd) do
      ChildIO.start_link(
        [
          config: root_config,
          identity: identity,
          root_header_id: root_header_id,
          lifetime_recovery: state.lifetime_recovery,
          messages: messages,
          transcript_path: Path.join(directory, "session.jsonl"),
          backplane_store_path: Path.join(directory, "runtime"),
          notify: fn identity, phase -> send(host, {:subagent_activity, identity, phase}) end
        ] ++ child_callbacks(state)
      )
    end
  end

  defp root_header_id(writer, cwd) do
    with result when result == :ignored or (is_tuple(result) and elem(result, 0) == :ok) <-
           apply(Writer, :append, [writer, {:agent_start, cwd}]),
         {:ok, %{entries: entries}} <- apply(Writer, :selected_journal, [writer]) do
      case Enum.filter(entries, &(&1["type"] == "session")) do
        [%{"id" => id}] when is_binary(id) and id != "" -> {:ok, id}
        _ -> failure(:malformed_result, "root session requires one immutable header")
      end
    end
  end

  defp child_callbacks(state) do
    host = self()
    opts = state.root.config.dispatcher_opts
    interactive = Keyword.get(opts, :interactive_approvals, false)
    permission_resolver = Keyword.get(opts, :permission_request_fn)
    question_resolver = Keyword.get(opts, :ask_user_question_fn)

    permission =
      if permission_resolver do
        resolver = if interactive, do: nil, else: permission_resolver
        fn identity, call -> permission(host, identity, call, resolver) end
      end

    question =
      if question_resolver do
        fn identity, request, tool_opts ->
          resolver =
            if not interactive do
              fn registered ->
                case Function.info(question_resolver, :arity) do
                  {:arity, 1} -> question_resolver.(registered)
                  {:arity, 2} -> question_resolver.(registered, tool_opts)
                end
              end
            end

          ask(host, identity, request, Keyword.put(tool_opts, :resolver, resolver))
        end
      end

    [permission_request_fn: permission, ask_user_question_fn: question]
  end

  defp permission(host, identity, call, resolver) do
    request = %{
      kind: :permission,
      question: "Allow #{call.name} for this tool call?",
      tool_call_id: call.id,
      arguments: call.arguments,
      options: [
        %{label: "Allow once", value: "allow_once"},
        %{label: "Deny once", value: "deny_once"}
      ],
      allow_freeform: false
    }

    opts =
      if resolver,
        do: [resolver: fn registered -> resolver.(Map.put(call, :source, registered.source)) end],
        else: []

    case ask(host, identity, request, opts) do
      {:ok, "allow_once"} -> :allow
      {:ok, "deny_once"} -> {:deny, :denied_once}
      :allow -> :allow
      {:allow, patch} when is_map(patch) -> {:allow, patch}
      {:deny, _} = denied -> denied
      {:error, reason} -> {:deny, reason}
      _ -> {:deny, :invalid_approval_response}
    end
  end

  defp commit_receipt(state, receipt) do
    case state.attempts[receipt.attempt_id] do
      nil ->
        {failure(:not_found, "admission intent is unavailable"), state}

      attempt ->
        row = Enum.find(state.roster.agents, &(&1.agent_id == attempt.identity.agent_id))

        facts =
          if receipt.status == :created and row == nil,
            do: [fact(state, :registered, initial_row(state, attempt))],
            else: []

        attrs =
          admission(state, attempt, :receipt)
          |> Map.merge(
            Map.take(receipt, [:status, :process_started, :receipt_acknowledged, :reason])
          )
          |> Map.put(:facts, facts)

        case apply(Writer, :append, [state.writer, {:subagent_admission, attrs}]) do
          {:ok, _} ->
            state = apply_committed(state, facts)

            attempt = %{
              attempt
              | status: receipt.status,
                process_started: receipt.process_started
            }

            state = %{state | attempts: Map.put(state.attempts, receipt.attempt_id, attempt)}

            executor =
              if state.lifetime_recovery && receipt.status == :created,
                do:
                  LifetimeRecovery.observe_executor(
                    state.lifetime_recovery,
                    attempt.identity,
                    attempt.executor_name
                  ),
                else: :ok

            cleanup = with :ok <- executor, do: cleanup_unstarted_child(state, attempt)

            case cleanup do
              :ok -> {:ok, state}
              {:error, _} = error -> {error, %{state | error: :cleanup_unconfirmed}}
            end

          {:error, _} ->
            {failure(:execution_failure, "subagent receipt could not be persisted"),
             %{state | error: :storage_failed}}
        end
    end
  end

  defp cleanup_unstarted_child(state, %{
         status: status,
         process_started: false,
         identity: identity
       })
       when status in [:rejected, :failed] do
    case state.children[identity.agent_id] do
      %{identity: ^identity, io: io} ->
        case ChildIO.reject_preparation(io, {identity.run_id, identity.incarnation}) do
          {:ok, %{status: :confirmed}} -> :ok
          {:error, _} = error -> error
        end

      _ ->
        :ok
    end
  end

  defp cleanup_unstarted_child(_state, _attempt), do: :ok

  defp admission(state, attempt, phase) do
    id = attempt.identity

    %{
      phase: phase,
      attempt_id: qualify(state, attempt.runtime.attempt_id),
      observer_incarnation: state.generation,
      agent_id: id.agent_id,
      run_id: id.public_run_id,
      incarnation: id.incarnation,
      name: id.agent_path,
      child_session_id: id.child_session_id,
      metadata: %{
        "activation" => to_string(attempt.runtime.activation),
        "runtime_agent_id" => attempt.runtime.agent_id,
        "runtime_run_id" => id.run_id,
        "parent_agent_id" => id.parent_agent_id,
        "root_session_id" => id.root_session_id,
        "origin_turn_id" => id.origin_turn_id,
        "origin_tool_call_id" => id.origin_tool_call_id,
        "task" => attempt.request.message,
        "depth" => id.depth
      },
      facts: []
    }
  end

  defp initial_row(state, attempt) do
    id = attempt.identity

    Map.take(id, [
      :agent_id,
      :agent_path,
      :child_session_id,
      :root_session_id,
      :parent_agent_id,
      :origin_turn_id,
      :origin_tool_call_id,
      :incarnation,
      :depth
    ])
    |> Map.merge(%{
      run_id: id.public_run_id,
      task: attempt.request.message,
      agent_type: attempt.request.options["agent_type"] || "default",
      model: model_id(state.root.config.model),
      status: :pending_init,
      activity: nil,
      closure: :open,
      created_at: now(),
      started_at: nil,
      finished_at: nil,
      reason: nil
    })
  end

  defp observe(state, %{agent: agent} = event) do
    Sigma.Ai.ManagedCancellation.observe(event, self(), fn run_id -> qualify(state, run_id) end)

    id = qualify(state, agent.agent_id)
    row = Enum.find(state.roster.agents, &(&1.agent_id == id))
    original = get_in(agent.host_metadata, ["sigma_identity", "public_run_id"])

    run_id =
      if Map.get(agent, :archived, false) and is_binary(original),
        do: original,
        else: qualify(state, agent.run_id)

    if row do
      status =
        if agent.status == :closed and row.status in @terminal,
          do: row.status,
          else: runtime_status(agent.status)

      status =
        if status == :unknown_outcome and row.status in @terminal, do: row.status, else: status

      reconciled = not is_nil(Map.get(agent, :retirement_receipt_ref))

      status =
        if reconciled and row.status in (@terminal ++ [:unknown_outcome]),
          do: row.status,
          else: status

      data = %{
        agent_id: id,
        run_id: run_id,
        incarnation: if(reconciled, do: row.incarnation, else: agent.incarnation),
        status: status,
        reason: agent.reason,
        activity: if(status == :running, do: row.activity),
        closure:
          if(agent.cleanup == :confirmed,
            do: :closed,
            else: if(agent.cleanup == :uncertain, do: :unknown, else: :open)
          )
      }

      cond do
        status == :pending_init ->
          state

        status == :running and (row.run_id != run_id or row.status != :running) ->
          commit_fact(
            state,
            :run_started,
            Map.merge(data, %{started_at: now(), finished_at: nil})
          )

        status == :unknown_outcome or data.closure == :unknown ->
          state = commit_fact(state, :recovered, data)
          invalidate_questions(state, &(&1.identity.agent_id == id))

        status in @terminal and (row.run_id != run_id or row.status not in @terminal) ->
          # Startup can fail after a confirmed process birth but before :started.
          state =
            if row.run_id != run_id,
              do:
                commit_fact(state, :run_started, %{
                  agent_id: id,
                  run_id: run_id,
                  incarnation: agent.incarnation,
                  status: :running
                }),
              else: state

          state = commit_fact(state, :run_finished, Map.put(data, :finished_at, now()))
          invalidate_questions(state, &(&1.identity.agent_id == id))

        data.closure == :closed and row.closure != :closed ->
          commit_fact(state, :closed, %{data | status: row.status})

        true ->
          state
      end
    else
      state
    end
  end

  defp observe(state, _event), do: state

  defp runtime_status(:created), do: :pending_init
  defp runtime_status(:closed), do: :shutdown

  defp runtime_status(status)
       when status in [:running, :completed, :errored, :interrupted, :shutdown, :unknown_outcome],
       do: status

  defp runtime_status(_), do: :unknown_outcome

  defp fact(state, kind, data) do
    %{
      fact: kind,
      data:
        Map.take(
          data,
          Sigma.Protocol.Subagents.agent_fields() -- [:revision, :event_id, :observer_incarnation]
        ),
      revision: state.roster.revision + 1,
      observer_incarnation: state.generation,
      event_id: "subagent_" <> unique()
    }
  end

  defp commit_fact(state, kind, data) do
    event = fact(state, kind, data)

    case apply(Writer, :append, [state.writer, {:subagent, event}]) do
      {:ok, _} -> apply_committed(state, [event])
      {:error, _} -> %{state | error: :storage_failed}
    end
  end

  defp apply_committed(state, facts) do
    Enum.reduce(facts, state, fn event, acc ->
      {:ok, projection} = apply(Subagents, :apply_event, [acc.projection, event])
      notify(acc, {:subagent, event})
      %{acc | projection: projection, roster: apply(Subagents, :snapshot, [projection])}
    end)
  end

  defp resync(state) do
    if Enum.any?(state.jobs, fn {_ref, {_from, kind}} -> kind == :resync end) do
      {:noreply, state}
    else
      job(state, nil, :resync, fn -> MultiAgent.snapshot(state.manager) end)
    end
  end

  defp reconcile_snapshot(state, {:ok, snapshot}) do
    if state.manager_id == nil or state.manager_id == snapshot.manager_id do
      buffered = Enum.sort_by(state.observer_buffer, & &1.revision)

      state = %{
        state
        | manager_id: snapshot.manager_id,
          manager_revision: snapshot.revision,
          observer_buffer: []
      }

      state =
        Enum.reduce(snapshot.agents, state, fn agent, acc -> observe(acc, %{agent: agent}) end)

      Enum.reduce(buffered, state, fn event, acc ->
        if event.revision > acc.manager_revision do
          if event.revision == acc.manager_revision + 1,
            do: observe(%{acc | manager_revision: event.revision}, event),
            else: %{acc | observer_buffer: [event | acc.observer_buffer]}
        else
          acc
        end
      end)
    else
      state
    end
  end

  defp reconcile_snapshot(state, _),
    do: mark_unknown(%{state | error: :observer_unavailable}, "observer_unavailable")

  defp mark_unknown(state, reason) do
    state = invalidate_questions(state, fn _ -> true end)

    Enum.reduce(state.roster.agents, state, fn row, acc ->
      status = if row.status in @terminal, do: row.status, else: :unknown_outcome

      commit_fact(acc, :recovered, %{
        row
        | status: status,
          activity: nil,
          closure: :unknown,
          reason: reason
      })
    end)
  end

  defp notify(state, event) do
    if agent = Sigma.Agent.Runtime.lookup(state.repo_path, state.session_id, :agent),
      do: GenServer.cast(agent, {:notify_subscribers, event})
  end

  defp current_child?(state, identity) do
    case state.children[identity.agent_id] do
      %{identity: %{run_id: run, incarnation: incarnation}} ->
        row = Enum.find(state.roster.agents, &(&1.agent_id == identity.agent_id))

        state.error == nil and not state.closing and row != nil and
          row.run_id == identity.public_run_id and row.closure == :open and
          row.status in [:pending_init, :running, :cancelling] and
          run == identity.run_id and incarnation == identity.incarnation and
          identity.observer_incarnation == state.generation

      _ ->
        false
    end
  end

  defp forget_question(state, id) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        state

      {item, pending} ->
        Process.demonitor(item.monitor, [:flush])
        notify(state, {:ask_user_question_resolved, id})

        activity =
          if Enum.any?(pending, fn {_id, other} ->
               other.identity.agent_id == item.identity.agent_id
             end),
             do: :waiting_approval,
             else: :waiting_tool

        child_activity(%{state | pending: pending}, item.identity, activity)
    end
  end

  defp child_activity(state, identity, activity) do
    row = Enum.find(state.roster.agents, &(&1.agent_id == identity.agent_id))

    if (current_child?(state, identity) and row) && row.status == :running &&
         row.activity != activity,
       do: commit_fact(state, :run_started, Map.put(row, :activity, activity)),
       else: state
  end

  defp invalidate_questions(state, predicate) do
    Enum.reduce(state.pending, state, fn {id, item}, acc ->
      if predicate.(item) do
        send(item.waiter, {:subagent_answer, id, {:error, :cancelled}})
        forget_question(acc, id)
      else
        acc
      end
    end)
  end

  defp fork_messages(_state, _request, _parent, existing) when not is_nil(existing), do: {:ok, []}

  defp fork_messages(state, request, parent, nil) do
    value = request.options["fork_turns"]
    value = if is_nil(value) or value == "", do: "all", else: value
    mode = if is_binary(value), do: value |> String.trim() |> String.downcase(), else: :invalid

    cond do
      mode == "none" ->
        {:ok, []}

      mode == "all" ->
        parent_messages(state, parent)

      is_binary(mode) ->
        case Integer.parse(mode) do
          {n, ""} when n > 0 ->
            with {:ok, messages} <- parent_messages(state, parent) do
              boundaries =
                messages
                |> Enum.with_index()
                |> Enum.filter(fn {message, _} ->
                  message.role == :user and not Map.has_key?(message, :collaboration) and
                    is_nil(get_in(message, [Access.key(:metadata, %{}), :collaboration]))
                end)

              start = boundaries |> Enum.take(-n) |> List.first()
              {:ok, if(start, do: Enum.drop(messages, elem(start, 1)), else: messages)}
            end

          _ ->
            failure(:validation, "fork_turns must be none, all, or a positive integer string")
        end

      true ->
        failure(:validation, "fork_turns must be a string")
    end
  end

  defp parent_messages(state, parent) do
    store =
      if parent.name == "/root" do
        {:ok, state.root.store}
      else
        case Enum.find(state.children, fn {_id, child} ->
               child.identity.agent_path == parent.name
             end) do
          {_id, child} -> ChildIO.store(child.io)
          nil -> failure(:not_found, "parent child context is unavailable")
        end
      end

    with {:ok, store} <- store,
         {:ok, snapshot} <- Store.load(store, parent.run_id),
         messages when is_list(messages) <-
           get_in(snapshot, [:run, :context, :conversation, :messages]) do
      {:ok, complete_fork_boundary(messages)}
    else
      _ -> failure(:execution_failure, "committed parent context is unavailable")
    end
  end

  defp child_configuration(request, config) do
    model = request.options["model"]
    role = request.options["agent_type"]

    cond do
      model not in [nil, "", model_id(config.model)] ->
        failure(:unsupported_capability, "child model override is not configured")

      role not in [nil, "", "default"] ->
        failure(:unsupported_capability, "child agent type is not configured")

      request.options["reasoning_effort"] not in [nil, ""] ->
        failure(:unsupported_capability, "child reasoning override is not configured")

      true ->
        :ok
    end
  end

  defp parent_identity(state, name) do
    Enum.find_value(state.children, fn {id, child} ->
      if child.identity.agent_path == name, do: id
    end)
  end

  defp root_turn(_state, %{name: "/root", run_id: run_id}), do: run_id

  defp root_turn(state, parent) do
    Enum.find_value(state.children, fn {_id, child} ->
      if child.identity.agent_path == parent.name, do: child.identity.origin_turn_id
    end) || state.root.authority.run_id
  end

  defp evidence_from_writer(nil), do: %{roster: apply(Subagents, :new, []), admissions: %{}}

  defp evidence_from_writer(writer) do
    {:ok, evidence} = apply(Writer, :subagent_state, [writer])
    evidence
  end

  # A spawn admission happens after the issuing assistant response is committed,
  # before its tools have results. Fork only the complete committed prefix; no
  # synthetic tool result or inherited authorization is invented for that suffix.
  defp complete_fork_boundary(messages) do
    {safe, pending} =
      Enum.reduce(Enum.with_index(messages), {length(messages), MapSet.new()}, fn
        {%{role: :assistant, content: content}, index}, {safe, pending} when is_list(content) ->
          calls = for %{type: :tool_call, id: id} <- content, do: id

          {if(calls == [] or MapSet.size(pending) > 0, do: safe, else: index),
           Enum.reduce(calls, pending, &MapSet.put(&2, &1))}

        {%{role: role, tool_call_id: id}, index}, {safe, pending}
        when role in [:tool, :tool_result] ->
          pending = MapSet.delete(pending, id)
          {if(MapSet.size(pending) == 0, do: index + 1, else: safe), pending}

        _, acc ->
          acc
      end)

    if MapSet.size(pending) == 0, do: messages, else: Enum.take(messages, safe)
  end

  def collaboration_tools, do: @collaboration

  def configuration(state) do
    state
    |> Map.take(@configuration)
    |> Map.update(:provider_options, [], &Keyword.delete(&1, :hosted_web_search))
    |> Map.put(:mcp_clients, Map.get(Map.get(state, :mcp_session, %{}), :clients, %{}))
    |> Map.put(:mcp_client_source, Map.get(state, :control_pid))
    |> Map.put(:native_archive, archive_configuration(state))
    |> Map.put(:host_retirement, Map.get(state, :host_retirement))
    |> Map.put(
      :mcp_hook_executor,
      Sigma.Coding.MCP.hook_executor(Map.get(state, :mcp_session, %{}))
    )
  end

  defp archive_configuration(%{writer: writer, transcript_path: path, subagents: host})
       when not is_nil(writer) and is_binary(path) and path != "" and not is_nil(host),
       do: %{host: host, root_transcript: path, agent_name: "/root"}

  defp archive_configuration(_state), do: nil

  defp model_id(model) when is_map(model), do: model[:id] || model["id"]
  defp model_id(model), do: to_string(model)
  defp qualify(state, id), do: Map.get(state.archive_aliases, id, state.generation <> ":" <> id)
  defp unique, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  defp now, do: System.system_time(:millisecond)
  defp failure(class, message, opts \\ []), do: {:error, Error.new(class, message, opts)}
end
