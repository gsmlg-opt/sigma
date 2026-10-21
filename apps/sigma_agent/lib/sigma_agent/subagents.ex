defmodule Sigma.Agent.Subagents do
  @moduledoc "Session-owned bridge to Backplane's nested collaboration runtime."
  use GenServer

  require Logger

  alias Backplane.AgentRuntime.{Error, Codex.MultiAgent, Codex.Session}
  alias Sigma.Agent.Backplane.{ChildIO, Store}
  alias Sigma.Session.{Subagents, Writer}

  @collaboration ~w(spawn_agent send_message followup_task interrupt_agent list_agents wait_agent)
  @configuration ~w(model provider provider_options system_prompt session_context context_limit cwd tools mcp_servers hook_specs dispatcher_opts policy task_supervisor)a
  @terminal [:completed, :errored, :interrupted, :shutdown]

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, shutdown: 10_000}
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  def prepare_root(host, context), do: GenServer.call(host, {:prepare_root, context}, :infinity)
  def snapshot(host), do: GenServer.call(host, :snapshot, :infinity)
  def can_stop(host), do: GenServer.call(host, :can_stop)
  def close(host), do: GenServer.call(host, :close, :infinity)
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

    recovery_required =
      unresolved or
        Enum.any?(roster.agents, &(&1.status == :unknown_outcome or &1.closure == :unknown))

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
       manager: nil,
       contracts: [],
       root: nil,
       children: %{},
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
       error: if(recovery_required, do: :recovery_required)
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply,
     {:ok,
      %{
        available: state.enabled and state.writer != nil and state.error == nil,
        subagents: state.roster
      }}, state}
  end

  def handle_call(:can_stop, _from, state) do
    active =
      state.roster.counts.executing + state.roster.counts.pending + state.roster.counts.unknown

    uncertain = Enum.any?(state.roster.agents, &(&1.closure == :unknown))
    unresolved = Enum.any?(state.attempts, fn {_id, attempt} -> attempt.status == :reserved end)

    result =
      if active == 0 and not uncertain and not unresolved and map_size(state.pending) == 0 and
           not state.preparing and not state.closing and state.error == nil,
         do: :ok,
         else: {:error, :subagent_resources_active}

    {:reply, result, state}
  end

  def handle_call({:prepare_root, _context}, _from, %{writer: nil} = state),
    do: {:reply, {:ok, %{contracts: [], binding: nil}}, state}

  def handle_call({:prepare_root, _context}, _from, %{enabled: false} = state),
    do: {:reply, {:ok, %{contracts: [], binding: nil}}, state}

  def handle_call({:prepare_root, context}, from, state) do
    if state.preparing or state.closing or state.error != nil do
      {:reply, failure(:resource_conflict, "subagent host is unavailable"), state}
    else
      host = self()
      # Preparation may retire a confirmed-closed generation. The host owns
      # these links; unlink here before the control task stops the old owners.
      Enum.each([state.session, state.manager], fn pid ->
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

  def handle_call(:close, from, state) do
    was_closing = state.closing

    state =
      invalidate_questions(
        %{state | closing: true, close_waiters: [from | state.close_waiters]},
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
  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.jobs, ref) do
      {nil, _} ->
        {:noreply, state}

      {{from, :prepare}, jobs} ->
        Process.demonitor(ref, [:flush])
        state = %{state | jobs: jobs}

        case result do
          {:ok, runtime} ->
            Process.link(runtime.session)
            Process.link(runtime.manager)
            state = adopt_generation(state, runtime)

            if state.closing do
              GenServer.reply(from, failure(:resource_conflict, "subagent admission is closing"))
              start_close(%{state | preparing: false})
            else
              job(state, from, :bind, fn ->
                Session.bind(state.session, state.root.authority, incarnation: 1)
              end)
            end

          {:error, _} = error ->
            Enum.each([state.session, state.manager], fn pid ->
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

        reply =
          with {:ok, binding} <- result do
            contracts =
              Enum.map(state.contracts, fn contract ->
                %{
                  contract
                  | backend_context: Map.put(contract.backend_context, :session_binding, binding)
                }
              end)

            {:ok, %{contracts: contracts, binding: binding}}
          end

        if state.closing do
          GenServer.reply(from, failure(:resource_conflict, "subagent admission is closing"))
          start_close(state)
        else
          GenServer.reply(from, reply)
          {:noreply, state}
        end

      {{nil, :close}, jobs} ->
        Process.demonitor(ref, [:flush])
        {result, snapshot} = result
        state = %{state | jobs: jobs, closing: false}
        state = reconcile_snapshot(state, snapshot)

        state =
          if match?({:ok, %{status: :confirmed}}, result),
            do: state,
            else: mark_unknown(%{state | error: :cleanup_unconfirmed}, "cleanup_unconfirmed")

        if match?({:ok, %{status: :confirmed}}, result) do
          Enum.each(state.children, fn {_id, child} ->
            if Process.alive?(child.io), do: GenServer.stop(child.io, :normal)
          end)
        end

        reply =
          if(state.error,
            do: failure(:unknown_outcome, "subagent cleanup requires reconciliation"),
            else: result
          )

        {:noreply, reply_closes(state, reply)}

      {{nil, :resync}, jobs} ->
        Process.demonitor(ref, [:flush])
        state = %{state | jobs: jobs}
        state = reconcile_snapshot(state, result)
        if state.observer_buffer == [], do: {:noreply, state}, else: resync(state)
    end
  end

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

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.jobs, ref) do
      {{from, kind}, jobs} ->
        if from,
          do:
            GenServer.reply(
              from,
              failure(:execution_failure, "subagent control operation failed")
            )

        state = %{state | jobs: jobs, preparing: false, error: :control_failed}

        state =
          if kind == :close or state.closing,
            do:
              reply_closes(state, failure(:unknown_outcome, "subagent control operation failed")),
            else: state

        {:noreply, state}

      {nil, _} ->
        ids = for {id, item} <- state.pending, item.monitor == ref, do: id
        {:noreply, Enum.reduce(ids, state, &forget_question(&2, &1))}
    end
  end

  def handle_info({:EXIT, pid, _reason}, state) when pid == state.manager or pid == state.session,
    do: {:noreply, mark_unknown(%{state | error: :runtime_down}, "runtime_down")}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_pid(state.session) and Process.alive?(state.session) do
      task = Task.async(fn -> runtime_call(fn -> Session.close(state.session) end) end)
      result = Task.yield(task, 6_000) || Task.shutdown(task, :brutal_kill)

      unless match?({:ok, {:ok, %{status: :confirmed}}}, result) do
        Logger.error(
          "[Sigma.Agent.Subagents] Shutdown cleanup is unconfirmed: #{inspect(result)}"
        )
      end
    end

    owners =
      [state.session, state.manager] ++ Enum.map(state.children, fn {_id, child} -> child.io end)

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
    job(state, nil, :close, fn ->
      result = runtime_call(fn -> Session.close(state.session) end)
      snapshot = runtime_call(fn -> MultiAgent.snapshot(state.manager) end)
      {result, snapshot}
    end)
  end

  defp runtime_call(fun) do
    fun.()
  catch
    :exit, _ -> failure(:unknown_outcome, "subagent owner is unavailable")
  end

  defp reply_closes(state, result) do
    Enum.each(state.close_waiters, &GenServer.reply(&1, result))
    %{state | close_waiters: [], closing: false}
  end

  defp prepare_generation(host, state, context), do: runtime_generation(host, state, context)

  defp runtime_generation(host, %{session: session} = state, context) when is_pid(session) do
    case Session.status(session) do
      %{phase: :idle} ->
        {:ok, Map.take(state, [:generation, :session, :manager, :contracts])}

      %{phase: :closed, cleanup: {:ok, %{status: :confirmed}}} ->
        Process.unlink(state.manager)
        Process.unlink(session)
        GenServer.stop(state.manager, :shutdown)
        GenServer.stop(session, :shutdown)
        new_generation(host, state, context)

      _ ->
        failure(:unknown_outcome, "previous subagent generation is not settled")
    end
  end

  defp runtime_generation(host, state, context), do: new_generation(host, state, context)

  defp new_generation(host, state, context) do
    generation = unique()

    with {:ok, session} <- Session.start_link(owner_pid: host) do
      result = start_manager(host, state, context, generation, session)
      Process.unlink(session)
      if match?({:error, _}, result), do: stop_owner(session)
      result
    end
  end

  defp start_manager(host, state, context, generation, session) do
    case MultiAgent.start_link(
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

            with {:ok, snapshot} <- MultiAgent.snapshot(manager) do
              {:ok,
               %{
                 generation: generation,
                 session: session,
                 manager: manager,
                 contracts: contracts,
                 manager_id: snapshot.manager_id
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

  defp stop_owner(pid) do
    Process.unlink(pid)
    if Process.alive?(pid), do: GenServer.stop(pid, :shutdown)
  catch
    :exit, _ -> :ok
  end

  defp adopt_generation(%{generation: generation} = state, %{generation: generation}), do: state

  defp adopt_generation(state, runtime) do
    old_children = state.children

    state =
      Map.merge(state, runtime)
      |> Map.merge(%{
        children: %{},
        attempts: %{},
        manager_revision: 0,
        observer_buffer: [],
        origins: %{},
        error: nil
      })

    state =
      Enum.reduce(state.roster.agents, state, fn row, acc ->
        row =
          if row.status in @terminal,
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

    Enum.each(old_children, fn {_id, child} ->
      if Process.alive?(child.io), do: GenServer.stop(child.io, :normal)
    end)

    state
  end

  defp prepare_child(state, request, run_id, parent) do
    child = parent.child
    agent_id = qualify(state, child.agent_id)
    existing = state.children[agent_id]

    child_session =
      if existing, do: existing.identity.child_session_id, else: "child_" <> unique()

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
        if(existing, do: existing.identity.origin_turn_id, else: root_turn(state, parent)),
      origin_tool_call_id:
        if(existing, do: existing.identity.origin_tool_call_id, else: origin.tool_call_id),
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
              transcript_path: metadata.transcript_path
            })

          {{:ok, options}, state}
        else
          {:error, %Error{}} = error -> {error, state}
          {:error, _} -> {failure(:execution_failure, "child IO preparation failed"), state}
        end

      {:error, _} ->
        {failure(:execution_failure, "subagent intent could not be persisted"),
         %{state | error: :storage_failed}}
    end
  end

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

    with :ok <- File.mkdir_p(directory) do
      ChildIO.start_link(
        [
          config: root_config,
          identity: identity,
          messages: messages,
          transcript_path: Path.join(directory, "session.jsonl"),
          backplane_store_path: Path.join(directory, "runtime"),
          notify: fn identity, phase -> send(host, {:subagent_activity, identity, phase}) end
        ] ++ child_callbacks(state)
      )
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

            {:ok, %{state | attempts: Map.put(state.attempts, receipt.attempt_id, attempt)}}

          {:error, _} ->
            {failure(:execution_failure, "subagent receipt could not be persisted"),
             %{state | error: :storage_failed}}
        end
    end
  end

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

  defp observe(state, %{agent: agent}) do
    id = qualify(state, agent.agent_id)
    row = Enum.find(state.roster.agents, &(&1.agent_id == id))
    run_id = qualify(state, agent.run_id)

    if row do
      status =
        if agent.status == :closed and row.status in @terminal,
          do: row.status,
          else: runtime_status(agent.status)

      status =
        if status == :unknown_outcome and row.status in @terminal, do: row.status, else: status

      data = %{
        agent_id: id,
        run_id: run_id,
        incarnation: agent.incarnation,
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
    |> Map.put(
      :mcp_hook_executor,
      Sigma.Coding.MCP.hook_executor(Map.get(state, :mcp_session, %{}))
    )
  end

  defp model_id(model) when is_map(model), do: model[:id] || model["id"]
  defp model_id(model), do: to_string(model)
  defp qualify(state, id), do: state.generation <> ":" <> id
  defp unique, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  defp now, do: System.system_time(:millisecond)
  defp failure(class, message), do: {:error, Error.new(class, message)}
end
