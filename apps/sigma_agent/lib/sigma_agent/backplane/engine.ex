defmodule Sigma.Agent.Backplane.Engine do
  @moduledoc false

  alias Backplane.AgentRuntime.{Codex.Contract, Conversation, Error, Plan}

  alias Sigma.Agent.Backplane.{
    AsyncDelivery,
    CanonicalHistory,
    CodexResources,
    ContextControls,
    GoalIntegration,
    HookDelivery,
    HostedTools,
    InteractionResponder,
    LifetimeRecovery,
    NativeTools,
    PlanProjection,
    ToolCatalog,
    UserInput
  }

  alias Sigma.Agent.{ContextBuilder, Message}
  alias Sigma.Coding.Tool

  @poll_interval 10

  def run(state, turn_id) do
    authority = authority(state, turn_id)

    with {:ok, hosted} <- prepare_hosted(state),
         {:ok, collaboration} <- prepare_collaboration(state, authority),
         {:ok, collaboration} <- prepare_goal(state, authority, collaboration) do
      case release_goal_runtime(state) do
        :ok ->
          # From this acknowledged handoff onward Runtime may start. Later
          # preparation/startup failures keep ordinary indexed-run recovery.
          state = %{state | hook_execution: nil}

          {state, outcome} =
            run_prepared(
              state,
              turn_id,
              authority,
              Map.put(collaboration, :provider_hosted, hosted)
            )

          if state.native_tools and outcome != :completed do
            case Sigma.Agent.Subagents.close_execution(state.subagents) do
              {:ok, %{status: :confirmed}} ->
                {state, outcome}

              {:error, error} ->
                Sigma.Agent.__backplane_emit__(state, {:turn_error, normalize_error(error)})
                {state, :failed}
            end
          else
            {state, outcome}
          end

        {:error, error} ->
          stop_prepared_goal(state, error)
      end
    else
      {:host_preparation_failed, error} ->
        host_preparation_failed(state, error)

      {:error, error} ->
        Sigma.Agent.__backplane_emit__(state, {:turn_error, normalize_error(error)})
        {state, :failed}
    end
  end

  defp release_goal_runtime(%{goal_execution_admission: nil}), do: :ok

  defp release_goal_runtime(state),
    do: GoalIntegration.start_runtime(state.goal_integration, state.goal_execution_admission)

  defp stop_prepared_goal(state, error) do
    # Successful Goal binding already committed its run index. A failed or
    # uncertain handoff retains that binding/index and ordinary recovery; it
    # must not be converted to a host settlement from a missing Store.
    Sigma.Agent.__backplane_emit__(state, {:turn_error, normalize_error(error)})

    case Sigma.Agent.Subagents.close_execution(state.subagents) do
      {:ok, %{status: :confirmed}} ->
        {state, :failed}

      {:error, cleanup_error} ->
        Sigma.Agent.__backplane_emit__(state, {:turn_error, normalize_error(cleanup_error)})
        {state, :failed}
    end
  end

  defp host_preparation_failed(state, error) do
    normalized = normalize_error(error)
    Sigma.Agent.__backplane_emit__(state, {:turn_error, normalized})

    terminal =
      if match?(%Error{class: :cancelled}, error),
        do: %{"status" => "cancelled"},
        else: %{"status" => "failed", "reason" => normalized.message}

    {state, {:goal_host_stopped, terminal}}
  end

  defp run_prepared(state, turn_id, authority, collaboration) do
    {eager, deferred} = partition_tools(state)

    with {:ok, collaboration} <- prepare_discovery(state, turn_id, collaboration, deferred),
         :ok <- hydrate_plan(state, collaboration.native_context),
         {:ok, profiles} <- native_profiles(state, turn_id, authority, collaboration),
         authority <- %{
           authority
           | grants:
               Enum.map(eager, &Tool.name/1) ++
                 Enum.map(
                   collaboration.contracts,
                   &Contract.canonical_name(&1.namespace, &1.name)
                 ) ++
                 Enum.flat_map(profiles, &Map.keys(&1.registry.tools))
         },
         {:ok, catalog} <-
           catalog(state, turn_id, eager, authority, collaboration.contracts, profiles),
         {:ok, conversation, responder} <-
           start_conversation(state, turn_id, catalog, collaboration) do
      state = %{
        state
        | backplane_catalog_tools: catalog.tools,
          backplane_catalog_revision: Conversation.status(conversation).catalog_revision
      }

      try do
        case Conversation.prompt(conversation, List.last(state.messages).content) do
          {:ok, admission} ->
            initial = List.last(state.messages)

            require_async_delivery(
              AsyncDelivery.runtime_admitted(state.writer, initial, turn_id, admission.message_id)
            )

            require_hook_feedback(admit_hook_feedback(state, initial, admission.message_id))

            loop(
              state,
              conversation,
              turn_id,
              %{admission.message_id => initial},
              MapSet.new(),
              nil,
              collaboration.native_context
            )

          {:error, error} ->
            Sigma.Agent.__backplane_emit__(state, {:turn_error, normalize_error(error)})
            {state, :failed}
        end
      after
        if Process.alive?(conversation), do: GenServer.stop(conversation, :normal)
        stop_responder(responder)
      end
    else
      {:error, error} ->
        error =
          if collaboration.binding do
            case Sigma.Agent.Subagents.close_execution(state.subagents) do
              {:error, cleanup_error} -> cleanup_error
              _ -> error
            end
          else
            error
          end

        Sigma.Agent.__backplane_emit__(state, {:turn_error, normalize_error(error)})
        {state, :failed}
    end
  end

  defp prepare_discovery(%{native_tools: false}, _turn_id, collaboration, _deferred),
    do: {:ok, collaboration}

  defp prepare_discovery(state, turn_id, collaboration, deferred) do
    context = collaboration.native_context

    with {:ok, plugins} <-
           CodexResources.plugin_tools(context.codex_resources, collaboration.binding),
         {:ok, candidates} <-
           ToolCatalog.deferred_candidates(deferred ++ plugins, execute(state, turn_id, plugins)),
         {:ok, context} <-
           CodexResources.context(context.codex_resources, collaboration.binding,
             candidates: candidates
           ) do
      context = GoalIntegration.native_context(context, collaboration[:goal_context])
      {:ok, %{collaboration | native_context: Map.put(context, :plugin_tools, plugins)}}
    end
  end

  defp partition_tools(%{native_tools: false, tools: tools}), do: {tools, []}

  defp partition_tools(state) do
    {deferred, eager} =
      Enum.split_with(state.tools, fn
        %Sigma.Coding.MCP.Tool{client: client, server_id: server} when not is_nil(client) ->
          state.mcp_session.clients[server] == client

        _ ->
          false
      end)

    {eager, deferred}
  end

  defp hydrate_plan(_state, nil), do: :ok

  defp hydrate_plan(state, %{plan: plan}) do
    with {:ok, saved} <- selected_plan(state),
         {:ok, actual} <- Plan.read(plan) do
      content = if saved, do: Map.take(saved, ["plan", "explanation"]), else: %{}

      if actual.content == content do
        :ok
      else
        case Plan.update(plan, actual.revision, content) do
          {:ok, _} -> :ok
          error -> error
        end
      end
    end
  catch
    :exit, _ -> {:error, Error.new(:execution_failure, "native plan hydration is unavailable")}
  end

  defp selected_plan(%{writer: nil, messages: messages}),
    do: {:ok, PlanProjection.latest(messages)}

  defp selected_plan(%{writer: writer}) do
    with {:ok, selected} <- apply(Sigma.Session.Writer, :selected_journal, [writer]),
         {:ok, saved} <-
           PlanProjection.latest_entries(selected.entries, leaf_id: selected.leaf_id) do
      {:ok, saved}
    else
      {:error, reason} ->
        {:error,
         Error.new(:execution_failure, "selected plan journal is unavailable", cause: reason)}
    end
  end

  defp project_plan(
         state,
         %{tool_name: name} = tool,
         %{message: %{invocation_id: invocation_id}},
         %{plan: plan} = context
       )
       when name in ["update_plan", "exec", "wait"] do
    binding = context.session_binding

    origin = %{
      run_id: binding.run_id,
      incarnation: binding.run_incarnation,
      tool_call_id: tool.tool_call_id,
      tool_name: name
    }

    operation = %{run_id: origin.run_id, incarnation: origin.incarnation}

    with {:ok, _} <- Backplane.AgentRuntime.Codex.Session.validate(binding, operation),
         {:ok, %{run: %{run_id: run_id, incarnation: incarnation} = run}} <-
           Sigma.Agent.Backplane.Store.load(state.backplane_store, origin.run_id),
         true <- run_id == origin.run_id and incarnation == origin.incarnation,
         %{is_error: false} = actual <- get_in(run, [:tool_results, invocation_id]),
         false <- Map.has_key?(actual, :error),
         {:ok, observed} <- PlanProjection.capture_state(origin, Plan.read(plan)),
         {:ok, previous} <- selected_plan(state),
         false <- same_plan?(observed, previous) do
      metadata = Map.merge(tool.metadata, %{native_plan: observed, native_effect_success: true})
      %{tool | metadata: metadata}
    else
      _ -> tool
    end
  catch
    :exit, _ -> tool
  end

  defp project_plan(_state, tool, _event, _context), do: tool

  defp same_plan?(_observed, nil), do: false

  defp same_plan?(observed, previous),
    do: Map.take(observed, ["plan", "explanation"]) == Map.take(previous, ["plan", "explanation"])

  # Provider configuration can fail without a Conversation. Validate it before
  # reserving a Session or durably indexing a Goal-bound run.
  @doc false
  def prepare_hosted(%{native_tools: false}), do: {:ok, nil}

  def prepare_hosted(state),
    do: HostedTools.configuration(state.provider, state.model, state.provider_options)

  defp native_profiles(%{native_tools: false}, _turn_id, _authority, _prepared), do: {:ok, []}

  defp native_profiles(state, turn_id, authority, %{
         native_context: context,
         provider_hosted: hosted
       }) do
    selected = native_names(state, context[:plugin_tools] || [])

    owner = self()

    context =
      Map.put(context, :context_remaining, fn ->
        ContextControls.request(owner, :remaining, turn_id)
      end)

    context =
      if Enum.any?(selected, &(&1 in NativeTools.resource_names())) do
        Map.put(context, :mcp_clients, fn ->
          GenServer.call(state.control_pid, {:native_mcp_clients, turn_id})
        end)
      else
        context
      end

    hooks =
      state
      |> Sigma.Agent.__backplane_hook_context__(turn_id)
      |> Map.put(:hook_specs, state.hook_specs)

    hooks =
      if state.writer,
        do: Map.put(hooks, :native_async_hooks, %{writer: state.writer}),
        else: hooks

    context = Map.put(context, :provider_hosted, hosted)

    with {:ok, profile} <- NativeTools.profile(context, authority, hooks, tools: selected),
         do: {:ok, [profile]}
  end

  defp start_conversation(state, turn_id, catalog, collaboration) do
    binding = collaboration.binding
    initial_prompt = :atomics.new(1, signed: false)
    stop_hook_active = :atomics.new(1, signed: false)
    initial_message = List.last(state.messages)
    self_owner = self()

    host = %{
      model: state.model,
      provider: state.provider,
      provider_options: state.provider_options,
      session_id: state.session_id,
      log_session_id: state.log_session_id,
      initial_prompt: initial_prompt,
      stop_hook_active: stop_hook_active,
      hook_specs: state.hook_specs,
      hook_context: Sigma.Agent.__backplane_hook_context__(state, turn_id),
      initial_message: initial_message,
      native_tool_names: native_names(state, collaboration.native_context[:plugin_tools] || []),
      context_window: fn -> ContextControls.request(self_owner, :window, turn_id) end,
      build_context: fn messages, window, tools ->
        messages = canonical_user_messages(self_owner, turn_id, messages)

        Sigma.Agent.__backplane_build_context__(state, messages, tools, window)
        |> ContextBuilder.with_execution_environment(
          CodexResources.environment(collaboration.native_context)
        )
      end,
      context_error: &Sigma.Agent.__backplane_context_error__(state, &1),
      stop_hook: &Sigma.Agent.__backplane_stop_hook__(state, turn_id, &1, &2)
    }

    permission_options = Sigma.Agent.__backplane_permission_options__(state, turn_id)

    context = %{
      host: host,
      owner: self(),
      provider_lifecycle_store: if(state.native_tools, do: state.backplane_store),
      permission_options: permission_options,
      permission_interaction: state.native_tools
    }

    with {:ok, responder} <- start_responder(state, turn_id, permission_options) do
      opts = [
        run_id: turn_id,
        store: Sigma.Agent.Backplane.Store,
        context: state.backplane_store,
        provider: Sigma.Agent.Backplane.Provider,
        provider_context: context,
        hooks: Sigma.Agent.Backplane.Hooks,
        registry: catalog.registry,
        tools: catalog.tools,
        hosted_tools: catalog.hosted_tools,
        subscriber: responder || self(),
        messages:
          CanonicalHistory.runtime_messages(
            Enum.drop(Sigma.Agent.__backplane_context_messages__(state), -1)
          ),
        authority: catalog.authority,
        work: 100,
        provider_output_limit: :infinity,
        run_timeout: :infinity,
        effect_timeout: 300_000
      ]

      opts = if binding, do: Keyword.put(opts, :session_binding, binding), else: opts

      opts =
        opts
        |> Keyword.merge(GoalIntegration.conversation_options(collaboration[:goal_context]))
        |> Keyword.put(:goal_trigger, goal_trigger(initial_message))

      case Conversation.start_link(opts) do
        {:ok, conversation} ->
          observed = observe_executor(collaboration.native_context, conversation, turn_id)

          attached =
            with :ok <- observed,
                 do:
                   if(responder,
                     do: InteractionResponder.attach(responder, conversation),
                     else: :ok
                   )

          case attached do
            :ok ->
              {:ok, conversation, responder}

            error ->
              GenServer.stop(conversation, :normal)
              stop_responder(responder)
              error
          end

        error ->
          stop_responder(responder)
          error
      end
    end
  end

  defp observe_executor(
         %{lifetime_recovery: %{writer: writer}, session_binding: binding},
         conversation,
         turn_id
       ),
       do:
         LifetimeRecovery.observe_executor(
           writer,
           %{run_id: turn_id, incarnation: binding.run_incarnation},
           conversation
         )

  defp observe_executor(_context, _conversation, _turn_id), do: :ok

  defp start_responder(%{native_tools: false}, _turn_id, _opts), do: {:ok, nil}

  defp start_responder(state, turn_id, opts) do
    permission =
      Keyword.get(opts, :permission_request_fn, fn call ->
        {:deny, {:approval_required, call.name}}
      end)

    InteractionResponder.start_link(
      run_id: turn_id,
      incarnation: 1,
      owner_pid: state.control_pid,
      subscriber: self(),
      permission_request_fn: permission,
      runtime_permission_request_fn: Keyword.get(opts, :runtime_permission_request_fn),
      user_input_request_fn: UserInput.resolver(state.control_pid)
    )
  end

  defp stop_responder(nil), do: :ok

  defp stop_responder(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
  catch
    :exit, {:noproc, _} -> :ok
  end

  defp authority(state, turn_id) do
    collaboration = if state.subagents, do: Sigma.Agent.Subagents.collaboration_tools(), else: []

    %{
      caller: state.session_id || "sigma",
      run_id: turn_id,
      grants:
        Enum.map(state.tools, &Tool.name/1) ++
          collaboration ++ native_names(state),
      tool_revision: 1
    }
  end

  defp native_names(%{native_tools: false}), do: []

  defp native_names(state, plugin_tools \\ nil) do
    resources =
      if map_size(state.mcp_session.clients) > 0, do: NativeTools.resource_names(), else: []

    {_, deferred} = partition_tools(state)

    discovery =
      if deferred != [] or plugin_tools not in [nil, []] or
           (is_nil(plugin_tools) and not is_nil(state.native_plugins)),
         do: NativeTools.discovery_names(),
         else: []

    async = if is_nil(state.writer), do: [], else: NativeTools.async_names()
    plugins = if state.native_plugins, do: NativeTools.plugin_names(), else: []

    archive =
      if not is_nil(state.writer) and is_binary(state.transcript_path) and
           state.transcript_path != "",
         do: NativeTools.archive_names(),
         else: []

    goals = if state.goal_integration, do: NativeTools.goal_names(), else: []
    board = if archive != [] and state.subagents, do: NativeTools.board_names(), else: []

    NativeTools.names() ++
      NativeTools.environment_names() ++
      resources ++
      discovery ++
      async ++
      plugins ++
      NativeTools.skill_names() ++
      NativeTools.memory_names() ++
      archive ++ goals ++ board
  end

  defp prepare_goal(%{goal_integration: nil}, _authority, collaboration),
    do: {:ok, collaboration}

  defp prepare_goal(state, authority, collaboration) do
    with {:ok, context} <-
           GoalIntegration.bind(state.goal_integration, authority,
             session_binding: collaboration.binding,
             provider: state.provider,
             admission: Map.get(state, :goal_execution_admission),
             mode: :execution
           ) do
      {:ok,
       collaboration
       |> Map.put(:goal_context, context)
       |> Map.update!(:native_context, &GoalIntegration.native_context(&1, context))}
    else
      {:error, error} ->
        # Collaboration already reserved a real Session. Goal preparation has
        # no Conversation to detach it, so close through its owning host before
        # another prompt can prepare a generation.
        case Sigma.Agent.Subagents.close(state.subagents) do
          {:ok, %{status: :confirmed}} ->
            if state.goal_execution_admission,
              do: {:host_preparation_failed, error},
              else: {:error, error}

          {:error, cleanup_error} ->
            Sigma.Agent.__backplane_emit__(state, {:turn_error, normalize_error(error)})
            {:error, cleanup_error}
        end
    end
  end

  defp goal_trigger(%{metadata: %{goal_continuation: true}}), do: :goal
  defp goal_trigger(_message), do: :user

  defp prepare_collaboration(%{subagents: nil}, _authority),
    do: {:ok, %{contracts: [], binding: nil, native_context: nil}}

  defp prepare_collaboration(state, authority) do
    Sigma.Agent.Subagents.prepare_root(state.subagents, %{
      authority: authority,
      config: Sigma.Agent.Subagents.configuration(state),
      store: state.backplane_store
    })
  end

  defp catalog(state, turn_id, tools, authority, contracts, profiles) do
    ToolCatalog.admit(
      tools,
      authority,
      execute(state, turn_id),
      contracts: contracts,
      profiles: profiles,
      mode: :quarantine
    )
  end

  defp execute(_state, turn_id, additional_tools \\ []) do
    owner = self()

    fn operation ->
      ref = make_ref()
      send(owner, {:backplane_tool_context, self(), ref})

      current =
        receive do
          {:backplane_tool_context, ^ref, current} -> current
        end

      current = %{current | tools: current.tools ++ additional_tools}
      result = Sigma.Agent.__backplane_dispatch_tool__(current, turn_id, operation, owner)
      send(owner, {:backplane_tool_boundary, self(), ref})

      receive do
        {:backplane_tool_continue, ^ref} -> result
      end
    end
  end

  defp loop(state, conversation, turn_id, users, forwarded, assistant, native_context) do
    state = ready_pending_request(state)
    Sigma.Agent.__backplane_acknowledge__(state)

    receive do
      {:agent_runtime, ^turn_id, event} ->
        {state, users, assistant, terminal} =
          reduce_event(state, event, users, assistant, native_context)

        case terminal do
          nil -> loop(state, conversation, turn_id, users, forwarded, assistant, native_context)
          outcome -> finish(state, conversation, outcome)
        end

      {:backplane_request_started, worker, ref, request, context} ->
        state = %{state | backplane_pending_request: {worker, ref, request, context}}
        loop(state, conversation, turn_id, users, forwarded, assistant, native_context)

      {:backplane_context_control, worker, ref, kind, ^turn_id} ->
        status = Conversation.status(conversation)

        result =
          case kind do
            :window -> ContextControls.window(status, turn_id)
            :remaining -> remaining_context(state, status, turn_id, native_context)
          end

        send(worker, {:backplane_context_control, ref, result})
        loop(state, conversation, turn_id, users, forwarded, assistant, native_context)

      {:backplane_context_control, worker, ref, _kind, _stale_run} ->
        send(worker, {:backplane_context_control, ref, nil})
        loop(state, conversation, turn_id, users, forwarded, assistant, native_context)

      {:backplane_canonical_users, worker, ref, ^turn_id, messages} ->
        messages =
          Enum.map(messages, fn
            %{role: :user, id: id} = message -> Map.get(users, id, message)
            message -> message
          end)

        send(worker, {:backplane_canonical_users, ref, {:ok, messages}})
        loop(state, conversation, turn_id, users, forwarded, assistant, native_context)

      {:backplane_canonical_users, worker, ref, _stale_run, _messages} ->
        send(worker, {:backplane_canonical_users, ref, {:error, :stale_run}})
        loop(state, conversation, turn_id, users, forwarded, assistant, native_context)

      {:backplane_collaboration_messages, messages} ->
        state = capture_canonical(state, messages)

        loop(state, conversation, turn_id, users, forwarded, assistant, native_context)

      {:backplane_tool_context, worker, ref} ->
        send(worker, {:backplane_tool_context, ref, state})
        loop(state, conversation, turn_id, users, forwarded, assistant, native_context)

      {:backplane_tool_boundary, worker, ref} ->
        {state, users, forwarded} =
          forward_steering(state, conversation, turn_id, users, forwarded)

        send(worker, {:backplane_tool_continue, ref})
        loop(state, conversation, turn_id, users, forwarded, assistant, native_context)

      {:backplane_provider_boundary, worker, ref, request} ->
        {state, users, forwarded} =
          forward_steering(state, conversation, turn_id, users, forwarded)

        state = Sigma.Agent.__backplane_request_finished__(state, request)
        send(worker, {:backplane_provider_continue, ref})
        loop(state, conversation, turn_id, users, forwarded, assistant, native_context)

      {:backplane_request_progress, request} ->
        loop(
          %{state | backplane_request: request},
          conversation,
          turn_id,
          users,
          forwarded,
          assistant,
          native_context
        )

      {:backplane_request_finished, request} ->
        state = Sigma.Agent.__backplane_request_finished__(state, request)
        loop(state, conversation, turn_id, users, forwarded, assistant, native_context)

      {:backplane_synthetic_user, message} ->
        Sigma.Agent.__backplane_emit__(state, {:message_start, message})
        Sigma.Agent.__backplane_emit__(state, {:message_end, message})

        loop(
          %{state | messages: state.messages ++ [message]}
          |> Sigma.Agent.__backplane_messages_changed__(),
          conversation,
          turn_id,
          users,
          forwarded,
          assistant,
          native_context
        )

      {:backplane_tool_update, tool_call, update} ->
        Sigma.Agent.__backplane_emit__(
          state,
          {:tool_execution_update, tool_call.id, tool_call.name, tool_call.arguments, update}
        )

        loop(state, conversation, turn_id, users, forwarded, assistant, native_context)

      {:cancel, _ref} ->
        _ = Conversation.cancel(conversation)
        loop(state, conversation, turn_id, users, forwarded, assistant, native_context)

      {:abort, _ref} ->
        loop(state, conversation, turn_id, users, forwarded, assistant, native_context)
    after
      @poll_interval ->
        {state, users, forwarded} =
          forward_steering(state, conversation, turn_id, users, forwarded)

        loop(state, conversation, turn_id, users, forwarded, assistant, native_context)
    end
  end

  defp ready_pending_request(%{backplane_pending_request: nil} = state), do: state

  defp ready_pending_request(
         %{backplane_pending_request: {worker, ref, request, context}} = state
       ) do
    window = Map.get(context, :runtime_context_window)

    # Runtime events may travel through the interaction responder while this
    # request comes directly from the Provider task. Reduce those earlier events
    # and durably acknowledge the matching boundary before releasing HTTP.
    cancelled? = GenServer.call(state.control_pid, {:cancelled?, request.turn_id}, :infinity)

    if cancelled? do
      send(worker, {:backplane_request_ready, ref, {:error, :cancelled}})
      %{state | backplane_pending_request: nil}
    else
      release_pending_request(state, window, worker, ref, request, context)
    end
  end

  defp release_pending_request(state, window, worker, ref, request, context) do
    if is_nil(window) or window.window == 1 or state.context_window == window do
      state = %{
        state
        | backplane_catalog_tools: context.tools,
          backplane_catalog_revision: context.catalog_revision
      }

      state = Sigma.Agent.__backplane_request_started__(state, request, context)
      Sigma.Agent.__backplane_acknowledge__(state)
      if is_pid(state.control_pid), do: Sigma.Agent.status(state.control_pid)
      send(worker, {:backplane_request_ready, ref, :ok})
      %{state | backplane_pending_request: nil}
    else
      state
    end
  end

  defp remaining_context(state, status, turn_id, native_context) do
    with %{run_id: ^turn_id} = window <- ContextControls.window(status, turn_id),
         true <- status.catalog_revision == state.backplane_catalog_revision do
      context =
        Sigma.Agent.__backplane_build_context__(
          state,
          Sigma.Agent.Backplane.Provider.normalize_messages(status.messages),
          state.backplane_catalog_tools,
          window
        )
        |> ContextBuilder.with_execution_environment(CodexResources.environment(native_context))

      snapshot =
        Sigma.Agent.ContextPolicy.snapshot(
          model: state.model,
          system: context.system,
          messages: context.messages,
          tools: context.tools
        )

      ContextControls.tokens_left(snapshot,
        model: state.model,
        context_limit: state.context_limit,
        output_reserve:
          Sigma.Ai.Provider.output_token_limit(
            state.provider,
            state.model,
            state.provider_options
          )
      )
    else
      _ -> nil
    end
  end

  defp forward_steering(state, conversation, turn_id, users, forwarded) do
    case GenServer.call(state.control_pid, {:peek_steering, turn_id}, :infinity) do
      %{message_id: message_id} = item ->
        if MapSet.member?(forwarded, message_id) do
          {state, users, forwarded}
        else
          forward_steering_item(state, conversation, turn_id, item, users, forwarded)
        end

      :cancelled ->
        {state, users, forwarded}

      _none ->
        forward_hook_feedback(state, conversation, turn_id, users, forwarded)
    end
  end

  defp forward_hook_feedback(
         %{native_tools: true, writer: writer} = state,
         conversation,
         turn_id,
         users,
         forwarded
       )
       when not is_nil(writer) do
    pending =
      users |> Map.values() |> Enum.filter(&HookDelivery.message?/1) |> MapSet.new(& &1.id)

    case HookDelivery.next(writer, state.backplane_store, turn_id, pending) do
      {:ok, message} ->
        case Conversation.steer(conversation, message.content) do
          {:ok, %{message_id: runtime_id}} ->
            case HookDelivery.admitted(writer, message, runtime_id) do
              :ok ->
                :ok

              _ ->
                require_hook_feedback(
                  HookDelivery.unknown(writer, message, "admission_receipt_unconfirmed")
                )
            end

            {state, Map.put(users, runtime_id, message), MapSet.put(forwarded, message.id)}

          {:error, _error} ->
            require_hook_feedback(
              HookDelivery.unknown(writer, message, "runtime_admission_unconfirmed")
            )

            {state, users, MapSet.put(forwarded, message.id)}
        end

      :none ->
        {state, users, forwarded}

      {:error, error} ->
        require_hook_feedback({:error, error})
    end
  end

  defp forward_hook_feedback(state, _conversation, _turn_id, users, forwarded),
    do: {state, users, forwarded}

  defp admit_hook_feedback(%{writer: writer} = state, message, runtime_id)
       when not is_nil(writer) do
    with :ok <- HookDelivery.admitted(writer, message, runtime_id),
         do: HookDelivery.reconcile(writer, state.backplane_store)
  end

  defp admit_hook_feedback(_state, _message, _runtime_id), do: :ok

  defp require_hook_feedback(:ok), do: :ok

  defp require_hook_feedback(error),
    do: throw({:event_persistence_failed, :hook_feedback, error})

  defp require_async_delivery(:ok), do: :ok

  defp require_async_delivery(error),
    do: throw({:event_persistence_failed, :async_interaction, error})

  # Conversation admits content and supplies its own message ID. Restore only
  # users recorded under that exact admission ID, including async reply metadata.
  defp canonical_user_messages(owner, turn_id, messages) do
    monitor = Process.monitor(owner)
    ref = make_ref()
    send(owner, {:backplane_canonical_users, self(), ref, turn_id, messages})

    try do
      receive do
        {:backplane_canonical_users, ^ref, {:ok, canonical}} ->
          canonical

        {:backplane_canonical_users, ^ref, {:error, reason}} ->
          raise Sigma.Ai.ProviderError.from_exception(reason)

        {:DOWN, ^monitor, :process, ^owner, reason} ->
          raise Sigma.Ai.ProviderError.from_exception({:backplane_owner_down, reason})
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp forward_steering_item(state, conversation, turn_id, item, users, forwarded) do
    message = Message.user(item.message_id, item.content)
    message = %{message | metadata: Map.merge(Map.get(item, :metadata, %{}), %{turn_id: turn_id})}

    case Sigma.Agent.__backplane_prompt_hook__(state, message) do
      {:block, reason} ->
        Sigma.Agent.__backplane_emit__(state, {:prompt_rejected, item.message_id, reason})

        :ok =
          GenServer.call(state.control_pid, {:ack_steering, turn_id, item.message_id}, :infinity)

        {state, users, MapSet.put(forwarded, item.message_id)}

      {:ok, message, state} ->
        case Conversation.steer(conversation, message.content) do
          {:ok, %{message_id: runtime_id}} ->
            require_async_delivery(
              AsyncDelivery.runtime_admitted(state.writer, message, turn_id, runtime_id)
            )

            {state, Map.put(users, runtime_id, message), MapSet.put(forwarded, item.message_id)}

          {:error, _error} ->
            {state, users, forwarded}
        end
    end
  end

  defp reduce_event(
         state,
         %{type: :tool_completed, message: message} = event,
         users,
         assistant,
         native_context
       ) do
    tool = tool_message(message, state.turn_state.turn_id)
    tool = project_plan(state, tool, event, native_context)
    content = tool.content

    Sigma.Agent.__backplane_emit__(
      state,
      {:tool_execution_end, tool.tool_call_id, tool.tool_name, content, tool.is_error}
    )

    Sigma.Agent.__backplane_emit__(state, {:message_start, tool})
    Sigma.Agent.__backplane_emit__(state, {:message_end, tool})
    results = state.backplane_tool_results ++ [tool]

    if length(results) == Enum.count(assistant.content, &match?(%{type: :tool_call}, &1)) do
      Sigma.Agent.__backplane_emit__(state, {:turn_end, assistant, results})
    end

    state =
      %{state | messages: state.messages ++ [tool], backplane_tool_results: results}
      |> Sigma.Agent.__backplane_messages_changed__()

    reconcile_async(state)

    {state, users, assistant, nil}
  end

  defp reduce_event(state, event, users, assistant, _native_context),
    do: reduce_event(state, event, users, assistant)

  defp reduce_event(state, %{type: :context_window_started} = event, users, assistant) do
    window = Map.take(event, [:run_id, :incarnation, :window])
    state = Sigma.Agent.__backplane_context_window__(state, window)
    {state, users, assistant, nil}
  end

  defp reduce_event(state, %{type: type}, users, assistant)
       when type in [:async_user_input_requested, :async_user_message] do
    # These transport events may precede settlement. Only public Store records
    # reconciled at the completed-tool boundary can create durable cards.
    reconcile_async(state)
    {state, users, assistant, nil}
  end

  defp reduce_event(
         state,
         %{type: :provider_hosted_event, capability: "web_search", event: frame},
         users,
         assistant
       ) do
    case HostedTools.observe(frame) do
      {:ok, _} ->
        Sigma.Agent.__backplane_emit__(state, {:provider_hosted_event, "web_search", frame})
        {state, users, assistant, nil}

      {:error, error} ->
        Sigma.Agent.__backplane_emit__(state, {:turn_error, normalize_error(error)})
        {state, users, assistant, :failed}
    end
  end

  defp reduce_event(state, %{type: :response_started} = event, users, _assistant) do
    message = assistant_message(event)
    Sigma.Agent.__backplane_emit__(state, {:message_start, message})
    {state, users, message, nil}
  end

  defp reduce_event(state, %{type: type} = event, users, _assistant)
       when type in [
              :content_text_delta,
              :content_thinking_delta,
              :tool_call_started,
              :tool_call_arguments_delta,
              :tool_call_completed
            ] do
    message = assistant_message(event)
    Sigma.Agent.__backplane_emit__(state, {:message_update, message, legacy_event(event)})
    {state, users, message, nil}
  end

  defp reduce_event(state, %{type: :response_completed} = event, users, _assistant) do
    message = assistant_message(event)
    Sigma.Agent.__backplane_emit__(state, {:message_end, message})

    if not Enum.any?(message.content, &match?(%{type: :tool_call}, &1)) do
      Sigma.Agent.__backplane_emit__(state, {:turn_end, message, []})
    end

    state =
      %{state | messages: state.messages ++ [message], backplane_tool_results: []}
      |> Sigma.Agent.__backplane_messages_changed__()

    {state, users, message, nil}
  end

  defp reduce_event(state, %{type: :tool_started, invocation: invocation}, users, assistant) do
    Sigma.Agent.__backplane_phase__(state, :running_tools)

    Sigma.Agent.__backplane_emit__(
      state,
      {:tool_execution_start, invocation.tool_call_id, invocation.tool_name, invocation.arguments}
    )

    {state, users, assistant, nil}
  end

  defp reduce_event(
         state,
         %{type: :prompt_consumed, mode: :steering, message: message},
         users,
         assistant
       ) do
    canonical = Map.get(users, message.id, to_user_message(message))
    Sigma.Agent.__backplane_emit__(state, {:message_start, canonical})
    Sigma.Agent.__backplane_emit__(state, {:message_end, canonical})

    if HookDelivery.message?(canonical) do
      require_hook_feedback(HookDelivery.reconcile(state.writer, state.backplane_store))
    else
      :ok =
        GenServer.call(
          state.control_pid,
          {:ack_steering, state.turn_state.turn_id, canonical.id},
          :infinity
        )
    end

    Sigma.Agent.__backplane_emit__(
      state,
      {:prompt_consumed, :steering,
       %{message_id: canonical.id, turn_id: state.turn_state.turn_id}}
    )

    state =
      %{state | messages: state.messages ++ [canonical]}
      |> Sigma.Agent.__backplane_messages_changed__()

    {state, users, assistant, nil}
  end

  defp reduce_event(
         state,
         %{type: :turn_failed, error: %Error{class: :budget_exceeded} = error},
         users,
         assistant
       ) do
    Sigma.Agent.__backplane_emit__(state, {:turn_error, normalize_error(error)})
    {state, users, assistant, nil}
  end

  defp reduce_event(state, %{type: :turn_failed}, users, assistant),
    do: {state, users, assistant, nil}

  defp reduce_event(state, %{type: :run_completed}, users, assistant),
    do: {state, users, assistant, :completed}

  defp reduce_event(state, %{type: :run_failed}, users, assistant),
    do: {state, users, assistant, :failed}

  defp reduce_event(state, %{type: :run_cancelled} = event, users, assistant) do
    cancelled? =
      GenServer.call(state.control_pid, {:cancelled?, state.turn_state.turn_id}, :infinity)

    outcome = if cancelled?, do: :cancelled, else: :failed

    if not cancelled?,
      do: Sigma.Agent.__backplane_emit__(state, {:turn_error, normalize_error(event)})

    {state, users, assistant, outcome}
  end

  defp reduce_event(state, %{type: :storage_failed, error: error}, users, assistant) do
    Sigma.Agent.__backplane_emit__(state, {:turn_error, normalize_error(error)})
    {state, users, assistant, :failed}
  end

  defp reduce_event(state, %{type: :response_failed, error: error}, users, assistant) do
    Sigma.Agent.__backplane_emit__(state, {:turn_error, normalize_error(error)})
    {state, users, assistant, nil}
  end

  defp reduce_event(state, _event, users, assistant), do: {state, users, assistant, nil}

  defp finish(state, conversation, outcome) do
    reconcile_async(state)

    if state.writer,
      do: require_hook_feedback(HookDelivery.reconcile(state.writer, state.backplane_store))

    state =
      capture_canonical(
        state,
        CanonicalHistory.checkpoint_messages(Conversation.status(conversation))
      )

    state =
      case state.backplane_request do
        nil ->
          state

        request ->
          finished =
            Sigma.Ai.ProviderRequest.finish(
              request,
              outcome,
              System.monotonic_time(:millisecond),
              DateTime.utc_now()
            )

          Sigma.Agent.__backplane_request_finished__(state, finished)
      end

    Sigma.Agent.__backplane_acknowledge__(state)
    {state, outcome}
  end

  defp reconcile_async(%{writer: nil}), do: :ok

  defp reconcile_async(state) do
    GenServer.call(
      state.control_pid,
      {:reconcile_async_interactions, state.turn_state.turn_id},
      :infinity
    )
  end

  defp capture_canonical(state, messages) do
    Enum.reduce(Sigma.Agent.Backplane.Provider.normalize_messages(messages), state, fn message,
                                                                                       acc ->
      if Enum.any?(acc.messages, &(&1.id == message.id)) do
        acc
      else
        Sigma.Agent.__backplane_emit__(acc, {:message_start, message})
        Sigma.Agent.__backplane_emit__(acc, {:message_end, message})

        %{acc | messages: acc.messages ++ [message]}
        |> Sigma.Agent.__backplane_messages_changed__()
      end
    end)
  end

  defp assistant_message(%{message: message} = event) do
    id =
      Map.get(message, :id) ||
        "msg_assistant_#{Map.get(event, :attempt_id, System.unique_integer([:positive]))}"

    Sigma.Agent.__backplane_assistant_message__(
      message,
      id,
      Map.get(event, :run_id) || Map.get(event, :turn_id)
    )
  end

  defp tool_message(%{role: :tool} = message, turn_id) do
    [normalized] = Sigma.Agent.Backplane.Provider.normalize_messages([message])
    %{normalized | id: "msg_tool_res_#{turn_id}_#{message.tool_call_id}"}
  end

  defp to_user_message(message), do: Message.user(message.id, message.content)

  defp legacy_event(%{type: :content_text_delta} = event),
    do: {:text_delta, Map.get(event, :index, 0), Map.get(event, :delta, ""), event.message}

  defp legacy_event(%{type: :content_thinking_delta} = event),
    do: {:thinking_delta, Map.get(event, :index, 0), Map.get(event, :delta, ""), event.message}

  defp legacy_event(%{type: :tool_call_started} = event),
    do: {:toolcall_start, Map.get(event, :index, 0), event.message}

  defp legacy_event(%{type: :tool_call_arguments_delta} = event),
    do: {:toolcall_delta, Map.get(event, :index, 0), Map.get(event, :delta, ""), event.message}

  defp legacy_event(%{type: :tool_call_completed} = event),
    do: {:toolcall_end, Map.get(event, :index, 0), event.tool_call, event.message}

  defp normalize_error(%Sigma.Ai.ProviderError{} = error), do: error

  defp normalize_error(
         %Error{
           class: :resource_conflict,
           message: "provider output limit exceeded",
           details: %{scope: :provider_response, size: size, limit: limit}
         } = error
       ) do
    %Sigma.Ai.ProviderError{
      kind: :output_limit,
      message:
        "Provider output limit exceeded (scope=provider_response, size=#{size}, limit=#{limit})",
      retryable: false,
      raw: error
    }
  end

  defp normalize_error(error), do: Sigma.Ai.ProviderError.from_exception(error)
end
