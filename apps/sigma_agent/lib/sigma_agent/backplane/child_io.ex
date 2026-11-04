defmodule Sigma.Agent.Backplane.ChildIO do
  @moduledoc """
  Child-local provider, tool, and transcript boundary for a stable subagent.

  `prepare/5` uses cached contracts and never calls the multi-agent manager. Each
  new run gets fresh tool ETS and a fenced provider owner. Only committed runtime
  messages are projected to the child's writer; chat never enters the root stream.
  """

  use GenServer
  require Logger

  alias Backplane.AgentRuntime.{Conversation, Error, Plan, Codex.Session}
  alias Sigma.Agent.{ContextBuilder, ContextPolicy, Hooks, Message, SessionContext}
  alias Sigma.Coding.Hooks.Outcome

  alias Sigma.Agent.Backplane.{
    CanonicalHistory,
    ChildStore,
    CodexResources,
    ContextControls,
    HookDelivery,
    LifetimeEvidence,
    LifetimeRecovery,
    NativeTools,
    PlanProjection,
    Provider,
    Store,
    ToolCatalog
  }

  alias Sigma.Ai.{ProviderRequest, ProviderUsage}
  alias Sigma.Coding.{Dispatcher, Tool}
  alias Sigma.Session.{Log, Writer}

  @config_keys ~w(model provider provider_options system_prompt session_context context_limit cwd tools mcp_servers mcp_clients mcp_client_source hook_specs dispatcher_opts policy task_supervisor mcp_hook_executor native_tools native_memory_root native_archive native_plugins)a

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def prepare(io, identity, parent_authority, contracts, opts \\ []),
    do: GenServer.call(io, {:prepare, identity, parent_authority, contracts, opts}, :infinity)

  def store(io), do: GenServer.call(io, :store)
  def metadata(io), do: GenServer.call(io, :metadata)
  def archive_source(io), do: GenServer.call(io, :archive_source, :infinity)
  def validate(io, key), do: GenServer.call(io, {:validate, key}, :infinity)
  def project(io, key, messages), do: GenServer.call(io, {:project, key, messages}, :infinity)
  def reject_preparation(io, key), do: GenServer.call(io, {:reject_preparation, key}, :infinity)

  @doc "Closes native resources and async hooks and persists their independent confirmations."
  def retire(io), do: GenServer.call(io, :retire, :infinity)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    config = opts |> Keyword.fetch!(:config) |> Map.take(@config_keys)
    identity = Keyword.fetch!(opts, :identity)
    path = Keyword.fetch!(opts, :transcript_path)
    sidecar_path = Keyword.fetch!(opts, :backplane_store_path)
    storage_mod = Keyword.get(opts, :storage_mod, Sigma.Session.Storage.JsonlFile)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, snapshot} <- apply(Log, :snapshot, [path, [], storage_mod]),
         {:ok, sidecar} <- start_store(sidecar_path, Keyword.get(opts, :lifetime_recovery)),
         {:ok, writer} <-
           apply(Writer, :start_link, [
             [
               storage_id: path,
               storage_mod: storage_mod,
               session_id: identity.child_session_id,
               cwd: config.cwd
             ]
           ]),
         {:ok, hook_async_runtime} <- Sigma.Coding.Hooks.AsyncRuntime.start(self()),
         {:ok, host_retirement} <- retirement_context(opts, writer, sidecar, identity, config) do
      {:ok,
       %{
         config: config,
         mcp_client_source: Map.get(config, :mcp_client_source),
         mcp_server_ids: config |> Map.get(:mcp_clients, %{}) |> Map.keys(),
         identity: identity,
         transcript_path: path,
         backplane_store_path: sidecar_path,
         store: sidecar,
         writer: writer,
         messages:
           if(snapshot.messages == [],
             do: Keyword.get(opts, :messages, []),
             else: snapshot.messages
           ),
         persisted: MapSet.new(Map.keys(snapshot.message_entry_ids)),
         permission_request_fn: Keyword.get(opts, :permission_request_fn),
         ask_user_question_fn: Keyword.get(opts, :ask_user_question_fn),
         notify: Keyword.get(opts, :notify),
         key: nil,
         prepared: nil,
         tool_state: nil,
         active_tools: [],
         delegated_tool_names: MapSet.new(),
         catalog_tools: [],
         native_names: [],
         codex_resources: nil,
         lifetime_recovery: Keyword.get(opts, :lifetime_recovery),
         native_context: nil,
         request: nil,
         current_request_id: nil,
         finished_requests: MapSet.new(),
         start_hook_pending: true,
         hook_context: nil,
         hook_async_contexts: Hooks.async_contexts(),
         hook_async_runtime: hook_async_runtime,
         host_retirement: host_retirement,
         retiring: false,
         retirement_task: nil,
         retirement_waiters: [],
         retirement_native: nil,
         retirement_async_hooks: nil,
         retired: nil,
         rejected_preparation: false,
         hook_delivery_task: nil,
         hook_delivery_timer: nil,
         hook_delivery_started: false,
         hook_delivery_pending: %{},
         hook_delivery_admissions: %{},
         hook_delivery_waiters: [],
         persistence_error: nil
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp start_store(path, recovery) do
    case Store.start_link(path: path) do
      {:error, {:already_started, store}} when is_pid(recovery) ->
        LifetimeRecovery.handoff_store(recovery, path, store)

      result ->
        result
    end
  end

  @impl true
  def handle_call(:store, _from, state), do: {:reply, {:ok, state.store}, state}

  def handle_call(:metadata, _from, state) do
    metadata =
      state
      |> Map.take([:identity, :transcript_path, :backplane_store_path])
      |> Map.put(:host_retirement, if(state.host_retirement, do: state.host_retirement.identity))

    {:reply, {:ok, metadata}, state}
  end

  def handle_call(:archive_source, _from, state),
    do: {:reply, {:ok, Map.take(state, [:identity, :transcript_path, :writer])}, state}

  def handle_call({:validate, key}, _from, %{key: key} = state),
    do: {:reply, :ok, state}

  def handle_call({:validate, _key}, _from, state), do: {:reply, stale(), state}

  def handle_call(:retire, _from, %{retired: retired} = state) when not is_nil(retired),
    do: {:reply, retired, state}

  def handle_call(:retire, from, state) do
    state = %{state | retiring: true, retirement_waiters: [from | state.retirement_waiters]}

    if state.retirement_task do
      {:noreply, state}
    else
      state = retire_hook_delivery(state)

      task =
        Task.Supervisor.async_nolink(Sigma.Coding.Dispatcher.TaskSupervisor, fn ->
          retire_components(state)
        end)

      {:noreply, %{state | retirement_task: task}}
    end
  end

  def handle_call(
        {:prepare, _identity, _authority, _contracts, _opts},
        _from,
        %{retiring: true} = state
      ),
      do: {:reply, retiring_error(), state}

  def handle_call({:prepare, identity, authority, contracts, opts}, _from, state) do
    key = {identity.run_id, identity.incarnation}

    cond do
      identity.agent_id != state.identity.agent_id or
          identity.child_session_id != state.identity.child_session_id ->
        {:reply, {:error, Error.new(:validation, "child identity changed")}, state}

      key == state.key ->
        {:reply, {:ok, state.prepared}, state}

      state.persistence_error != nil ->
        {:reply, {:error, state.persistence_error}, state}

      true ->
        state = retire_hook_delivery(state)

        state = %{
          state
          | identity: identity,
            config: Map.take(Keyword.get(opts, :config, state.config), @config_keys),
            permission_request_fn:
              Keyword.get(opts, :permission_request_fn, state.permission_request_fn),
            ask_user_question_fn:
              Keyword.get(opts, :ask_user_question_fn, state.ask_user_question_fn)
        }

        # The public manager supplies the parent's committed catalog on each run.
        grants = MapSet.new(Map.get(authority, :grants, []))
        state = %{state | delegated_tool_names: grants}

        tools =
          Enum.filter(Map.get(state.config, :tools, []), &MapSet.member?(grants, Tool.name(&1)))

        contracts = Enum.filter(contracts, &MapSet.member?(grants, contract_name(&1)))
        native_names = child_native_names(state, grants, tools)

        names =
          Enum.map(tools, &Tool.name/1) ++ Enum.map(contracts, &contract_name/1) ++ native_names

        authority =
          authority
          |> Map.put(:run_id, identity.run_id)
          |> Map.put(:caller, identity.child_session_id)
          |> Map.put(:grants, names)

        case prepare_catalog(state, authority, tools, contracts, native_names, key) do
          {:ok, catalog, state} ->
            if state.tool_state, do: :ets.delete(state.tool_state)
            tool_state = :ets.new(__MODULE__, [:set, :public, read_concurrency: true])

            messages =
              if state.messages == [], do: Keyword.get(opts, :messages, []), else: state.messages

            state = %{
              state
              | identity: identity,
                key: key,
                tool_state: tool_state,
                active_tools: tools ++ plugin_tools(state.native_context),
                catalog_tools: catalog.tools,
                native_names: native_names,
                request: nil,
                current_request_id: nil,
                finished_requests: MapSet.new(),
                hook_delivery_started: false,
                messages: messages
            }

            options = conversation_options(state, catalog)
            prepared = %{options: options, catalog: catalog, key: key}
            {:reply, {:ok, prepared}, %{state | prepared: prepared}}

          {:error, error, state} ->
            {:reply, {:error, error}, state}
        end
    end
  end

  def handle_call({:reject_preparation, key}, _from, %{key: key} = state) do
    result = close_native_resources(state)
    rejected = match?({:ok, %{status: :confirmed}}, result)
    {:reply, result, %{state | rejected_preparation: rejected}}
  end

  def handle_call({:reject_preparation, _key}, _from, state), do: {:reply, stale(), state}

  def handle_call({action, _key, _argument}, _from, %{retiring: true} = state)
      when action in [:hook_prompt, :hook_dispatching, :tool_context],
      do: {:reply, retiring_error(), state}

  def handle_call({:start_hook, _key}, _from, %{retiring: true} = state),
    do: {:reply, retiring_error(), state}

  def handle_call({:context_remaining, key}, _from, %{key: key} = state) do
    context = build_context(state, state.messages, state.catalog_tools)

    snapshot =
      ContextPolicy.snapshot(
        model: state.config.model,
        system: context.system,
        messages: context.messages,
        tools: context.tools
      )

    remaining =
      ContextControls.tokens_left(snapshot,
        model: state.config.model,
        context_limit: Map.get(state.config, :context_limit),
        output_reserve:
          Sigma.Ai.Provider.output_token_limit(
            state.config.provider,
            state.config.model,
            Map.get(state.config, :provider_options, [])
          )
      )

    {:reply, remaining, state}
  end

  def handle_call({:context_remaining, _key}, _from, state), do: {:reply, nil, state}

  def handle_call({:permission_options, key}, _from, %{key: key} = state),
    do: {:reply, {:ok, dispatcher_options(state)}, state}

  def handle_call({:permission_options, _key}, _from, state), do: {:reply, stale(), state}

  def handle_call({:mcp_client_source, key}, _from, %{key: key} = state) do
    result =
      if is_pid(state.mcp_client_source),
        do: {:ok, %{source: state.mcp_client_source, server_ids: state.mcp_server_ids}},
        else: {:error, Error.new(:cancelled, "child MCP resource source is unavailable")}

    {:reply, result, state}
  end

  def handle_call({:mcp_client_source, _key}, _from, state), do: {:reply, stale(), state}

  def handle_call({:project, key, messages}, _from, %{key: key} = state) do
    cond do
      state.persistence_error ->
        {:reply, {:error, state.persistence_error}, state}

      true ->
        {result, state} = project_messages(state, messages)
        state = reconcile_hook_delivery(state)

        result =
          case result do
            :ok when not is_nil(state.persistence_error) -> {:error, state.persistence_error}
            result -> result
          end

        {:reply, result, state}
    end
  end

  def handle_call({:project, _key, _messages}, _from, state), do: {:reply, stale(), state}

  def handle_call({:hook_prompt, key, message}, from, %{key: key} = state) do
    # Hold prompt preparation until the admission receipt restores its identity.
    # Checkpoint projection must stay free: steering admission can await it.
    if state.hook_delivery_task do
      {:noreply, defer_hook_call(state, from, {:prompt, message})}
    else
      {:reply, {:ok, restore_hook_message(state, message)}, state}
    end
  end

  def handle_call({:hook_prompt, _key, _message}, _from, state),
    do: {:reply, stale(), state}

  def handle_call({:hook_dispatching, key, message}, _from, %{key: key} = state) do
    pending = Map.put(state.hook_delivery_pending, message.id, message)
    {:reply, :ok, %{state | hook_delivery_pending: pending}}
  end

  def handle_call({:hook_dispatching, _key, _message}, _from, state),
    do: {:reply, stale(), state}

  def handle_call({:canonical_hook_messages, key, messages}, _from, %{key: key} = state),
    do: {:reply, {:ok, Enum.map(messages, &restore_hook_message(state, &1))}, state}

  def handle_call({:canonical_hook_messages, _key, _messages}, _from, state),
    do: {:reply, stale(), state}

  def handle_call({:start_hook, key}, _from, %{key: key} = state) do
    if state.start_hook_pending do
      outcome =
        Hooks.dispatch(
          :subagent_start,
          Map.get(state.config, :hook_specs, []),
          hook_context(state)
        )

      {:reply, :ok, %{state | start_hook_pending: false, hook_context: Outcome.context(outcome)}}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:start_hook, _key}, _from, state), do: {:reply, stale(), state}

  def handle_call({:hook_context, key}, _from, %{key: key} = state),
    do: {:reply, state.hook_context, state}

  def handle_call({:hook_context, _key}, _from, state), do: {:reply, nil, state}

  def handle_call(
        {:tool_context, {run_id, incarnation} = key,
         %{run_id: run_id, incarnation: incarnation} = operation},
        _from,
        %{key: key} = state
      ) do
    notify(state, :running_tools)
    opts = dispatcher_options(state)

    opts =
      if state.config[:native_tools] == true,
        do:
          Keyword.put(
            opts,
            :hook_async_callback_factory,
            HookDelivery.factory(state.writer, operation)
          ),
        else: opts

    {:reply, {:ok, state.active_tools, opts}, state}
  end

  def handle_call({:tool_context, _key, _operation}, _from, state),
    do: {:reply, stale(), state}

  def handle_call({:tool_boundary, key}, _from, %{key: key} = state),
    do: {:reply, :ok, state}

  def handle_call({:tool_boundary, _key}, _from, state), do: {:reply, stale(), state}

  def handle_call({:tool_fact, key, fact}, _from, %{key: key} = state) do
    state = append(state, {:metrics, :tool_finished, fact})
    {:reply, :ok, state}
  end

  def handle_call({:tool_fact, _key, _fact}, _from, state), do: {:reply, stale(), state}

  @impl true
  def handle_info({ref, result}, %{retirement_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = complete_retirement(state, result)
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, cause},
        %{retirement_task: %Task{ref: ref}} = state
      ) do
    result = {:error, Error.new(:unknown_outcome, "child retirement task failed", cause: cause)}
    Enum.each(state.retirement_waiters, &GenServer.reply(&1, result))
    {:noreply, %{state | retirement_task: nil, retirement_waiters: []}}
  end

  def handle_info(
        {:hook_delivery_tick, token},
        %{hook_delivery_timer: {_timer, token}} = state
      ) do
    state = start_hook_delivery(%{state | hook_delivery_timer: nil})
    {:noreply, state}
  end

  def handle_info({:hook_delivery_tick, _token}, state), do: {:noreply, state}

  def handle_info({ref, result}, %{hook_delivery_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | hook_delivery_task: nil}

    state =
      case result do
        {:admitted, message, runtime_id} ->
          %{
            state
            | hook_delivery_admissions:
                Map.put(state.hook_delivery_admissions, runtime_id, message)
          }

        {:failed, message} ->
          %{state | hook_delivery_pending: Map.delete(state.hook_delivery_pending, message.id)}

        :inactive ->
          %{state | hook_delivery_pending: %{}}

        {:delivery_error, error} ->
          hook_delivery_error(state, error)

        _ ->
          state
      end

    state = state |> release_hook_calls() |> reconcile_hook_delivery()
    state = if result == :inactive, do: state, else: schedule_hook_delivery(state, 25)
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{hook_delivery_task: %Task{ref: ref}} = state
      ) do
    state = %{state | hook_delivery_task: nil, hook_delivery_pending: %{}}
    state = state |> release_hook_calls() |> reconcile_hook_delivery()
    {:noreply, schedule_hook_delivery(state, 25)}
  end

  def handle_info({:child_io, key, event}, %{key: key} = state),
    do: {:noreply, provider_event(event, state)}

  def handle_info({:child_io, _key, {:backplane_request_started, worker, ref, _, _}}, state) do
    send(worker, {:backplane_request_ready, ref, {:error, :stale_child_io}})
    {:noreply, state}
  end

  def handle_info({:child_io, _key, {:backplane_provider_boundary, worker, ref, _request}}, state) do
    send(worker, {:backplane_provider_continue, ref})
    {:noreply, state}
  end

  def handle_info({:child_io, _key, _event}, state), do: {:noreply, state}

  def handle_info({:EXIT, store, reason}, %{store: store} = state) do
    error = Error.new(:execution_failure, "child runtime Store exited", cause: reason)
    {:stop, error, %{state | persistence_error: error}}
  end

  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  @impl true
  def terminate(_reason, state) do
    if state.retirement_task, do: Task.shutdown(state.retirement_task, :brutal_kill)
    if state.hook_delivery_task, do: Task.shutdown(state.hook_delivery_task, :brutal_kill)
    if state.hook_delivery_timer, do: Process.cancel_timer(elem(state.hook_delivery_timer, 0))

    unless state.retired do
      case retire_components(state) do
        %{result: {:ok, %{status: :confirmed}}} ->
          :ok

        %{result: error} ->
          Logger.error("Child host retirement is unconfirmed: #{inspect(error)}")
      end
    end

    if state.codex_resources do
      if Process.alive?(state.codex_resources), do: GenServer.stop(state.codex_resources, :normal)
    end

    # Compatibility cleanup after an unconfirmed strict shutdown; never turn
    # this best-effort result into a durable confirmation.
    Sigma.Coding.Hooks.AsyncRuntime.shutdown(state.hook_async_runtime)

    if Process.alive?(state.writer), do: GenServer.stop(state.writer, :normal)

    case Store.retire(state.store) do
      :ok -> :ok
      {:error, error} -> Logger.error("Child runtime writer retirement failed: #{inspect(error)}")
    end
  end

  defp retirement_context(opts, writer, store, identity, config) do
    case Keyword.get(opts, :root_header_id) do
      nil ->
        {:ok, nil}

      root when is_binary(root) and root != "" ->
        with result when result == :ignored or elem(result, 0) == :ok <-
               apply(Writer, :append, [writer, {:agent_start, config.cwd}]),
             {:ok, %{entries: entries}} <- apply(Writer, :selected_journal, [writer]),
             %{"id" => header} when is_binary(header) and header != "" <-
               Enum.find(entries, &(&1["type"] == "session")) do
          {:ok,
           %{
             store: store,
             identity: %{
               root_header_id: root,
               transcript_header_id: header,
               child_session_id: identity.child_session_id,
               host_lifetime_id:
                 "child-host-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
             }
           }}
        else
          {:error, cause} ->
            {:error,
             Error.new(:execution_failure, "child retirement header is unavailable", cause: cause)}

          _ ->
            {:error, Error.new(:malformed_result, "child retirement requires its journal header")}
        end

      _ ->
        {:error, Error.new(:validation, "invalid trusted root journal header")}
    end
  end

  defp retire_components(state) do
    native = state.retirement_native || retirement_call(fn -> close_native_resources(state) end)

    hooks =
      state.retirement_async_hooks ||
        retirement_call(fn ->
          Sigma.Coding.Hooks.AsyncRuntime.shutdown_confirmed(state.hook_async_runtime)
        end)

    # A failed native close can still have an unacknowledged binding-index
    # write. Retain the real hook confirmation in memory, but do not seal its
    # host lifetime until that earlier membership and native fact are durable.
    persisted_hooks =
      if match?({:ok, %{status: :confirmed}}, native),
        do: persist_async_retirement(state.host_retirement, hooks),
        else: hooks

    result =
      with {:ok, %{status: :confirmed}} <- native,
           {:ok, %{status: :confirmed}} <- persisted_hooks,
           :ok <- retirement_call(fn -> Store.confirm_provider_shutdown(state.store) end),
           :ok <- retirement_call(fn -> reconcile_native_lifetime(state) end) do
        {:ok,
         %{status: :confirmed, capture: if(state.host_retirement, do: :durable, else: :disabled)}}
      else
        {:error, _} = error ->
          error

        other ->
          {:error,
           Error.new(:malformed_result, "invalid child retirement confirmation", cause: other)}
      end

    %{native: native, async_hooks: hooks, result: result}
  end

  # The existing manager receipt explicitly rejected this preparation before
  # process birth. Keep its ordinary close; do not fabricate lifetime receipts.
  defp reconcile_native_lifetime(%{rejected_preparation: true}), do: :ok
  defp reconcile_native_lifetime(%{lifetime_recovery: nil}), do: :ok
  defp reconcile_native_lifetime(%{codex_resources: nil}), do: :ok

  defp reconcile_native_lifetime(state) do
    host = state.host_retirement.identity

    identity = %{
      run_id: state.identity.run_id,
      incarnation: state.identity.incarnation,
      thread_id: state.identity.run_id,
      root_thread_id: host.root_header_id,
      child_header_id: host.transcript_header_id,
      child_session_id: state.identity.child_session_id
    }

    with :ok <-
           LifetimeEvidence.recover_child(
             %{writer: state.lifetime_recovery},
             state.store,
             identity
           ),
         :ok <-
           state.codex_resources
           |> CodexResources.retirement_context()
           |> LifetimeEvidence.capture_session(),
         do: :ok
  end

  defp persist_async_retirement(nil, result), do: result

  defp persist_async_retirement(context, {:ok, %{status: :confirmed} = confirmation}) do
    case retirement_call(fn ->
           Store.record_host_retirement(
             context.store,
             context.identity,
             :async_hooks,
             confirmation
           )
         end) do
      :ok -> {:ok, confirmation}
      {:error, _} = error -> error
    end
  end

  defp persist_async_retirement(_context, error), do: error

  defp retirement_call(fun) do
    fun.()
  catch
    :exit, cause ->
      {:error, Error.new(:unknown_outcome, "child retirement owner is unavailable", cause: cause)}
  end

  defp complete_retirement(state, %{native: native, async_hooks: hooks, result: result}) do
    Enum.each(state.retirement_waiters, &GenServer.reply(&1, result))

    %{
      state
      | retirement_task: nil,
        retirement_waiters: [],
        retirement_native: confirmed_or_previous(native, state.retirement_native),
        retirement_async_hooks: state.retirement_async_hooks || hooks,
        retired: if(match?({:ok, %{status: :confirmed}}, result), do: result)
    }
  end

  defp confirmed_or_previous({:ok, %{status: :confirmed}} = result, _previous), do: result
  defp confirmed_or_previous(_result, previous), do: previous

  defp retiring_error,
    do: {:error, Error.new(:resource_conflict, "child host is retiring")}

  defp conversation_options(state, catalog) do
    config = state.config
    io = self()
    key = state.key
    hook_context = hook_context(state)
    initial_prompt = :atomics.new(1, signed: false)

    host = %{
      model: config.model,
      provider: config.provider,
      provider_options: Map.get(config, :provider_options, []),
      session_id: state.identity.child_session_id,
      log_session_id: state.identity.child_session_id,
      turn_id: public_run_id(state.identity),
      hook_specs: Map.get(config, :hook_specs, []),
      hook_context: hook_context,
      stop_hook_context:
        Map.put(hook_context, :transcript_path, Map.get(state.identity, :parent_transcript_path)),
      stop_hook_data: %{agent_transcript_path: state.transcript_path},
      stop_hook_active: :atomics.new(1, signed: false),
      native_tool_names: state.native_names,
      permission_options: fn -> GenServer.call(io, {:permission_options, key}, :infinity) end,
      start_hook: fn -> GenServer.call(io, {:start_hook, key}, :infinity) end,
      canonical_hook_prompt: fn message ->
        GenServer.call(io, {:hook_prompt, key, message}, :infinity)
      end,
      prepare_hook_prompt: fn message ->
        with {:ok, canonical} <- GenServer.call(io, {:hook_prompt, key, message}, :infinity),
             {:ok, prepared} <-
               if(:atomics.compare_exchange(initial_prompt, 1, 0, 1) == :ok,
                 do:
                   HookDelivery.prepare_prompt(state.writer, state.store, canonical, elem(key, 0)),
                 else: {:ok, canonical}
               ),
             :ok <- HookDelivery.admitted(state.writer, prepared, message.id) do
          {:ok, %{prepared | id: message.id}}
        end
      end,
      build_context: fn messages ->
        additional_context = GenServer.call(io, {:hook_context, key}, :infinity)
        {:ok, messages} = GenServer.call(io, {:canonical_hook_messages, key, messages}, :infinity)

        ContextBuilder.build(
          messages:
            messages
            |> Hooks.prepend_context(additional_context)
            |> Hooks.async_messages(state.hook_async_contexts),
          session_context: Map.get(config, :session_context) || SessionContext.new(),
          system_prompt: Map.get(config, :system_prompt),
          tools: catalog.tools,
          cwd: config.cwd,
          model: config.model
        )
        |> ContextBuilder.with_execution_environment(
          CodexResources.environment(state.native_context)
        )
      end,
      context_error:
        &Sigma.Agent.__backplane_context_error__(
          Map.merge(
            %{
              context_limit: nil,
              provider_options: []
            },
            config
          ),
          &1
        )
    }

    [
      name: hook_conversation_name(self(), state.key),
      run_id: state.identity.run_id,
      incarnation: state.identity.incarnation,
      store: ChildStore,
      context: %{store: state.store, io: self(), key: state.key},
      provider: Provider,
      provider_context: %{
        host: host,
        owner: {self(), state.key},
        provider_lifecycle_store: if(state.native_context, do: state.store),
        permission_interaction: state.native_context != nil
      },
      hooks: Sigma.Agent.Backplane.ChildHooks,
      registry: catalog.registry,
      tools: catalog.tools,
      authority: catalog.authority,
      messages: CanonicalHistory.runtime_messages(state.messages),
      work: 100,
      provider_output_limit: :infinity,
      run_timeout: :infinity,
      effect_timeout: 300_000
    ]
    |> then(fn options ->
      if state.native_context,
        do: Keyword.put(options, :session_binding, state.native_context.session_binding),
        else: options
    end)
  end

  defp child_native_names(%{config: %{native_tools: true}} = state, grants, tools) do
    resources =
      if state.mcp_server_ids != [],
        do: NativeTools.resource_names(),
        else: []

    archive =
      if is_map(state.config[:native_archive]),
        do: NativeTools.archive_names() ++ NativeTools.board_names(),
        else: []

    discovery =
      case partition_tools(state, tools) do
        {_, []} -> if(state.config[:native_plugins], do: NativeTools.discovery_names(), else: [])
        _ -> NativeTools.discovery_names()
      end

    plugins = if state.config[:native_plugins], do: NativeTools.plugin_names(), else: []

    (NativeTools.names() ++
       NativeTools.environment_names() ++
       plugins ++
       discovery ++
       resources ++ NativeTools.skill_names() ++ NativeTools.memory_names() ++ archive)
    |> Enum.reject(
      &(&1 in ~w(request_user_input request_user_input_async send_message_to_user_async new_context))
    )
    |> Enum.filter(&MapSet.member?(grants, &1))
  end

  defp child_native_names(_state, _grants, _tools), do: []

  defp prepare_catalog(
         %{config: %{native_tools: true}} = state,
         authority,
         tools,
         contracts,
         selected,
         key
       ) do
    case native_resources(state) do
      {:ok, state} -> bind_native_catalog(state, authority, tools, contracts, selected, key)
      {:error, error, state} -> {:error, error, state}
    end
  end

  defp prepare_catalog(state, authority, tools, contracts, _selected, key) do
    io = self()

    case ToolCatalog.admit(tools, authority, &execute(io, key, &1), contracts: contracts) do
      {:ok, catalog} -> {:ok, catalog, state}
      {:error, error} -> {:error, error, state}
    end
  end

  defp bind_native_catalog(state, authority, tools, contracts, selected, key) do
    io = self()
    {eager, deferred} = partition_tools(state, tools)

    with {:ok, binding} <-
           CodexResources.bind(state.codex_resources, authority, incarnation: elem(key, 1)),
         {:ok, plugins} <- CodexResources.plugin_tools(state.codex_resources, binding),
         plugins <-
           Enum.filter(plugins, &MapSet.member?(state.delegated_tool_names, Tool.name(&1))),
         {:ok, candidates} <-
           ToolCatalog.deferred_candidates(deferred ++ plugins, &execute(io, key, &1)),
         {:ok, context} <-
           CodexResources.context(state.codex_resources, binding, candidates: candidates) do
      context = Map.put(context, :plugin_tools, plugins)
      state = %{state | native_context: context}

      selected =
        if deferred ++ plugins == [],
          do: selected -- NativeTools.discovery_names(),
          else: selected

      context =
        context
        |> Map.put(:root?, false)
        |> Map.put(:context_remaining, fn ->
          GenServer.call(io, {:context_remaining, key}, :infinity)
        end)
        |> Map.put(:mcp_clients, fn -> mcp_clients(io, key) end)

      contracts =
        Enum.map(contracts, fn contract ->
          %{
            contract
            | backend_context: Map.put(contract.backend_context, :session_binding, binding)
          }
        end)

      result =
        with :ok <- hydrate_plan(state, context),
             {:ok, profile} <-
               NativeTools.profile(
                 context,
                 authority,
                 Map.put(
                   hook_context(state),
                   :hook_specs,
                   Map.get(state.config, :hook_specs, [])
                 ),
                 tools: selected
               ),
             authority <-
               Map.put(
                 authority,
                 :grants,
                 Enum.map(eager, &Tool.name/1) ++
                   Enum.map(contracts, &contract_name/1) ++ Map.keys(profile.registry.tools)
               ),
             {:ok, catalog} <-
               ToolCatalog.admit(eager, authority, &execute(io, key, &1),
                 contracts: contracts,
                 profiles: [profile]
               ),
             do: {:ok, catalog, state}

      case result do
        {:ok, _, _} ->
          result

        {:error, error} ->
          close_native_resources(state)
          {:error, error, state}
      end
    else
      {:error, error} ->
        close_native_resources(state)
        {:error, error, state}
    end
  end

  defp partition_tools(state, tools) do
    clients = Map.get(state.config, :mcp_clients, %{})

    {deferred, eager} =
      Enum.split_with(tools, fn
        %Sigma.Coding.MCP.Tool{client: client, server_id: server} when not is_nil(client) ->
          clients[server] == client

        _ ->
          false
      end)

    {eager, deferred}
  end

  defp plugin_tools(nil), do: []
  defp plugin_tools(context), do: Map.get(context, :plugin_tools, [])

  defp mcp_clients(io, key) do
    # Release ChildIO before querying the root: root closure can synchronously
    # enter the child host. A second key check fences a concurrent followup.
    with {:ok, %{source: source, server_ids: server_ids}} <-
           GenServer.call(io, {:mcp_client_source, key}, :infinity),
         {:ok, clients} <- GenServer.call(source, :native_child_mcp_clients),
         :ok <- validate(io, key) do
      {:ok, Map.take(clients, server_ids)}
    end
  catch
    :exit, reason ->
      {:error, Error.new(:cancelled, "child MCP resource owner is unavailable", cause: reason)}
  end

  defp native_resources(%{codex_resources: nil} = state) do
    case CodexResources.start_link(
           workspace: state.config.cwd,
           owner_pid: self(),
           plugins: state.config[:native_plugins],
           host_retirement: state.host_retirement,
           lifetime_recovery:
             if(state.lifetime_recovery,
               do: %{
                 writer: state.lifetime_recovery,
                 store_ref: Path.join(state.identity.child_session_id, "runtime")
               }
             ),
           archive: child_archive(state),
           memory_root:
             Map.get(
               state.config,
               :native_memory_root,
               Path.join(apply(Sigma.Session.ConfigManager, :agent_dir, []), "memories")
             )
         ) do
      {:ok, resources} -> {:ok, %{state | codex_resources: resources}}
      {:error, error} -> {:error, error, state}
    end
  end

  defp native_resources(state) do
    case native_session_status(state.codex_resources) do
      %{phase: :idle} ->
        {:ok, state}

      status when status == :unavailable or :erlang.map_get(:phase, status) == :closed ->
        # A confirmed CodexResources.close stops its owned Session. Only the
        # resource owner can distinguish that from an unexpected Session loss;
        # its idempotent close retains confirmation or returns unknown_outcome.
        with {:ok, %{status: :confirmed}} <- close_native_resources(state) do
          GenServer.stop(state.codex_resources, :normal)
          native_resources(%{state | codex_resources: nil, native_context: nil})
        else
          {:error, error} -> {:error, error, state}
        end

      _ ->
        {:error, Error.new(:resource_conflict, "child native resource closure is unconfirmed"),
         state}
    end
  catch
    :exit, reason ->
      {:error,
       Error.new(:unknown_outcome, "child native resources are unavailable", cause: reason),
       state}
  end

  defp child_archive(state) do
    case state.config[:native_archive] do
      archive when is_map(archive) ->
        Map.merge(archive, %{
          agent_name: state.identity.agent_path,
          child_session_id: state.identity.child_session_id
        })

      nil ->
        nil
    end
  end

  defp native_session_status(resources) do
    Session.status(CodexResources.session(resources))
  catch
    :exit, _reason -> :unavailable
  end

  defp close_native_resources(%{codex_resources: nil}), do: {:ok, %{status: :confirmed}}
  defp close_native_resources(state), do: CodexResources.close(state.codex_resources)

  defp hydrate_plan(state, %{plan: plan}) do
    with {:ok, selected} <- apply(Writer, :selected_journal, [state.writer]),
         {:ok, saved} <-
           PlanProjection.latest_entries(selected.entries, leaf_id: selected.leaf_id),
         {:ok, current} <- Plan.read(plan) do
      content = if saved, do: Map.take(saved, ["plan", "explanation"]), else: %{}

      if current.content == content do
        :ok
      else
        case Plan.update(plan, current.revision, content) do
          {:ok, _} -> :ok
          error -> error
        end
      end
    end
  end

  defp build_context(state, messages, tools) do
    ContextBuilder.build(
      messages:
        messages
        |> Hooks.prepend_context(state.hook_context)
        |> Hooks.async_messages(state.hook_async_contexts),
      session_context: Map.get(state.config, :session_context) || SessionContext.new(),
      system_prompt: Map.get(state.config, :system_prompt),
      tools: tools,
      cwd: state.config.cwd,
      model: state.config.model
    )
    |> ContextBuilder.with_execution_environment(CodexResources.environment(state.native_context))
  end

  defp execute(io, key, operation) do
    with {:ok, tools, opts} <- GenServer.call(io, {:tool_context, key, operation}, :infinity) do
      call = %{
        id: operation.tool_call_id,
        name: operation.tool_name,
        arguments: operation.arguments,
        type: :tool_call
      }

      result = Dispatcher.dispatch(call, tools, opts)

      case GenServer.call(io, {:tool_boundary, key}, :infinity) do
        :ok -> result
        {:error, _error} = error -> error
      end
    end
  end

  defp dispatcher_options(state) do
    identity = state.identity
    io = self()
    key = state.key
    config = state.config

    opts =
      Map.get(config, :dispatcher_opts, [])
      |> Keyword.drop([
        :permission_request_fn,
        :ask_user_question_fn,
        :tool_state,
        :on_tool_fact,
        :on_tool_update,
        :on_update
      ])
      |> Keyword.merge(
        observed_permission_denials: true,
        cwd: config.cwd,
        permission_policy: resolve_policy(Map.get(config, :policy)),
        session_id: identity.child_session_id,
        log_session_id: identity.child_session_id,
        turn_id: public_run_id(identity),
        request_id: state.current_request_id,
        transcript_path: state.transcript_path,
        tool_state: state.tool_state,
        hook_specs: Map.get(config, :hook_specs, []),
        model: hook_context(state).model,
        agent_id: state.identity.agent_id,
        agent_type: Map.get(state.identity, :agent_type, "default"),
        mcp_hook_executor: Map.get(config, :mcp_hook_executor),
        hook_async_runtime: state.hook_async_runtime,
        hook_async_callback: Hooks.async_callback(state.hook_async_contexts),
        on_tool_fact: fn fact -> GenServer.call(io, {:tool_fact, key, fact}, :infinity) end
      )

    opts =
      if config[:task_supervisor],
        do: Keyword.put(opts, :task_supervisor, config.task_supervisor),
        else: opts

    opts =
      if state.permission_request_fn do
        Keyword.put(opts, :permission_request_fn, fn call ->
          state.permission_request_fn.(identity, call)
        end)
      else
        opts
      end

    if state.ask_user_question_fn do
      Keyword.put(opts, :ask_user_question_fn, fn request, tool_opts ->
        state.ask_user_question_fn.(identity, request, tool_opts)
      end)
    else
      opts
    end
  end

  defp hook_context(state) do
    Hooks.context(state.config, %{
      session_id: state.identity.child_session_id,
      turn_id: public_run_id(state.identity),
      transcript_path: state.transcript_path,
      agent_id: state.identity.agent_id,
      agent_type: Map.get(state.identity, :agent_type, "default"),
      mcp_hook_executor: Map.get(state.config, :mcp_hook_executor),
      hook_async_runtime: state.hook_async_runtime,
      hook_async_callback: Hooks.async_callback(state.hook_async_contexts),
      native_async_hooks: %{writer: state.writer}
    })
  end

  defp provider_event({:backplane_request_started, worker, ref, request, context}, state) do
    notify(state, :streaming_provider)

    state =
      state
      |> Map.put(:hook_delivery_started, true)
      |> Map.put(:request, request)
      |> Map.put(:catalog_tools, context.tools)
      |> Map.put(:current_request_id, request.request_id)
      |> append({:metrics, :request_started, request_fact(request)})
      |> schedule_hook_delivery(0)

    result = if state.persistence_error, do: {:error, state.persistence_error}, else: :ok
    send(worker, {:backplane_request_ready, ref, result})
    state
  end

  defp provider_event({:backplane_request_progress, request}, state),
    do: %{state | request: request}

  defp provider_event({:backplane_request_finished, request}, state),
    do: finish_request(state, request)

  defp provider_event({:backplane_provider_boundary, worker, ref, request}, state) do
    state = finish_request(state, request)
    send(worker, {:backplane_provider_continue, ref})
    state
  end

  defp provider_event(_event, state), do: state

  defp finish_request(state, request) do
    if MapSet.member?(state.finished_requests, request.request_id) do
      state
    else
      state = append(state, {:metrics, :request_finished, request_fact(request)})

      %{
        state
        | request: nil,
          finished_requests: MapSet.put(state.finished_requests, request.request_id)
      }
    end
  end

  defp project_messages(state, messages) do
    previous = Map.new(state.messages, fn message -> {Map.get(message, :id), message} end)

    messages =
      messages
      |> Enum.with_index()
      |> Enum.map(fn {raw, index} ->
        message = raw |> canonical_message(index) |> then(&restore_hook_message(state, &1))

        if MapSet.member?(state.persisted, message.id),
          do: Map.get(previous, message.id, message),
          else: project_plan(state, message, raw)
      end)

    messages
    |> Enum.reduce_while({:ok, state}, fn message, {:ok, state} ->
      if MapSet.member?(state.persisted, message.id) do
        {:cont, {:ok, state}}
      else
        case apply(Writer, :append, [state.writer, {:message_end, message}]) do
          {:ok, _entry_id} ->
            {:cont, {:ok, %{state | persisted: MapSet.put(state.persisted, message.id)}}}

          {:error, reason} ->
            error = Error.new(:execution_failure, "child journal append failed", cause: reason)
            {:halt, {{:error, error}, %{state | persistence_error: error}}}
        end
      end
    end)
    |> case do
      {:ok, state} -> {:ok, %{state | messages: messages}}
      {error, state} -> {error, state}
    end
  end

  defp project_plan(
         %{native_context: %{session_binding: binding, plan: plan}} = state,
         %{role: :tool_result, tool_name: name} = message,
         %{native_effect_success: true}
       )
       when name in ["update_plan", "exec", "wait"] do
    origin = %{
      run_id: binding.run_id,
      incarnation: binding.run_incarnation,
      tool_call_id: message.tool_call_id,
      tool_name: name
    }

    with {:ok, _} <- Session.validate(binding, origin),
         {:ok, observed} <- PlanProjection.capture_state(origin, Plan.read(plan)),
         previous = PlanProjection.latest(state.messages),
         false <-
           previous != nil and
             Map.take(previous, ["plan", "explanation"]) ==
               Map.take(observed, ["plan", "explanation"]) do
      metadata =
        Map.merge(message.metadata, %{native_plan: observed, native_effect_success: true})

      %{message | metadata: metadata}
    else
      _ -> message
    end
  catch
    :exit, _ -> message
  end

  defp project_plan(_state, message, _raw), do: message

  defp canonical_message(%Message{} = message, _index), do: message

  defp canonical_message(%{role: :tool} = message, index) do
    [normalized] = Provider.normalize_messages([message])
    %{normalized | id: "msg_child_tool_#{index}_#{message.tool_call_id}"}
  end

  defp canonical_message(message, _index) do
    [normalized] = Provider.normalize_messages([message])
    normalized
  end

  defp append(state, event) do
    case apply(Writer, :append, [state.writer, event]) do
      {:ok, _entry_id} ->
        state

      {:error, reason} ->
        %{
          state
          | persistence_error:
              Error.new(:execution_failure, "child metrics append failed", cause: reason)
        }
    end
  end

  defp request_fact(%ProviderRequest{} = request) do
    usage = if request.usage, do: ProviderUsage.to_fact(request.usage), else: %{}

    request
    |> Map.take([
      :request_id,
      :message_id,
      :session_id,
      :origin_session_id,
      :turn_id,
      :purpose,
      :status,
      :elapsed_ms,
      :first_output_ms,
      :ttft_ms
    ])
    |> Map.merge(usage)
    |> Map.merge(%{
      revision: request.usage_revision,
      provider: request.model[:provider],
      model: request.model[:id],
      started_at: iso(request.started_at),
      finished_at: iso(request.finished_at)
    })
  end

  defp hook_conversation_name(io, key),
    do: {:via, Registry, {Sigma.Agent.RepositoryRegistry, {__MODULE__, io, key}}}

  defp schedule_hook_delivery(%{hook_delivery_task: %Task{}} = state, _delay), do: state
  defp schedule_hook_delivery(%{retiring: true} = state, _delay), do: state
  defp schedule_hook_delivery(%{hook_delivery_timer: {_timer, _token}} = state, _delay), do: state

  defp schedule_hook_delivery(%{persistence_error: error} = state, _delay)
       when not is_nil(error),
       do: state

  defp schedule_hook_delivery(state, delay) do
    token = make_ref()
    timer = Process.send_after(self(), {:hook_delivery_tick, token}, delay)
    %{state | hook_delivery_timer: {timer, token}}
  end

  defp start_hook_delivery(%{hook_delivery_task: %Task{}} = state), do: state
  defp start_hook_delivery(%{retiring: true} = state), do: state
  defp start_hook_delivery(%{hook_delivery_started: false} = state), do: state
  defp start_hook_delivery(%{prepared: nil} = state), do: state
  defp start_hook_delivery(%{persistence_error: error} = state) when not is_nil(error), do: state

  defp start_hook_delivery(state) do
    async? =
      Enum.any?(Map.get(state.config, :hook_specs, []), fn spec ->
        spec.event == :post_tool_use and match?(%{async: true}, spec.handler)
      end)

    if state.config[:native_tools] == true and async? do
      io = self()
      key = state.key
      name = hook_conversation_name(io, key)
      pending = state.hook_delivery_pending |> Map.keys() |> MapSet.new()

      supervisor =
        Map.get(state.config, :task_supervisor) || Sigma.Coding.Dispatcher.TaskSupervisor

      task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          deliver_hook_feedback(io, key, name, state.writer, state.store, pending)
        end)

      %{state | hook_delivery_task: task}
    else
      state
    end
  end

  defp deliver_hook_feedback(io, key, name, writer, store, pending) do
    if active_hook_conversation?(name, key) do
      case HookDelivery.next(writer, store, elem(key, 0), pending) do
        {:ok, message} ->
          with :ok <- GenServer.call(io, {:hook_dispatching, key, message}, :infinity),
               :ok <- validate(io, key),
               true <- active_hook_conversation?(name, key),
               {:ok, %{message_id: runtime_id}} <- Conversation.steer(name, message.content),
               :ok <- HookDelivery.admitted(writer, message, runtime_id) do
            {:admitted, message, runtime_id}
          else
            reason ->
              case HookDelivery.unknown(writer, message, inspect(reason)) do
                :ok -> {:failed, message}
                {:error, error} -> {:delivery_error, error}
              end
          end

        :none ->
          :none

        {:error, error} ->
          {:delivery_error, error}
      end
    else
      :inactive
    end
  catch
    :exit, reason -> {:delivery_error, {:child_hook_destination_unavailable, reason}}
  end

  # Once a run is active it can become terminal/cancelling, never idle again.
  # Check the public identity as well as phase; steering an idle Conversation
  # would start a new turn without a real child prompt.
  defp active_hook_conversation?(name, {run_id, incarnation}) do
    case Conversation.status(name) do
      %{phase: :running, run: %{run_id: ^run_id, incarnation: ^incarnation}} -> true
      _ -> false
    end
  catch
    :exit, _ -> false
  end

  defp restore_hook_message(state, %{id: id} = message) do
    case Map.get(state.hook_delivery_admissions, id) do
      nil ->
        message

      canonical ->
        message
        |> Map.put(:id, canonical.id)
        |> Map.put(:metadata, Map.merge(canonical.metadata, Map.get(message, :metadata, %{})))
    end
  end

  defp restore_hook_message(_state, message), do: message

  defp defer_hook_call(state, from, operation),
    do: %{state | hook_delivery_waiters: state.hook_delivery_waiters ++ [{from, operation}]}

  defp release_hook_calls(state) do
    Enum.reduce(state.hook_delivery_waiters, %{state | hook_delivery_waiters: []}, fn
      {from, _operation}, %{persistence_error: error} = state when not is_nil(error) ->
        GenServer.reply(from, {:error, error})
        state

      {from, {:prompt, message}}, state ->
        GenServer.reply(from, {:ok, restore_hook_message(state, message)})
        state
    end)
  end

  defp reconcile_hook_delivery(%{hook_delivery_task: %Task{}} = state), do: state

  defp reconcile_hook_delivery(state) do
    pending =
      Map.reject(state.hook_delivery_pending, fn {id, _message} ->
        MapSet.member?(state.persisted, id)
      end)

    state = %{state | hook_delivery_pending: pending}

    case HookDelivery.reconcile(state.writer, state.store, pending |> Map.keys() |> MapSet.new()) do
      :ok -> state
      {:error, error} -> hook_delivery_error(state, error)
    end
  end

  defp retire_hook_delivery(state) do
    if state.hook_delivery_task, do: Task.shutdown(state.hook_delivery_task, :brutal_kill)
    if state.hook_delivery_timer, do: Process.cancel_timer(elem(state.hook_delivery_timer, 0))

    Enum.each(state.hook_delivery_waiters, fn {from, _operation} ->
      GenServer.reply(from, stale())
    end)

    %{
      state
      | hook_delivery_task: nil,
        hook_delivery_timer: nil,
        hook_delivery_pending: %{},
        hook_delivery_admissions: %{},
        hook_delivery_waiters: []
    }
    |> reconcile_hook_delivery()
  end

  defp hook_delivery_error(state, error),
    do: %{
      state
      | persistence_error:
          Error.new(:execution_failure, "child hook delivery failed", cause: error)
    }

  defp notify(%{notify: notify, identity: identity}, phase) when is_function(notify, 2),
    do: notify.(identity, phase)

  defp notify(_state, _phase), do: :ok

  defp contract_name(contract),
    do:
      Map.get(contract, :tool_name) ||
        Backplane.AgentRuntime.Codex.Contract.canonical_name(
          Map.get(contract, :namespace),
          contract.name
        )

  defp public_run_id(identity), do: Map.get(identity, :public_run_id, identity.run_id)
  defp resolve_policy(nil), do: nil
  defp resolve_policy(policy) when is_pid(policy) or is_atom(policy), do: policy
  defp resolve_policy(policy), do: GenServer.whereis(policy)
  defp iso(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp iso(_time), do: nil
  defp stale, do: {:error, Error.new(:resource_conflict, "stale child IO run")}
end
