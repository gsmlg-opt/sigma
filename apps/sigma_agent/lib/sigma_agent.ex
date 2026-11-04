defmodule Sigma.Agent do
  @moduledoc """
  A GenServer that manages a single agent session.
  """
  use GenServer

  require Logger

  alias Sigma.Agent.Message
  alias Sigma.Agent.ContextBuilder
  alias Sigma.Agent.ContextPolicy
  alias Sigma.Agent.PromptQueue
  alias Sigma.Agent.SessionContext
  alias Sigma.Agent.TurnState
  alias Sigma.Ai.{Provider, ProviderError, ProviderEvent, ProviderRequest, ProviderUsage}
  alias Sigma.Ai.Providers.Anthropic
  alias Sigma.Coding.ToolError
  alias Sigma.Coding.Hooks.Outcome
  alias Sigma.Agent.Hooks

  alias Sigma.Agent.Backplane.{
    AsyncDelivery,
    AsyncInbox,
    GoalIntegration,
    HookDelivery,
    RootRetirement
  }

  alias Sigma.Protocol.{AsyncInteractions, AsyncReplyUploads}

  defstruct [
    :session_id,
    :log_session_id,
    :transcript_path,
    :model,
    :system_prompt,
    :session_context,
    :tools,
    :provider,
    :mcp_servers,
    :base_tools,
    :cwd,
    :on_event,
    :writer,
    :dispatcher_opts,
    :tool_state,
    :provider_options,
    :task_supervisor,
    :current_turn_task,
    :current_request_id,
    :context_snapshot,
    :context_policy,
    :context_limit,
    :context_window,
    :backplane_pending_request,
    :backplane_catalog_tools,
    :backplane_catalog_revision,
    :turn_started_at,
    :turn_started_monotonic,
    :control_pid,
    :last_cancelled_turn_id,
    :policy,
    :backplane_store,
    :backplane_store_owned,
    :backplane_store_path,
    :backplane_request,
    :subagents,
    :native_memory_root,
    :native_plugins,
    :start_hook_pending,
    :hook_async_contexts,
    :hook_async_runtime,
    :hook_execution,
    :host_retirement,
    :host_retirement_task,
    :host_retirement_stage,
    :host_recovery_task,
    :pending_host_prompt,
    :goal_integration,
    :goal_admission,
    :goal_execution_admission,
    :goal_executor_control,
    :goal_executor_settlement,
    :pending_goal_result,
    :goal_idle_task,
    goal_generation: 0,
    goal_idle_generation: 0,
    goal_resume_pending: false,
    goal_instruction_pending: false,
    context_excluded_message_ids: MapSet.new(),
    context_reconciliation_required: false,
    messages: [],
    subscribers: [],
    current_turn_resources: [],
    pending_user_questions: %{},
    pending_mcp_elicitations: %{},
    prompt_queue: %PromptQueue{},
    turn_state: %TurnState{},
    hook_specs: [],
    backplane_tool_results: [],
    native_tools: false,
    async_reply_messages: %{},
    async_interaction_signature: nil,
    async_interaction_error: nil,
    async_reply_uploads: %{},
    host_retirement_facts: %{},
    host_retirement_waiters: [],
    resume_source: :startup,
    mcp_session: %{handles: [], subscriptions: [], clients: %{}}
  ]

  @default_mcp_elicitation_timeout_ms 60_000
  @mcp_sampling_timeout_ms 60_000

  # Client API

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  def subscribe(pid) do
    GenServer.call(pid, {:subscribe, self()})
  end

  def subscribe_snapshot(pid) do
    GenServer.call(pid, {:subscribe_snapshot, self()})
  end

  def unsubscribe(pid) do
    GenServer.call(pid, {:unsubscribe, self()})
  end

  def prompt(pid, prompt_text, opts \\ []) do
    GenServer.call(pid, {:admit_prompt, prompt_text, opts, :auto}, :infinity)
  end

  def steer(pid, prompt_text, opts \\ []) do
    GenServer.call(pid, {:admit_prompt, prompt_text, opts, :steering}, :infinity)
  end

  def follow_up(pid, prompt_text, opts \\ []) do
    GenServer.call(pid, {:admit_prompt, prompt_text, opts, :follow_up}, :infinity)
  end

  def goal(pid) do
    with {:ok, handle} <- GenServer.call(pid, :goal_handle), do: GoalIntegration.get(handle)
  end

  def set_goal(pid, mutation, instruction) do
    with {:ok, handle} <- GenServer.call(pid, :goal_handle),
         {:ok, _} = result <- GoalIntegration.set(handle, mutation, instruction) do
      GenServer.cast(pid, :goal_changed)
      result
    end
  end

  def clear_goal(pid, instruction) do
    with {:ok, handle} <- GenServer.call(pid, :goal_handle),
         do: GoalIntegration.clear(handle, instruction)
  end

  def fork_goal(pid, target_writer, cwd, target_transcript) do
    with {:ok, handle} <- GenServer.call(pid, :goal_operation_handle),
         do: GoalIntegration.fork(handle, target_writer, cwd, target_transcript)
  end

  def retire_goal(pid), do: GenServer.call(pid, :retire_goal, :infinity)

  def retire_runtime_store(pid), do: GenServer.call(pid, :retire_runtime_store, :infinity)

  @doc false
  def retire_host(pid), do: GenServer.call(pid, :retire_host, :infinity)

  def async_interaction_snapshot(pid),
    do: GenServer.call(pid, :async_interaction_snapshot, :infinity)

  @doc "Resolves this session's configured plugin host outside its command loop."
  def plugin_installation_host(pid) do
    config = GenServer.call(pid, :plugin_installation_config)
    Sigma.Agent.Backplane.PluginResources.open(config)
  end

  def reply_async_interaction(pid, item_id, payload, expected_leaf_id),
    do:
      GenServer.call(
        pid,
        {:reply_async_interaction, item_id, payload, expected_leaf_id},
        :infinity
      )

  def dismiss_async_interaction(pid, item_id, expected_leaf_id),
    do: GenServer.call(pid, {:dismiss_async_interaction, item_id, expected_leaf_id}, :infinity)

  def upload_async_reply_chunk(pid, request),
    do: GenServer.call(pid, {:upload_async_reply_chunk, request}, :infinity)

  def commit_async_reply_upload(pid, request),
    do: GenServer.call(pid, {:commit_async_reply_upload, request}, :infinity)

  def cancel_async_reply_upload(pid, request),
    do: GenServer.call(pid, {:cancel_async_reply_upload, request}, :infinity)

  @doc "Changes the session context limit only after a successful idle-time persistence callback."
  def change_context_limit(pid, limit, persist) when is_function(persist, 0) do
    GenServer.call(pid, {:change_context_limit, limit, persist}, :infinity)
  end

  @doc "Adopts a session limit at an idle checkpoint only if the runtime has no configured limit."
  def ensure_context_limit(pid, limit) do
    GenServer.call(pid, {:ensure_context_limit, limit}, :infinity)
  end

  def status(pid), do: GenServer.call(pid, :status)

  @doc "Returns the current canonical transcript without replaying or executing messages."
  def messages(pid), do: GenServer.call(pid, :messages)

  def reload_context(pid, %SessionContext{} = session_context) do
    GenServer.call(pid, {:reload_context, session_context})
  end

  def context_preview(pid), do: GenServer.call(pid, :context_preview)

  @doc "Admits one replacement turn from an already validated persisted checkpoint."
  def retry(pid, context_messages, content, retry_of_turn_id, opts \\ []) do
    GenServer.call(
      pid,
      {:retry_checkpoint, context_messages, content, retry_of_turn_id, opts},
      :infinity
    )
  end

  def begin_session_operation(pid), do: GenServer.call(pid, :begin_session_operation)
  def end_session_operation(pid), do: GenServer.call(pid, :end_session_operation, :infinity)
  def compact(pid, opts \\ []), do: GenServer.call(pid, {:compact, opts}, :infinity)

  def ask_user_question(pid, request, opts \\ []) when is_map(request) do
    question_id = "ask_#{System.unique_integer([:positive])}"

    timeout = request[:timeout_ms] || Keyword.get(opts, :timeout, :infinity)

    case GenServer.call(pid, {:ask_user_question, question_id, self(), request}) do
      {:ok, ^question_id} ->
        wait_for_user_question_answer(pid, question_id, timeout)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def pending_user_questions(pid, timeout \\ 5_000) do
    GenServer.call(pid, :pending_user_questions, timeout)
  end

  def answer_user_question(pid, question_id, reply) when is_binary(question_id) do
    GenServer.call(pid, {:answer_user_question, question_id, reply})
  end

  @doc """
  Blocks until the LiveView answers an MCP elicitation request.

  Returns `{:accept, content}`, `:decline`, `:cancel`, or `{:error, reason}`.
  """
  def request_mcp_elicitation(pid, message, schema, opts \\ [])
      when is_binary(message) and is_map(schema) do
    elicitation_id = "mcp_elicit_#{System.unique_integer([:positive])}"
    timeout = Keyword.get(opts, :timeout, @default_mcp_elicitation_timeout_ms)

    case GenServer.call(
           pid,
           {:request_mcp_elicitation, elicitation_id, self(), message, schema},
           timeout
         ) do
      {:ok, ^elicitation_id} ->
        wait_for_mcp_elicitation_answer(pid, elicitation_id, timeout)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def pending_mcp_elicitations(pid, timeout \\ 5_000) do
    GenServer.call(pid, :pending_mcp_elicitations, timeout)
  end

  def answer_mcp_elicitation(pid, elicitation_id, reply) when is_binary(elicitation_id) do
    GenServer.call(pid, {:answer_mcp_elicitation, elicitation_id, reply})
  end

  def cancel(pid) do
    GenServer.call(pid, :cancel)
  end

  def cancel_prompt(pid, turn_id) when is_binary(turn_id) do
    GenServer.call(pid, {:cancel_prompt, turn_id})
  end

  @doc """
  Restarts the session's MCP clients and re-discovers their tools.

  Returns `{:ok, count}` with the number of MCP tools now available.
  """
  def reload_mcp_tools(pid) do
    GenServer.call(pid, :reload_mcp_tools, 30_000)
  end

  @doc """
  Updates the model used by subsequent turns. Has no effect on the
  currently in-flight turn (the model is captured into the provider
  request at turn start).
  """
  def set_model(pid, model) when is_map(model) do
    GenServer.cast(pid, {:set_model, model})
  end

  def set_provider(pid, provider, model, options \\ [])
      when is_atom(provider) and is_map(model) do
    GenServer.cast(pid, {:set_provider, provider, model, options})
  end

  def change_provider(pid, provider, model, options, persist)
      when is_atom(provider) and is_map(model) and is_function(persist, 0) do
    GenServer.call(pid, {:change_provider, provider, model, options, persist}, :infinity)
  end

  def get_policy(pid) do
    GenServer.call(pid, :get_policy)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    if Keyword.get(opts, :native_tools, false) and is_nil(opts[:subagents]) do
      {:stop, :native_tools_require_session_host}
    else
      case init_backplane_store(opts) do
        {:ok, store, owned?} -> init_agent(opts, store, owned?)
        {:error, reason} -> {:stop, reason}
      end
    end
  end

  defp init_agent(opts, backplane_store, backplane_store_owned) do
    task_supervisor =
      case Keyword.get(opts, :task_supervisor) do
        nil ->
          {:ok, pid} = Task.Supervisor.start_link()
          pid

        provided ->
          provided
      end

    policy =
      case Keyword.get(opts, :policy) do
        nil ->
          {:ok, pid} = Sigma.Coding.PermissionPolicy.start_link(default: :allow, rules: %{})
          pid

        provided ->
          provided
      end

    cwd = opts[:cwd] || File.cwd!()

    hook_specs =
      case Keyword.fetch(opts, :hook_specs) do
        {:ok, specs} when is_list(specs) -> specs
        :error -> Sigma.Coding.Hooks.Discovery.load(cwd)
      end

    context_snapshot =
      ContextPolicy.snapshot(
        context_revision: Keyword.get(opts, :context_revision, 0),
        active_leaf: Keyword.get(opts, :active_leaf),
        model: opts[:model],
        source: Keyword.get(opts, :context_source, :runtime_start),
        messages: opts[:context_messages] || opts[:messages] || [],
        system: :unknown,
        tools: :unknown,
        skills: :unknown,
        stale: true
      )

    {:ok, hook_async_runtime} = Sigma.Coding.Hooks.AsyncRuntime.start(self())

    state = %__MODULE__{
      task_supervisor: task_supervisor,
      policy: policy,
      session_id: opts[:session_id],
      log_session_id: opts[:log_session_id] || opts[:session_id],
      transcript_path: opts[:transcript_path],
      model: opts[:model],
      system_prompt: opts[:system_prompt],
      session_context: opts[:session_context] || SessionContext.new(),
      tools: opts[:tools] || [],
      base_tools: opts[:tools] || [],
      mcp_servers: opts[:mcp_servers] || %{},
      provider: opts[:provider] || Anthropic,
      messages: opts[:messages] || [],
      context_window: opts[:context_window],
      context_excluded_message_ids:
        excluded_context_ids(opts[:messages] || [], opts[:context_messages]),
      cwd: cwd,
      on_event: opts[:on_event],
      writer: opts[:writer],
      dispatcher_opts: opts[:dispatcher_opts] || [],
      tool_state:
        opts[:tool_state] ||
          :ets.new(:sigma_tools_state, [
            :set,
            :public,
            read_concurrency: true,
            write_concurrency: true
          ]),
      provider_options: opts[:options] || [],
      context_snapshot: context_snapshot,
      context_limit: opts[:context_limit],
      context_policy:
        context_policy(
          context_snapshot,
          opts[:provider] || Anthropic,
          opts[:model],
          opts[:options] || [],
          opts[:context_limit]
        ),
      hook_specs: hook_specs,
      start_hook_pending: :atomics.new(1, signed: false),
      hook_async_contexts: Hooks.async_contexts(),
      hook_async_runtime: hook_async_runtime,
      prompt_queue: PromptQueue.new(),
      turn_state: TurnState.idle(),
      resume_source:
        Keyword.get(
          opts,
          :resume_source,
          if((opts[:messages] || []) == [], do: :startup, else: :resume)
        ),
      backplane_store: backplane_store,
      backplane_store_owned: backplane_store_owned,
      backplane_store_path:
        opts[:backplane_runtime_path] || backplane_runtime_path(opts[:transcript_path]),
      native_tools: Keyword.get(opts, :native_tools, false),
      native_memory_root:
        Keyword.get_lazy(opts, :native_memory_root, fn ->
          Path.join(apply(Sigma.Session.ConfigManager, :agent_dir, []), "memories")
        end),
      native_plugins:
        Keyword.get_lazy(opts, :native_plugins, fn ->
          apply(Sigma.Session.ConfigManager, :get_plugin_config, [])
        end),
      subagents: opts[:subagents]
    }

    case init_goal(state) do
      {:ok, state} ->
        case RootRetirement.context(state) do
          {:ok, context} ->
            {:ok, %{state | host_retirement: context}, {:continue, :session_start}}

          {:error, reason} ->
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:session_start, state) do
    {:noreply, state |> start_mcp_clients() |> refresh_async_interactions() |> maybe_goal_idle()}
  end

  @impl true
  def terminate(reason, state) do
    release_all_resources(state)
    stop_goal_idle_task(state)
    stop_host_recovery_task(state)

    if state.native_tools do
      retire_root_on_terminate(state, reason)
    else
      Sigma.Coding.Hooks.AsyncRuntime.shutdown(state.hook_async_runtime)

      if reason in [:normal, :shutdown] or match?({:shutdown, _}, reason) do
        run_session_end_hook(state)
      end
    end

    Sigma.Coding.MCP.stop(state.mcp_session)
    GoalIntegration.close(state.goal_integration)
    stop_backplane_store(state)

    :ok
  end

  @impl true
  def handle_call({:subscribe, subscriber_pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: Enum.uniq([subscriber_pid | state.subscribers])}}
  end

  def handle_call({:subscribe_snapshot, subscriber_pid}, _from, state) do
    state = %{state | subscribers: Enum.uniq([subscriber_pid | state.subscribers])}
    {:reply, status_snapshot(state), state}
  end

  @impl true
  def handle_call({:unsubscribe, subscriber_pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: List.delete(state.subscribers, subscriber_pid)}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, status_snapshot(state), state}
  end

  def handle_call(:messages, _from, state) do
    {:reply, state.messages, state}
  end

  def handle_call(:plugin_installation_config, _from, state),
    do: {:reply, state.native_plugins, state}

  def handle_call(:goal_handle, _from, %{goal_integration: nil} = state),
    do: {:reply, {:error, :goal_unavailable}, state}

  def handle_call(:goal_handle, _from, state),
    do: {:reply, {:ok, state.goal_integration}, state}

  def handle_call(:goal_operation_handle, _from, state) do
    if not is_nil(state.goal_integration) and state.turn_state.phase == :session_operation and
         is_nil(state.pending_host_prompt),
       do: {:reply, {:ok, state.goal_integration}, state},
       else: {:reply, {:error, :session_busy}, state}
  end

  def handle_call(:retire_goal, _from, state) do
    if is_nil(state.current_turn_task) and is_nil(state.goal_idle_task) and
         is_nil(state.pending_host_prompt) do
      case GoalIntegration.close(state.goal_integration) do
        :ok -> {:reply, :ok, %{state | goal_integration: nil, goal_admission: nil}}
        error -> {:reply, error, state}
      end
    else
      {:reply, {:error, :session_busy}, state}
    end
  end

  def handle_call(:retire_runtime_store, _from, state) do
    cond do
      state.turn_state.phase != :session_operation or not is_nil(state.current_turn_task) or
        not is_nil(state.goal_idle_task) or not is_nil(state.goal_integration) or
          not is_nil(state.pending_host_prompt) ->
        {:reply, {:error, :session_busy}, state}

      is_nil(state.backplane_store) ->
        {:reply, :ok, state}

      not state.backplane_store_owned ->
        {:reply, {:error, :runtime_store_not_owned}, state}

      state.native_tools and
          not match?(%{completion: {:ok, %{status: :confirmed}}}, state.host_retirement_facts) ->
        {:reply, {:error, :host_retirement_unconfirmed}, state}

      true ->
        case Sigma.Agent.Backplane.Store.retire(state.backplane_store) do
          :ok -> {:reply, :ok, %{state | backplane_store: nil}}
          {:error, _} = error -> {:reply, error, state}
        end
    end
  end

  def handle_call(:retire_host, _from, %{native_tools: false} = state),
    do: {:reply, :ok, state}

  def handle_call(:retire_host, from, state) do
    cond do
      state.host_retirement_task ->
        {:noreply, %{state | host_retirement_waiters: [from | state.host_retirement_waiters]}}

      match?(%{completion: {:ok, %{status: :confirmed}}}, state.host_retirement_facts) ->
        {:reply, state.host_retirement_facts.completion, state}

      state.current_turn_task || state.goal_idle_task || state.pending_host_prompt ||
        state.host_recovery_task ||
          match?(%{status: :reserved}, state.goal_admission) ->
        {:reply, {:error, :session_busy}, state}

      true ->
        state = %{
          state
          | host_retirement_waiters: [from],
            turn_state: TurnState.transition(state.turn_state, :session_operation)
        }

        {:noreply, start_host_retirement(state)}
    end
  end

  def handle_call({:goal_record_instruction, thread, instruction}, _from, state) do
    content = instruction[:text] || instruction["text"]

    if goal_thread?(state, thread) and
         state.turn_state.phase not in [:session_operation, :cancelling] and is_binary(content) and
         content != "" do
      message =
        Message.user("msg_goal_#{random_id(8)}", content)
        |> Map.put(:metadata, %{goal_instruction: true})

      case apply(Sigma.Session.Writer, :append, [state.writer, {:message_end, message}]) do
        {:ok, _} ->
          notify_subscribers(state, {:message_start, message})
          notify_subscribers(state, {:message_end, message})

          state = %{
            state
            | messages: state.messages ++ [message],
              goal_instruction_pending:
                state.goal_instruction_pending or not is_nil(state.current_turn_task)
          }

          {:reply, :ok, invalidate_context(state, :goal_instruction)}

        {:error, reason} ->
          {:reply,
           {:error,
            Backplane.AgentRuntime.Error.new(
              :execution_failure,
              "Goal instruction persistence failed",
              cause: reason
            )}, state}
      end
    else
      {:reply,
       {:error,
        Backplane.AgentRuntime.Error.new(
          :resource_conflict,
          "Goal instruction requires an available owning session"
        )}, state}
    end
  end

  def handle_call({:goal_reserve, thread, request}, _from, state) do
    counts = PromptQueue.counts(state.prompt_queue)

    if goal_thread?(state, thread) and request.host_generation == state.goal_generation and
         is_nil(state.current_turn_task) and is_nil(state.goal_admission) and
         state.turn_state.phase not in [:cancelling, :session_operation] and
         counts == %{steering: 0, follow_up: 0} do
      case new_prompt_item(request.steering.text, []) do
        {:ok, item} ->
          item = %{item | metadata: %{goal_continuation: true}}
          reservation = %{request: request, item: item, status: :reserved}

          {:reply,
           {:ok, {:started, %{run_id: item.turn_id, incarnation: 1, turn_id: item.turn_id}}},
           %{state | goal_admission: reservation}}

        {:error, reason} ->
          {:reply,
           {:error,
            Backplane.AgentRuntime.Error.new(
              :validation,
              "Goal continuation prompt is invalid",
              cause: reason
            )}, state}
      end
    else
      {:reply, {:ok, {:not_submitted, :superseded}}, state}
    end
  end

  def handle_call({:goal_release, thread, admission}, _from, state) do
    case state.goal_admission do
      %{request: request, item: item, status: status}
      when request.reservation_token == admission.reservation_token and
             request.host_generation == admission.host_generation ->
        cond do
          not goal_thread?(state, thread) ->
            {:reply,
             {:error,
              Backplane.AgentRuntime.Error.new(
                :resource_conflict,
                "Goal continuation owner changed"
              )}, state}

          status in [:cancelled, :superseded] ->
            {:reply, {:ok, {:not_submitted, status}}, state}

          status == :reserved and is_nil(state.current_turn_task) and
              state.turn_state.phase != :session_operation ->
            # The Task waits for its coordinator's exact monitored release.
            # Only pure configuration preparation precedes that owner's
            # effect gate; later failures keep ordinary Runtime recovery.
            control = :atomics.new(1, signed: false)

            item =
              item
              |> Map.put(:goal_admission, admission)
              |> Map.put(:goal_executor_control, control)

            state = start_ready_turn(%{state | goal_admission: nil}, item)
            info = prompt_info(item, item.turn_id)
            emit(state, {:prompt_admitted, :accepted, info})
            emit_prompt_telemetry(state, :accepted)
            {:reply, {:ok, %{executor: state.current_turn_task.pid, control: control}}, state}

          true ->
            {:reply, {:ok, {:not_submitted, :superseded}},
             fence_goal_admission(state, :superseded)}
        end

      _ ->
        {:reply,
         {:error,
          Backplane.AgentRuntime.Error.new(
            :resource_conflict,
            "Goal continuation reservation is unavailable"
          )}, state}
    end
  end

  @impl true
  def handle_call({:reload_context, session_context}, _from, state) do
    if is_nil(state.current_turn_task) do
      :telemetry.execute(
        [:sigma, :context, :reloaded],
        %{count: 1},
        %{session_id: state.session_id}
      )

      {:reply, :ok, %{state | session_context: session_context}}
    else
      {:reply, {:error, :session_busy}, state}
    end
  end

  @impl true
  def handle_call(:context_preview, _from, state) do
    {:reply,
     %{
       text: SessionContext.to_text(state.session_context),
       injections: state.session_context.injections
     }, state}
  end

  @impl true
  def handle_call(:begin_session_operation, _from, state) do
    if is_nil(state.current_turn_task) and state.turn_state.phase != :session_operation and
         is_nil(state.goal_idle_task) and subagents_can_stop?(state) do
      {:reply, :ok,
       %{state | turn_state: TurnState.transition(state.turn_state, :session_operation)}}
    else
      {:reply, {:error, :session_busy}, state}
    end
  end

  @impl true
  def handle_call(:end_session_operation, from, state) do
    cond do
      state.host_retirement_task || state.pending_host_prompt ->
        {:reply, {:error, :session_busy}, state}

      state.turn_state.phase == :session_operation and
        map_size(state.host_retirement_facts) > 0 and
          not match?(%{completion: {:ok, %{status: :confirmed}}}, state.host_retirement_facts) ->
        state = %{state | host_retirement_waiters: [{:session_reopen, from}]}
        {:noreply, start_host_retirement(state)}

      true ->
        finish_session_operation(state)
    end
  end

  def handle_call({:compact, opts}, _from, state) do
    if state.turn_state.phase == :session_operation and is_nil(state.current_turn_task) and
         is_nil(state.pending_host_prompt) do
      {state, result} = run_compact(state, Keyword.put(opts, :trigger, :manual))
      {:reply, result, state}
    else
      {:reply, {:error, :session_busy}, state}
    end
  end

  def handle_call(
        {:retry_checkpoint, context_messages, content, retry_of_turn_id, opts},
        _from,
        state
      ) do
    cond do
      state.turn_state.phase != :session_operation or not is_nil(state.current_turn_task) or
          not is_nil(state.pending_host_prompt) ->
        release_resources(Keyword.get(opts, :prepared_resources, []))
        {:reply, {:rejected, :session_busy}, state}

      not is_list(context_messages) or not is_binary(retry_of_turn_id) or
          retry_of_turn_id == "" ->
        release_resources(Keyword.get(opts, :prepared_resources, []))
        {:reply, {:rejected, :invalid_retry_checkpoint}, state}

      true ->
        opts = Keyword.put(opts, :retry_of_turn_id, retry_of_turn_id)

        case new_prompt_item(content, opts) do
          {:ok, item} ->
            item =
              item
              |> Map.put(:retry_restore_messages, state.messages)
              |> Map.put(:retry_restore_context_window, state.context_window)
              |> Map.put(:retry_restore_context_excluded_ids, state.context_excluded_message_ids)

            state = %{
              state
              | messages: context_messages,
                context_window: Keyword.get(opts, :context_window),
                context_excluded_message_ids:
                  excluded_context_ids(context_messages, opts[:provider_context_messages])
            }

            state = start_turn(state, item)
            info = prompt_info(item, item.turn_id)
            emit(state, {:prompt_admitted, :accepted, info})
            emit_prompt_telemetry(state, :accepted)
            {:reply, {:accepted, info}, state}

          {:error, reason} ->
            release_resources(Keyword.get(opts, :prepared_resources, []))
            {:reply, {:rejected, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:admit_prompt, content, opts, requested_mode}, _from, state) do
    case admit_prompt(state, content, opts, requested_mode) do
      {result, state} -> {:reply, result, state}
    end
  end

  def handle_call(:async_interaction_snapshot, _from, state) do
    state = refresh_async_interactions(state)

    result =
      cond do
        state.async_interaction_error -> {:error, state.async_interaction_error}
        is_nil(state.writer) -> {:ok, %{items: [], leaf_id: nil}}
        true -> AsyncDelivery.snapshot(state.writer)
      end

    {:reply, result, state}
  end

  def handle_call({:reconcile_async_interactions, turn_id}, _from, state) do
    if state.turn_state.turn_id == turn_id do
      {:reply, :ok, refresh_async_interactions(state)}
    else
      {:reply, {:error, :turn_changed}, state}
    end
  end

  def handle_call({:reply_async_interaction, item_id, payload, expected_leaf}, _from, state) do
    state = refresh_async_interactions(state)
    {result, state} = admit_async_reply(state, item_id, payload, expected_leaf)
    {:reply, result, refresh_async_interactions(state)}
  end

  def handle_call({:dismiss_async_interaction, item_id, expected_leaf}, _from, state) do
    result =
      if is_nil(state.writer),
        do: {:error, :async_interactions_unavailable},
        else: AsyncDelivery.dismiss(state.writer, item_id, expected_leaf)

    {:reply, result, refresh_async_interactions(state)}
  end

  def handle_call({:upload_async_reply_chunk, request}, _from, state) do
    # Reading a selected view must not reconcile durable facts or dispatch a reply.
    with :ok <- AsyncReplyUploads.validate_request("async_interaction.reply_chunk", request),
         {:ok, _item} <- async_upload_origin(state, request) do
      upload_result(
        AsyncReplyUploads.append(state.async_reply_uploads, request, upload_time()),
        state
      )
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:commit_async_reply_upload, request}, _from, state) do
    case AsyncReplyUploads.reply(state.async_reply_uploads, request, upload_time()) do
      {:ok, uploads, payload} ->
        state = %{state | async_reply_uploads: uploads}

        with {:ok, item} <- async_upload_origin(state, request),
             item <-
               if(item["status"] in ~w(dispatching admitted consumed delivery_unknown),
                 do: Map.put(item, "status", "saved"),
                 else: item
               ),
             {:ok, _reply} <- AsyncInteractions.reply(payload, item) do
          state = refresh_async_interactions(state)

          {result, state} =
            admit_async_reply(state, request["itemId"], payload, request["expectedLeafId"])

          {:reply, result, refresh_async_interactions(state)}
        else
          {:error, _} = error -> {:reply, error, state}
        end

      {:error, reason, uploads} ->
        {:reply, {:error, reason}, %{state | async_reply_uploads: uploads}}
    end
  end

  def handle_call({:cancel_async_reply_upload, request}, _from, state) do
    upload_result(
      AsyncReplyUploads.cancel(state.async_reply_uploads, request, upload_time()),
      state
    )
  end

  @impl true
  def handle_call({:peek_steering, turn_id}, _from, state) do
    cond do
      state.turn_state.turn_id != turn_id -> {:reply, :cancelled, state}
      state.turn_state.phase == :cancelling -> {:reply, :cancelled, state}
      true -> {:reply, PromptQueue.peek(state.prompt_queue, :steering), state}
    end
  end

  @impl true
  def handle_call({:ack_steering, turn_id, message_id}, _from, state) do
    if state.turn_state.turn_id == turn_id do
      case PromptQueue.ack(state.prompt_queue, :steering, message_id) do
        {:ok, queue} ->
          state = %{
            state
            | prompt_queue: queue,
              async_reply_messages: Map.delete(state.async_reply_messages, message_id)
          }

          {:reply, :ok, refresh_async_interactions(state)}

        {:error, _reason} = error ->
          {:reply, error, state}
      end
    else
      {:reply, {:error, :turn_changed}, state}
    end
  end

  def handle_call({:register_skill_resource, turn_id, resource}, _from, state) do
    if state.turn_state.turn_id == turn_id and not is_nil(state.current_turn_task) and
         valid_prepared_resource?(resource) do
      register_skill_grant(state.tool_state, turn_id, resource)

      {:reply, :ok, %{state | current_turn_resources: [resource | state.current_turn_resources]}}
    else
      {:reply, {:error, :turn_changed}, state}
    end
  end

  @impl true
  def handle_call({:cancelled?, turn_id}, _from, state) do
    cancelled? =
      state.turn_state.turn_id == turn_id and state.turn_state.phase == :cancelling

    {:reply, cancelled?, state}
  end

  @impl true
  def handle_call({:native_mcp_clients, turn_id}, _from, state) do
    result =
      if state.native_tools and state.turn_state.turn_id == turn_id and
           not is_nil(state.current_turn_task) and state.turn_state.phase != :cancelling do
        {:ok, state.mcp_session.clients}
      else
        {:error,
         Backplane.AgentRuntime.Error.new(:cancelled, "MCP resource turn is no longer active")}
      end

    {:reply, result, state}
  end

  def handle_call(:native_child_mcp_clients, _from, state) do
    result =
      if state.native_tools and state.turn_state.phase != :cancelling do
        {:ok, state.mcp_session.clients}
      else
        {:error,
         Backplane.AgentRuntime.Error.new(:cancelled, "MCP resource owner is unavailable")}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:reload_mcp_tools, _from, state) do
    Sigma.Coding.MCP.stop(state.mcp_session)
    state = %{state | mcp_session: empty_mcp_session()} |> start_mcp_clients()
    mcp_count = length(state.tools) - length(state.base_tools)
    {:reply, {:ok, mcp_count}, state}
  end

  @impl true
  def handle_call(:cancel, _from, state) do
    cond do
      state.pending_host_prompt ->
        turn_id = state.pending_host_prompt.item.turn_id
        {:reply, {:cancelling, turn_id}, cancel_host_prompt(state)}

      match?(%{status: :reserved}, state.goal_admission) and is_nil(state.current_turn_task) ->
        turn_id = state.goal_admission.item.turn_id
        state = fence_goal_admission(state, :cancelled)
        {:reply, {:cancelling, turn_id}, %{state | last_cancelled_turn_id: turn_id}}

      state.turn_state.phase == :cancelling ->
        {:reply, {:already_cancelling, state.turn_state.turn_id}, state}

      is_nil(state.current_turn_task) and not is_nil(state.last_cancelled_turn_id) ->
        {:reply, {:already_cancelled, state.last_cancelled_turn_id}, state}

      is_nil(state.current_turn_task) ->
        {:reply, {:error, :no_active_turn}, state}

      fence_goal_executor_cancel(state) == :sealed ->
        # DOWN already sealed this admission. Its settlement acknowledgement
        # is still in flight; a new cancel cannot change that exact receipt.
        {:reply, {:error, :no_active_turn}, state}

      true ->
        state = fence_goal_admission(state, :cancelled)
        task = state.current_turn_task
        turn_id = state.turn_state.turn_id
        cancellation_ref = state.turn_state.cancellation_ref
        send(task.pid, {:cancel, cancellation_ref})
        send(task.pid, {:abort, cancellation_ref})
        state = cancel_pending_interactions(state)
        timer = Process.send_after(self(), {:force_cancel, turn_id, task.ref}, 2_000)

        turn_state =
          state.turn_state
          |> TurnState.transition(:cancelling)
          |> Map.put(:cancel_timer, timer)

        {:reply, {:cancelling, turn_id}, %{state | turn_state: turn_state}}
    end
  end

  def handle_call({:cancel_prompt, turn_id}, _from, state) do
    cond do
      match?(%{item: %{turn_id: ^turn_id}}, state.pending_host_prompt) ->
        {:reply, :ok, cancel_host_prompt(state)}

      match?(%{status: :reserved, item: %{turn_id: ^turn_id}}, state.goal_admission) and
          is_nil(state.current_turn_task) ->
        {:reply, :ok, fence_goal_admission(state, :cancelled)}

      state.turn_state.turn_id == turn_id and fence_goal_executor_cancel(state) == :sealed ->
        {:reply, :ok, state}

      state.turn_state.turn_id == turn_id and not is_nil(state.current_turn_task) ->
        state = fence_goal_admission(state, :cancelled)
        task = state.current_turn_task
        cancellation_ref = state.turn_state.cancellation_ref
        send(task.pid, {:cancel, cancellation_ref})
        send(task.pid, {:abort, cancellation_ref})
        state = cancel_pending_interactions(state)
        timer = Process.send_after(self(), {:force_cancel, turn_id, task.ref}, 2_000)

        turn_state =
          state.turn_state
          |> TurnState.transition(:cancelling)
          |> Map.put(:cancel_timer, timer)

        {:reply, :ok, %{state | turn_state: turn_state}}

      true ->
        case PromptQueue.remove(state.prompt_queue, :follow_up, turn_id) do
          {:ok, item, queue} ->
            release_resources(item.prepared_resources)
            {:reply, :ok, %{state | prompt_queue: queue}}

          {:error, :prompt_not_found} ->
            {:reply, {:error, :prompt_not_found}, state}
        end
    end
  end

  @impl true
  def handle_call(:get_policy, _from, state) do
    {:reply, state.policy, state}
  end

  @impl true
  def handle_call({:ensure_context_limit, limit}, from, %{context_limit: nil} = state) do
    handle_call({:change_context_limit, limit, fn -> :ok end}, from, state)
  end

  def handle_call({:ensure_context_limit, _limit}, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_call({:change_context_limit, limit, persist}, _from, state) do
    with {:ok, limit} <- ContextPolicy.parse_context_limit(limit),
         false <- TurnState.active?(state.turn_state) or not is_nil(state.current_turn_task),
         result when result == :ok or elem(result, 0) == :ok <- run_state_change(persist) do
      state = invalidate_context(%{state | context_limit: limit}, :context_limit_change)
      notify_subscribers(state, {:context_limit_changed, limit})
      {:reply, :ok, state}
    else
      true -> {:reply, {:error, :session_busy}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_call(
        {:change_provider, _provider, _model, _options, _persist},
        _from,
        %{turn_state: %{phase: :session_operation}} = state
      ) do
    {:reply, {:error, :session_busy}, state}
  end

  def handle_call({:change_provider, provider, model, options, persist}, _from, state) do
    case run_state_change(persist) do
      :ok ->
        state = %{state | provider: provider, model: model, provider_options: options}
        {:reply, :ok, invalidate_context(state, :model_change)}

      {:ok, _result} = success ->
        state = %{state | provider: provider, model: model, provider_options: options}
        {:reply, success, invalidate_context(state, :model_change)}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:ask_user_question, question_id, reply_to, request}, _from, state) do
    monitor_ref = Process.monitor(reply_to)

    pending_question = %{
      id: question_id,
      request: Map.put(request, :id, question_id),
      reply_to: reply_to,
      monitor_ref: monitor_ref,
      created_at: System.monotonic_time()
    }

    state = put_pending_user_question(state, question_id, pending_question)

    state =
      if request[:kind] == :permission,
        do: %{state | turn_state: TurnState.transition(state.turn_state, :waiting_permission)},
        else: state

    emit(state, {:ask_user_question, question_id, public_user_question(pending_question)})

    {:reply, {:ok, question_id}, state}
  end

  @impl true
  def handle_call(:pending_user_questions, _from, state) do
    {:reply, public_user_questions(state), state}
  end

  @impl true
  def handle_call({:answer_user_question, question_id, reply}, _from, state) do
    case Map.pop(pending_user_question_map(state), question_id) do
      {nil, _pending_questions} ->
        {:reply, {:error, :not_found}, state}

      {pending_question, pending_questions} ->
        Process.demonitor(pending_question.monitor_ref, [:flush])
        send(pending_question.reply_to, {:ask_user_question_reply, question_id, reply})

        state = put_pending_user_questions(state, pending_questions)
        state = restore_running_tools_phase(state, :waiting_permission)
        emit(state, {:ask_user_question_resolved, question_id})

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(
        {:request_mcp_elicitation, elicitation_id, reply_to, message, schema},
        _from,
        state
      ) do
    case elicitation_fields(schema) do
      :unsupported ->
        {:reply, {:error, :unsupported_schema}, state}

      fields ->
        monitor_ref = Process.monitor(reply_to)

        pending = %{
          id: elicitation_id,
          message: message,
          schema: schema,
          fields: fields,
          reply_to: reply_to,
          monitor_ref: monitor_ref,
          created_at: System.monotonic_time()
        }

        state = put_pending_mcp_elicitation(state, elicitation_id, pending)

        state = %{
          state
          | turn_state: TurnState.transition(state.turn_state, :waiting_elicitation)
        }

        emit(state, {:mcp_elicitation, elicitation_id, public_mcp_elicitation(pending)})

        {:reply, {:ok, elicitation_id}, state}
    end
  end

  @impl true
  def handle_call(:pending_mcp_elicitations, _from, state) do
    {:reply, public_mcp_elicitations(state), state}
  end

  @impl true
  def handle_call({:answer_mcp_elicitation, elicitation_id, reply}, _from, state) do
    case Map.pop(pending_mcp_elicitation_map(state), elicitation_id) do
      {nil, _pending} ->
        {:reply, {:error, :not_found}, state}

      {pending, pending_map} ->
        Process.demonitor(pending.monitor_ref, [:flush])
        send(pending.reply_to, {:mcp_elicitation_reply, elicitation_id, reply})

        state = put_pending_mcp_elicitations(state, pending_map)
        state = restore_running_tools_phase(state, :waiting_elicitation)
        emit(state, {:mcp_elicitation_resolved, elicitation_id})

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:mcp_sampling, params}, _from, state) do
    {:reply, run_mcp_sampling(state, params), state}
  end

  @impl true
  def handle_cast(:goal_changed, state),
    do: {:noreply, maybe_goal_idle(%{state | goal_resume_pending: true})}

  def handle_cast({:notify_subscribers, event}, state) do
    notify_subscribers(state, event)
    {:noreply, state}
  end

  def handle_cast({:set_model, model}, state) do
    {:noreply, state |> Map.put(:model, model) |> invalidate_context(:model_change)}
  end

  @impl true
  def handle_cast({:set_provider, provider, model, options}, state) do
    state = %{state | provider: provider, model: model, provider_options: options}
    {:noreply, invalidate_context(state, :model_change)}
  end

  @impl true
  def handle_cast({:expire_user_question, question_id}, state) do
    case Map.pop(pending_user_question_map(state), question_id) do
      {nil, _pending_questions} ->
        {:noreply, state}

      {pending_question, pending_questions} ->
        Process.demonitor(pending_question.monitor_ref, [:flush])

        state = put_pending_user_questions(state, pending_questions)
        emit(state, {:ask_user_question_resolved, question_id})

        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:expire_mcp_elicitation, elicitation_id}, state) do
    case Map.pop(pending_mcp_elicitation_map(state), elicitation_id) do
      {nil, _pending} ->
        {:noreply, state}

      {pending, pending_map} ->
        Process.demonitor(pending.monitor_ref, [:flush])

        state = put_pending_mcp_elicitations(state, pending_map)
        emit(state, {:mcp_elicitation_resolved, elicitation_id})

        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:turn_phase, turn_id, phase}, state) do
    if state.turn_state.turn_id == turn_id and
         state.turn_state.phase not in [:cancelling, :session_operation] do
      {:noreply, %{state | turn_state: TurnState.transition(state.turn_state, phase)}}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:current_request, turn_id, request_id}, state) do
    if state.turn_state.turn_id == turn_id do
      {:noreply, %{state | current_request_id: request_id}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:prompt, prompt_text}, state) do
    handle_cast({:prompt, prompt_text, []}, state)
  end

  @impl true
  def handle_cast({:prompt, prompt_text, opts}, state) do
    {_result, state} = admit_prompt(state, prompt_text, opts, :auto)
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {ref, {:root_retirement, facts}},
        %{host_retirement_task: %{ref: ref}} = state
      ) do
    Process.demonitor(ref, [:flush])
    {:noreply, complete_host_retirement(state, facts)}
  end

  def handle_info(
        {ref, {:host_completion, result}},
        %{host_retirement_task: %{ref: ref}} = state
      ) do
    Process.demonitor(ref, [:flush])
    facts = Map.put(state.host_retirement_facts, :completion, result)
    {:noreply, settle_host_retirement(state, facts)}
  end

  def handle_info(
        {ref, {:host_inspection, result}},
        %{host_recovery_task: %{ref: ref}} = state
      ) do
    Process.demonitor(ref, [:flush])
    state = %{state | host_recovery_task: nil}

    state =
      case {state.pending_host_prompt.cancelled?, result} do
        {true, _} -> finish_host_prompt(state, :cancelled, nil)
        {false, {:ok, false}} -> start_host_prompt(state)
        {false, {:ok, true}} -> start_host_retirement(state)
        {false, {:error, reason}} -> finish_host_prompt(state, :failed, reason)
      end

    {:noreply, state}
  end

  def handle_info(
        {ref, {:host_recovery, result}},
        %{host_recovery_task: %{ref: ref}} = state
      ) do
    Process.demonitor(ref, [:flush])
    state = %{state | host_recovery_task: nil}

    state =
      case result do
        {:ok, context} ->
          facts =
            Map.put(state.host_retirement_facts, :completion, state.host_retirement_facts.result)

          state = settle_host_retirement(state, facts)

          case adopt_host(state, context) do
            {:ok, ready} -> start_host_prompt(ready)
            {:error, reason, retained} -> finish_host_prompt(retained, :failed, reason)
          end

        {:error, reason} ->
          facts = Map.put(state.host_retirement_facts, :completion, {:error, reason})
          state |> settle_host_retirement(facts) |> finish_host_prompt(:failed, reason)
      end

    {:noreply, state}
  end

  def handle_info({ref, {:goal_idle, result}}, %{goal_idle_task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    stale? = state.goal_idle_generation != state.goal_generation
    state = %{state | goal_idle_task: nil, goal_admission: nil}

    case result do
      {:error, error} -> emit(state, {:turn_error, error})
      _ -> :ok
    end

    state =
      if match?({:ok, {:started, _}}, result) or
           (stale? and match?({:ok, _}, result)),
         do: maybe_goal_idle(state),
         else: state

    {:noreply, inspect_host_prompt(state)}
  end

  def handle_info({ref, {:goal_unstarted, error}}, %{current_turn_task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = clear_cancel_timer(state)
    {:noreply, finish_goal_unstarted(%{state | pending_goal_result: %{error: error}})}
  end

  def handle_info({ref, {:goal_host_stopped, result}}, %{current_turn_task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = clear_cancel_timer(state)
    {:noreply, finish_goal_unstarted(%{state | pending_goal_result: %{host_result: result}})}
  end

  def handle_info(
        {:goal_executor_settled, coordinator, executor, control, admission, result},
        %{
          goal_integration: %{coordinator: coordinator},
          current_turn_task: %{pid: executor},
          goal_executor_control: control
        } = state
      )
      when admission.run_id == state.turn_state.turn_id do
    {:noreply, finish_goal_unstarted(%{state | goal_executor_settlement: result})}
  end

  def handle_info(
        {ref,
         {:ok,
          %{
            messages: _,
            outcome: _,
            context_snapshot: _,
            context_policy: _
          } = result}},
        state
      )
      when is_reference(ref) do
    case state.current_turn_task do
      %Task{ref: ^ref} ->
        Process.demonitor(ref, [:flush])
        {state, result} = reconcile_goal_instructions(state, result)
        new_messages = result.messages
        outcome = if state.turn_state.phase == :cancelling, do: :cancelled, else: result.outcome

        new_state =
          state
          |> clear_cancel_timer()
          |> Map.put(:messages, new_messages)
          |> Map.put(:context_snapshot, result.context_snapshot)
          |> Map.put(:context_policy, result.context_policy)
          |> Map.put(:context_window, Map.get(result, :context_window, state.context_window))
          |> Map.put(
            :context_excluded_message_ids,
            Map.get(result, :context_excluded_message_ids, state.context_excluded_message_ids)
          )
          |> Map.put(:current_turn_task, nil)
          |> Map.put(:goal_resume_pending, Map.get(result, :goal_resume_pending, false))
          |> Map.put(:context_reconciliation_required, state.goal_instruction_pending)
          |> finish_turn(outcome)

        emit(new_state, {:agent_end, new_messages})
        {:noreply, maybe_start_follow_up(new_state, outcome)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(
        {ref, {:error, {:event_persistence_failed, _event_type, _persistence_reason} = reason}},
        state
      )
      when is_reference(ref) do
    case state.current_turn_task do
      %Task{ref: ^ref} ->
        Process.demonitor(ref, [:flush])

        new_state =
          state
          |> clear_cancel_timer()
          |> Map.put(:current_turn_task, nil)
          |> Map.put(:context_reconciliation_required, true)
          |> finish_turn(:failed, reason, persist_metrics?: false)

        emit(new_state, {:turn_error, reason})
        {:noreply, maybe_start_follow_up(new_state, :failed)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({ref, {:error, reason}}, state) when is_reference(ref) do
    case state.current_turn_task do
      %Task{ref: ^ref} ->
        Process.demonitor(ref, [:flush])
        cancelling? = state.turn_state.phase == :cancelling

        new_state =
          state
          |> clear_cancel_timer()
          |> Map.put(:current_turn_task, nil)
          |> Map.put(:context_reconciliation_required, true)
          |> finish_turn(if(cancelling?, do: :cancelled, else: :failed), reason)

        unless cancelling?, do: emit(new_state, {:turn_error, reason})

        {:noreply,
         maybe_start_follow_up(new_state, if(cancelling?, do: :cancelled, else: :failed))}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:canonical_context, turn_id, messages, window, excluded}, state) do
    if state.turn_state.turn_id == turn_id and is_list(messages) do
      {:noreply,
       %{
         state
         | messages: messages,
           context_window: window,
           context_excluded_message_ids: excluded
       }}
    else
      {:noreply, state}
    end
  end

  def handle_info({:canonical_messages, turn_id, messages}, state) do
    if state.turn_state.turn_id == turn_id and is_list(messages) do
      {:noreply, refresh_async_interactions(%{state | messages: messages})}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{host_retirement_task: %{ref: ref}, host_retirement_stage: :completion} = state
      ) do
    error =
      {:error,
       Backplane.AgentRuntime.Error.new(:unknown_outcome, "host archive completion task exited",
         cause: reason
       )}

    facts = Map.put(state.host_retirement_facts, :completion, error)
    {:noreply, settle_host_retirement(state, facts)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{host_retirement_task: %{ref: ref}} = state
      ) do
    error =
      {:error,
       Backplane.AgentRuntime.Error.new(:unknown_outcome, "root retirement task exited",
         cause: reason
       )}

    # The task may have executed SessionEnd before its result was lost. Retain
    # uncertainty rather than executing an effect again to reconstruct a fact.
    facts =
      Map.merge(state.host_retirement_facts, %{
        async_hooks: state.host_retirement_facts[:async_hooks] || error,
        session_end: state.host_retirement_facts[:session_end] || error,
        result: error
      })

    {:noreply, complete_host_retirement(state, facts)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{host_recovery_task: %{ref: ref}} = state
      ) do
    error =
      Backplane.AgentRuntime.Error.new(:unknown_outcome, "live host recovery task exited",
        cause: reason
      )

    state = %{state | host_recovery_task: nil}

    state =
      if map_size(state.host_retirement_facts) > 0 do
        facts = Map.put(state.host_retirement_facts, :completion, {:error, error})
        settle_host_retirement(state, facts)
      else
        state
      end

    {:noreply, finish_host_prompt(state, :failed, error)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case {state.goal_idle_task, state.current_turn_task} do
      {%Task{ref: ^ref}, _} ->
        emit(state, {:turn_error, {:goal_idle_failed, reason}})
        {:noreply, inspect_host_prompt(%{state | goal_idle_task: nil})}

      {_, %Task{ref: ^ref}} ->
        if goal_before_effects?(state) do
          pending = state.pending_goal_result || %{error: reason}
          state = clear_cancel_timer(state)
          {:noreply, finish_goal_unstarted(%{state | pending_goal_result: pending})}
        else
          cancelling? = state.turn_state.phase == :cancelling

          if not cancelling? and reason not in [:normal, :shutdown, :killed] do
            emit(state, {:turn_error, reason})
          end

          outcome = if cancelling?, do: :cancelled, else: :failed

          new_state =
            state
            |> clear_cancel_timer()
            |> Map.put(:current_turn_task, nil)
            |> Map.put(:context_reconciliation_required, true)
            |> finish_turn(outcome, reason)

          {:noreply, maybe_start_follow_up(new_state, outcome)}
        end

      _ ->
        case remove_user_question_by_monitor(state, ref) do
          {:ok, question_id, state} ->
            emit(state, {:ask_user_question_resolved, question_id})
            {:noreply, state}

          :error ->
            case remove_mcp_elicitation_by_monitor(state, ref) do
              {:ok, elicitation_id, state} ->
                emit(state, {:mcp_elicitation_resolved, elicitation_id})
                {:noreply, state}

              :error ->
                {:noreply, state}
            end
        end
    end
  end

  def handle_info({:mcp_subscription, _subscription, notification}, state) do
    method = notification_method(notification)

    if method == "notifications/tools/list_changed" do
      {:noreply, refresh_mcp_tools_from_notification(state, notification)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:force_cancel, turn_id, task_ref}, state) do
    case state.current_turn_task do
      %Task{ref: ^task_ref} = task
      when state.turn_state.turn_id == turn_id and state.turn_state.phase == :cancelling ->
        shutdown = Task.shutdown(task, :brutal_kill)

        if goal_before_effects?(state) do
          reason =
            case shutdown do
              {:ok, {:goal_unstarted, error}} -> error
              {:exit, cause} -> cause
              _ -> :killed
            end

          pending = state.pending_goal_result || %{error: reason}
          state = clear_cancel_timer(state)
          {:noreply, finish_goal_unstarted(%{state | pending_goal_result: pending})}
        else
          new_state =
            state
            |> clear_cancel_timer()
            |> Map.put(:current_turn_task, nil)
            |> Map.put(:context_reconciliation_required, true)
            |> finish_turn(:cancelled)

          {:noreply, maybe_start_follow_up(new_state, :cancelled)}
        end

      _task ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}
  def handle_info(_msg, state), do: {:noreply, state}

  defp complete_host_retirement(state, facts) do
    state = %{
      state
      | host_retirement_task: nil,
        host_retirement_stage: nil,
        host_retirement_facts: facts
    }

    cond do
      not match?({:ok, %{status: :confirmed}}, facts.result) ->
        state = settle_host_retirement(state, facts)

        if state.pending_host_prompt,
          do: finish_host_prompt(state, :failed, elem(facts.result, 1)),
          else: state

      is_nil(state.pending_host_prompt) ->
        start_host_completion(state)

      match?({:ok, %{status: :confirmed}}, facts.result) ->
        reconcile_host_prompt(state)
    end
  end

  defp settle_host_retirement(state, facts) do
    {reopens, retirements} =
      Enum.split_with(state.host_retirement_waiters, &match?({:session_reopen, _}, &1))

    result =
      case facts.result do
        {:ok, %{status: :confirmed}} -> facts[:completion] || facts.result
        failure -> failure
      end

    Enum.each(retirements, &GenServer.reply(&1, result))

    state = %{
      state
      | host_retirement_task: nil,
        host_retirement_stage: nil,
        host_retirement_waiters: [],
        host_retirement_facts: facts
    }

    if reopens == [] do
      state
    else
      {:reply, reply, state} = finish_session_operation(state)
      Enum.each(reopens, fn {:session_reopen, from} -> GenServer.reply(from, reply) end)
      state
    end
  end

  defp start_host_retirement(
         %{host_retirement_facts: %{result: {:ok, %{status: :confirmed}}}} = state
       ),
       do: start_host_completion(state)

  defp start_host_retirement(state) do
    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        {:root_retirement, RootRetirement.close(state, state.host_retirement_facts, :shutdown)}
      end)

    %{state | host_retirement_task: task, host_retirement_stage: :components}
  end

  defp start_host_completion(state) do
    if state.pending_host_prompt do
      reconcile_host_prompt(state)
    else
      task =
        Task.Supervisor.async_nolink(state.task_supervisor, fn ->
          result =
            with :ok <- complete_host_generation(state, :archives),
                 do: state.host_retirement_facts.result

          {:host_completion, result}
        end)

      %{state | host_retirement_task: task, host_retirement_stage: :completion}
    end
  end

  defp complete_host_generation(state, purpose \\ :admission) do
    with :ok <- recover_generation_goal(state, purpose) do
      case state.subagents && Sigma.Agent.Subagents.close(state.subagents) do
        nil -> :ok
        :ok -> :ok
        {:ok, %{status: :confirmed}} -> :ok
        error -> error
      end
    end
  end

  defp recover_generation_goal(state, :admission),
    do: recover_retired_goal(state.goal_integration)

  defp recover_generation_goal(%{subagents: nil}, :archives), do: :ok

  defp recover_generation_goal(state, :archives) do
    # Root-only retirement leaves ordinary root recovery to its existing
    # admission/opening boundary. Only retained children require Goal ACKs
    # before their public archives can be completed by this live manager.
    with {:ok, sources} <- Sigma.Agent.Subagents.archive_sources(state.subagents) do
      if sources.children == [], do: :ok, else: recover_retired_goal(state.goal_integration)
    end
  end

  defp recover_retired_goal(nil), do: :ok

  defp recover_retired_goal(handle) do
    with {:ok, %{status: :ready}} <- GoalIntegration.recover_retired(handle), do: :ok
  end

  defp inspect_host_prompt(%{pending_host_prompt: nil} = state), do: state
  defp inspect_host_prompt(%{goal_idle_task: %Task{}} = state), do: state
  defp inspect_host_prompt(%{host_recovery_task: %Task{}} = state), do: state
  defp inspect_host_prompt(%{host_retirement_task: %Task{}} = state), do: state

  defp inspect_host_prompt(state) do
    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        result =
          case RootRetirement.recovery_required?(state) do
            {:ok, false} ->
              with {:ok, %{status: :ready}} <-
                     GoalIntegration.prepare_admission(state.goal_integration),
                   do: {:ok, false}

            result ->
              result
          end

        {:host_inspection, result}
      end)

    %{state | host_recovery_task: task}
  end

  defp reconcile_host_prompt(state) do
    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        result =
          with :ok <- complete_host_generation(state),
               do: RootRetirement.context(state)

        {:host_recovery, result}
      end)

    %{state | host_recovery_task: task, context_reconciliation_required: true}
  end

  defp start_host_prompt(%{pending_host_prompt: %{cancelled?: true}} = state),
    do: finish_host_prompt(state, :cancelled, nil)

  defp start_host_prompt(state) do
    item = state.pending_host_prompt.item
    start_ready_turn(%{state | pending_host_prompt: nil}, item)
  end

  defp cancel_host_prompt(state) do
    state
    |> fence_goal_admission(:cancelled)
    |> Map.put(:pending_host_prompt, %{state.pending_host_prompt | cancelled?: true})
    |> Map.put(:last_cancelled_turn_id, state.pending_host_prompt.item.turn_id)
  end

  defp finish_host_prompt(state, outcome, reason) do
    item = state.pending_host_prompt.item
    release_resources(item.prepared_resources)
    notify_retry_admission(item, {:error, reason || :cancelled})
    if reason, do: emit(state, {:turn_error, reason})

    %{
      state
      | pending_host_prompt: nil,
        messages: Map.get(item, :retry_restore_messages, state.messages),
        context_window: Map.get(item, :retry_restore_context_window, state.context_window),
        context_excluded_message_ids:
          Map.get(item, :retry_restore_context_excluded_ids, state.context_excluded_message_ids),
        context_reconciliation_required: true
    }
    |> finish_turn(outcome, reason, persist_metrics?: false)
    |> maybe_start_follow_up(outcome)
  end

  defp stop_host_recovery_task(%{host_recovery_task: %Task{} = task}) do
    Task.shutdown(task, :brutal_kill)
    :ok
  end

  defp stop_host_recovery_task(_state), do: :ok

  defp retire_root_on_terminate(%{host_retirement_task: %Task{} = task} = state, _reason) do
    case Task.yield(task, 0) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:root_retirement, facts}} ->
        complete_root_on_terminate(state, facts)

      {:ok, {:host_completion, result}} ->
        report_host_completion_on_terminate(state, state.host_retirement_facts, result)

      result ->
        Logger.error(
          "[Sigma.Agent] Root retirement task stopped without receipts: #{inspect(result)}"
        )

        Sigma.Coding.Hooks.AsyncRuntime.shutdown(state.hook_async_runtime)

        if state.host_retirement_stage == :completion do
          maybe_stage_host_on_terminate(state, state.host_retirement_facts, result)
        end
    end
  end

  defp retire_root_on_terminate(state, reason) do
    facts =
      case state.host_retirement_facts do
        %{result: {:ok, %{status: :confirmed}}} = confirmed ->
          confirmed

        previous ->
          # An active Engine may need Agent callbacks during Session.close.
          # terminate cannot serve them. Preserve the existing hook cleanup
          # order and leave native cleanup to the Subagents owner in that case.
          idle? =
            is_nil(state.current_turn_task) and is_nil(state.goal_idle_task) and
              root_can_retire_on_terminate?(state)

          RootRetirement.close(state, previous, reason, native_close: idle?)
      end

    complete_root_on_terminate(state, facts)
  end

  defp complete_root_on_terminate(state, facts) do
    RootRetirement.report(facts)

    # Goal and the original manager are still alive here. Complete the same
    # live ACK/archive gate before the supervisor retires either owner. An
    # active/unconfirmed shutdown retains its original recovery boundary.
    if match?({:ok, %{status: :confirmed}}, facts.result) do
      case facts[:completion] do
        {:ok, %{status: :confirmed}} ->
          :ok

        _ ->
          result = complete_host_generation(state, :archives)
          report_host_completion_on_terminate(state, facts, result)
      end
    end
  end

  defp report_host_completion_on_terminate(state, facts, result) do
    report_host_completion(result)
    maybe_stage_host_on_terminate(state, facts, result)
  end

  defp maybe_stage_host_on_terminate(state, facts, result) do
    if match?(%{result: {:ok, %{status: :confirmed}}}, facts) and
         result != :ok and not match?({:ok, %{status: :confirmed}}, result) do
      stage_host_on_terminate(state)
    end
  end

  defp stage_host_on_terminate(%{subagents: nil}), do: :ok

  defp stage_host_on_terminate(state) do
    case Sigma.Agent.Subagents.stage_shutdown(state.subagents) do
      :ok -> :ok
      error -> report_shutdown_stage(error)
    end
  catch
    :exit, reason -> report_shutdown_stage({:error, reason})
  end

  defp report_shutdown_stage(result),
    do: Logger.error("[Sigma.Agent] Shutdown export staging is unconfirmed: #{inspect(result)}")

  defp report_host_completion(:ok), do: :ok
  defp report_host_completion({:ok, %{status: :confirmed}}), do: :ok

  defp report_host_completion(result),
    do: Logger.error("[Sigma.Agent] Host archive completion is unconfirmed: #{inspect(result)}")

  defp root_can_retire_on_terminate?(state) do
    subagents_can_stop?(state)
  catch
    :exit, _ -> false
  end

  defp finish_session_operation(state) do
    if state.turn_state.phase == :session_operation do
      result =
        case reopen_runtime_store(state) do
          {:ok, reopened} ->
            case if(is_nil(reopened.goal_integration),
                   do: init_goal(reopened),
                   else: {:ok, reopened}
                 ) do
              {:ok, ready} -> reopen_host(ready)
              {:error, reason} -> {:error, reason, reopened}
            end

          {:error, reason} ->
            {:error, reason, state}
        end

      case result do
        {:ok, state} ->
          state = %{state | turn_state: TurnState.transition(state.turn_state, :idle)}
          {:reply, :ok, maybe_goal_idle(state)}

        {:error, reason, retained} ->
          {:reply, {:error, reason}, retained}
      end
    else
      {:reply, :ok, state}
    end
  end

  defp reopen_host(%{host_retirement_facts: facts} = state) when map_size(facts) == 0,
    do: {:ok, state}

  defp reopen_host(%{host_retirement_facts: %{completion: {:ok, %{status: :confirmed}}}} = state) do
    case RootRetirement.context(state) do
      {:ok, context} -> adopt_host(state, context)
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp reopen_host(%{host_retirement_facts: %{completion: {:error, reason}}} = state),
    do: {:error, reason, state}

  defp reopen_host(state), do: {:error, :host_retirement_unconfirmed, state}

  defp adopt_host(state, context) do
    with {:ok, runtime} <- Sigma.Coding.Hooks.AsyncRuntime.start(self()) do
      :ets.delete(state.hook_async_contexts)

      {:ok,
       %{
         state
         | host_retirement: context,
           hook_async_runtime: runtime,
           hook_async_contexts: Hooks.async_contexts(),
           host_retirement_facts: %{}
       }}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp status_snapshot(state) do
    counts = PromptQueue.counts(state.prompt_queue)

    %{
      phase: state.turn_state.phase,
      turn_id: state.turn_state.turn_id,
      current_request_id: state.current_request_id,
      context_snapshot: state.context_snapshot,
      context_policy: state.context_policy,
      steering_queue_count: counts.steering,
      follow_up_queue_count: counts.follow_up
    }
  end

  defp admit_prompt(state, content, opts, requested_mode) do
    case new_prompt_item(content, opts) do
      {:error, reason} ->
        release_resources(Keyword.get(opts, :prepared_resources, []))
        emit(state, {:prompt_rejected, reason})
        {{:rejected, reason}, state}

      {:ok, _item} when state.turn_state.phase == :session_operation ->
        release_resources(Keyword.get(opts, :prepared_resources, []))
        emit(state, {:prompt_rejected, :session_busy})
        {{:rejected, :session_busy}, state}

      {:ok, item} when is_nil(state.current_turn_task) ->
        state = state |> fence_goal_admission(:superseded) |> start_turn(item)
        info = prompt_info(item, item.turn_id)
        emit(state, {:prompt_admitted, :accepted, info})
        emit_prompt_telemetry(state, :accepted)
        {{:accepted, info}, state}

      {:ok, item} ->
        state = fence_goal_admission(state, :superseded)
        mode = admission_mode(requested_mode, opts)
        item = if mode == :steering, do: %{item | turn_id: state.turn_state.turn_id}, else: item
        state = if mode == :steering, do: attach_turn_resources(state, item), else: state
        queue = PromptQueue.enqueue(state.prompt_queue, mode, item)
        result = if mode == :steering, do: :queued_as_steering, else: :queued_as_follow_up
        info = prompt_info(item, item.turn_id)
        state = %{state | prompt_queue: queue}
        emit(state, {:prompt_admitted, result, info})
        emit_prompt_telemetry(state, result)
        {{result, info}, state}
    end
  end

  defp new_prompt_item(content, opts) when is_binary(content) or is_list(content) do
    empty? = is_binary(content) and String.trim(content) == ""
    prepared_resources = Keyword.get(opts, :prepared_resources, [])

    cond do
      empty? or content == [] ->
        {:error, :empty_prompt}

      not is_list(prepared_resources) or
          not Enum.all?(prepared_resources, &valid_prepared_resource?/1) ->
        {:error, :invalid_prepared_resources}

      true ->
        {:ok,
         %{
           message_id: "msg_user_#{random_id(8)}",
           turn_id: "turn_#{random_id(8)}",
           content: content,
           attachments: Keyword.get(opts, :attachments),
           retry_of_turn_id: Keyword.get(opts, :retry_of_turn_id),
           retry_admission_notify: Keyword.get(opts, :retry_admission_notify),
           metadata: %{},
           dispatcher_opts: Keyword.get(opts, :dispatcher_opts, []),
           prepared_resources: prepared_resources
         }}
    end
  end

  defp new_prompt_item(_content, _opts), do: {:error, :invalid_prompt}

  defp upload_time, do: System.monotonic_time(:millisecond)

  defp upload_result({:ok, uploads, progress}, state),
    do: {:reply, {:ok, progress}, %{state | async_reply_uploads: uploads}}

  defp upload_result({:error, reason, uploads}, state),
    do: {:reply, {:error, reason}, %{state | async_reply_uploads: uploads}}

  defp async_upload_origin(%{writer: nil}, _request),
    do: {:error, :async_interactions_unavailable}

  defp async_upload_origin(state, request) do
    with true <- state.turn_state.phase not in [:cancelling, :session_operation],
         {:ok, snapshot} <- AsyncDelivery.snapshot(state.writer),
         true <- snapshot.leaf_id == request["expectedLeafId"],
         %{} = item <- Enum.find(snapshot.items, &(&1["item_id"] == request["itemId"])),
         true <- item["session_id"] == state.session_id,
         true <-
           item["status"] in ~w(open notice saved dispatching admitted consumed delivery_unknown),
         true <- item["status"] != "delivery_unknown" or is_map(item["reply"]) do
      {:ok, item}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_async_reply_origin}
    end
  end

  defp admit_async_reply(%{writer: nil} = state, _id, _payload, _leaf),
    do: {{:error, :async_interactions_unavailable}, state}

  defp admit_async_reply(%{async_interaction_error: reason} = state, _id, _payload, _leaf)
       when not is_nil(reason),
       do: {{:error, reason}, state}

  defp admit_async_reply(state, item_id, payload, expected_leaf) do
    with true <- state.turn_state.phase not in [:cancelling, :session_operation],
         {:ok, snapshot} <- AsyncDelivery.snapshot(state.writer),
         true <- snapshot.leaf_id == expected_leaf,
         %{} = item <- Enum.find(snapshot.items, &(&1["item_id"] == item_id)),
         true <- item["session_id"] == state.session_id do
      if item["status"] in ~w(dispatching admitted consumed delivery_unknown) do
        with %{} <- item["reply"],
             {:ok, _} <- AsyncInteractions.reply(payload, Map.put(item, "status", "saved")) do
          {{:ok, %{item_id: item_id, status: item["status"]}}, state}
        else
          {:error, _} = error -> {error, state}
          _ -> {{:error, :invalid_async_reply}, state}
        end
      else
        dispatch_async_reply(state, item, payload, expected_leaf)
      end
    else
      {:error, _} = error -> {error, state}
      _ -> {{:error, :invalid_async_reply_origin}, state}
    end
  end

  defp dispatch_async_reply(state, item, payload, expected_leaf) do
    with {:ok, %{reply: reply}} <-
           AsyncInbox.prepare_reply(state.writer, item["item_id"], payload, expected_leaf),
         :ok <-
           AsyncDelivery.fact(state.writer, item, "dispatch_started", %{
             "reply_id" => reply["reply_id"]
           }),
         {:ok, queued} <- new_prompt_item(reply["content"], []) do
      queued = %{
        queued
        | message_id: reply["message_id"],
          turn_id: reply["turn_id"],
          metadata: reply["metadata"]
      }

      {admission, state, queued} =
        if is_nil(state.current_turn_task) do
          state = %{
            state
            | async_reply_messages:
                Map.put(state.async_reply_messages, queued.message_id, queued.turn_id)
          }

          {:accepted, start_turn(state, queued), queued}
        else
          queued = %{queued | turn_id: state.turn_state.turn_id}

          state = %{
            state
            | async_reply_messages:
                Map.put(state.async_reply_messages, queued.message_id, queued.turn_id),
              prompt_queue: PromptQueue.enqueue(state.prompt_queue, :steering, queued)
          }

          {:queued_as_steering, state, queued}
        end

      emit(state, {:prompt_admitted, admission, prompt_info(queued, queued.turn_id)})
      emit_prompt_telemetry(state, admission)

      result =
        case AsyncDelivery.fact(state.writer, item, "admitted", %{"reply_id" => reply["reply_id"]}) do
          :ok ->
            {:ok, %{item_id: item["item_id"], status: :admitted}}

          {:error, reason} ->
            {:error,
             {:async_reply_accepted, %{item_id: item["item_id"], status: :dispatching}, reason}}
        end

      {result, state}
    else
      {:error, _} = error -> {error, state}
    end
  end

  defp refresh_async_interactions(%{writer: nil} = state), do: state

  defp refresh_async_interactions(state) do
    pending = state.async_reply_messages |> Map.keys() |> MapSet.new()

    case AsyncDelivery.refresh(state.writer, state.backplane_store, pending) do
      {:ok, snapshot} ->
        signature = :crypto.hash(:sha256, :erlang.term_to_binary(snapshot))

        if signature != state.async_interaction_signature,
          do: notify_subscribers(state, {:async_interactions_updated, snapshot})

        %{state | async_interaction_signature: signature, async_interaction_error: nil}

      {:error, reason} ->
        if state.async_interaction_error != reason,
          do: Logger.warning("Async interaction recovery is unavailable: #{inspect(reason)}")

        %{state | async_interaction_error: reason}
    end
  end

  defp finish_async_interactions(%{writer: nil} = state, _turn_id, _outcome), do: state

  defp finish_async_interactions(state, turn_id, outcome) do
    state = %{
      state
      | async_reply_messages:
          Map.reject(state.async_reply_messages, fn {_id, turn} -> turn == turn_id end),
        prompt_queue: %{
          state.prompt_queue
          | steering:
              Enum.reject(state.prompt_queue.steering, fn item ->
                item.turn_id == turn_id and
                  Map.has_key?(Map.get(item, :metadata, %{}), "async_interaction")
              end)
        }
    }

    state = refresh_async_interactions(state)

    if outcome in [:cancelled, :failed] do
      case AsyncDelivery.close_run(state.writer, turn_id, outcome) do
        :ok -> refresh_async_interactions(state)
        {:error, reason} -> %{state | async_interaction_error: reason}
      end
    else
      state
    end
  end

  defp admission_mode(:steering, _opts), do: :steering
  defp admission_mode(:follow_up, _opts), do: :follow_up

  defp admission_mode(:auto, opts) do
    case Keyword.get(opts, :admission, :follow_up) do
      :steering -> :steering
      _mode -> :follow_up
    end
  end

  defp start_turn(state, item) do
    if state.native_tools and not is_nil(state.goal_integration) and
         not is_nil(state.host_retirement) do
      state
      |> fence_goal_admission(:superseded)
      |> Map.put(:pending_host_prompt, %{item: item, cancelled?: false})
      |> Map.put(:turn_state, %TurnState{turn_id: item.turn_id, phase: :session_operation})
      |> inspect_host_prompt()
    else
      start_ready_turn(state, item)
    end
  end

  defp start_ready_turn(state, item) do
    state = attach_turn_resources(state, item)
    control_pid = self()
    cancellation_ref = make_ref()
    turn_started_at = DateTime.utc_now() |> DateTime.to_iso8601()
    turn_started_monotonic = System.monotonic_time(:millisecond)

    dispatcher_opts =
      state.dispatcher_opts
      |> Keyword.merge(item.dispatcher_opts)
      |> Keyword.put(
        :skill_roots,
        merge_skill_roots(state.dispatcher_opts, prepared_resource_roots(item.prepared_resources))
      )
      |> Keyword.put(:register_skill_resource, fn resource ->
        GenServer.call(control_pid, {:register_skill_resource, item.turn_id, resource}, :infinity)
      end)
      |> Keyword.put(:skill_cancelled?, fn ->
        GenServer.call(control_pid, {:cancelled?, item.turn_id}, :infinity)
      end)
      |> Keyword.put(:signal, cancellation_ref)

    provider_options =
      state.provider_options
      |> Keyword.put(:cancellation_ref, cancellation_ref)

    task_state = %{
      state
      | control_pid: control_pid,
        current_turn_task: nil,
        dispatcher_opts: dispatcher_opts,
        provider_options: provider_options,
        turn_started_at: turn_started_at,
        turn_started_monotonic: turn_started_monotonic,
        goal_execution_admission: Map.get(item, :goal_admission),
        turn_state: TurnState.start(item.turn_id, cancellation_ref)
    }

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        try do
          case Map.get(item, :goal_admission) do
            nil ->
              {:ok, execute_turn(task_state, item)}

            admission ->
              GoalIntegration.execute_admission(
                task_state.goal_integration,
                admission,
                fn ->
                  if GenServer.call(control_pid, {:cancelled?, item.turn_id}, :infinity),
                    do: {:not_submitted, :cancelled},
                    else: Sigma.Agent.Backplane.Engine.prepare_hosted(task_state)
                end,
                fn ->
                  {:ok, scope} =
                    GoalIntegration.open_host_hooks(
                      task_state.goal_integration,
                      admission,
                      task_state.hook_async_runtime
                    )

                  result = execute_turn(%{task_state | hook_execution: scope}, item)

                  case Map.pop(result, :goal_host_terminal) do
                    {nil, result} ->
                      {:ok, result}

                    {terminal, result} ->
                      case GoalIntegration.stop_host_executor(
                             task_state.goal_integration,
                             admission,
                             terminal
                           ) do
                        :ok -> :ok
                        {:error, error} -> emit(task_state, {:turn_error, error})
                      end

                      {:goal_host_stopped, result}
                  end
                end
              )
          end
        catch
          {:event_persistence_failed, event_type, reason} ->
            {:error, {:event_persistence_failed, event_type, reason}}
        end
      end)

    %{
      state
      | current_turn_task: task,
        current_turn_resources: state.current_turn_resources,
        goal_executor_control: Map.get(item, :goal_executor_control),
        goal_executor_settlement: nil,
        pending_goal_result: nil,
        turn_started_at: turn_started_at,
        turn_started_monotonic: turn_started_monotonic,
        turn_state: TurnState.start(item.turn_id, cancellation_ref),
        last_cancelled_turn_id: nil
    }
  end

  defp prompt_info(item, turn_id), do: %{message_id: item.message_id, turn_id: turn_id}

  defp emit_prompt_telemetry(state, result) do
    counts = PromptQueue.counts(state.prompt_queue)

    :telemetry.execute(
      [:sigma, :agent, :prompt, :admitted],
      %{count: 1, queue_depth: counts.steering + counts.follow_up},
      %{session_id: state.session_id, result: result}
    )
  end

  defp random_id(bytes), do: :crypto.strong_rand_bytes(bytes) |> Base.encode16(case: :lower)

  defp finish_turn(state, outcome, reason \\ nil, opts \\ []) do
    turn_id = state.turn_state.turn_id
    turn_state = TurnState.transition(state.turn_state, outcome)
    state = %{state | turn_state: turn_state}

    if Keyword.get(opts, :persist_metrics?, true) do
      emit(
        state,
        {:metrics, :turn_finished,
         %{
           turn_id: turn_id,
           session_id: state.session_id,
           revision: 1,
           status: outcome,
           reason: reason,
           started_at: state.turn_started_at,
           finished_at: DateTime.utc_now() |> DateTime.to_iso8601(),
           wall_ms: elapsed_since(state.turn_started_monotonic)
         }}
      )
    end

    state = release_turn_resources(state)
    state = finish_async_interactions(state, turn_id, outcome)

    state = %{
      state
      | turn_started_at: nil,
        turn_started_monotonic: nil,
        current_request_id: nil,
        goal_executor_control: nil
    }

    case outcome do
      :completed ->
        emit(state, {:turn_completed, turn_id})
        state

      :failed ->
        emit(state, {:turn_failed, turn_id})
        state

      :cancelled ->
        if Keyword.get(opts, :interrupt_hooks?, true),
          do: Hooks.dispatch(:interrupt, state.hook_specs, hook_ctx(state, turn_id))

        emit(state, {:turn_cancelled})
        %{state | last_cancelled_turn_id: turn_id}
    end
  end

  defp maybe_start_follow_up(state, outcome) when outcome in [:completed, :failed, :cancelled] do
    case PromptQueue.pop(state.prompt_queue, :follow_up) do
      {nil, _queue} ->
        maybe_goal_idle(state)

      {item, queue} ->
        state = %{state | prompt_queue: queue}
        emit(state, {:prompt_consumed, :follow_up, prompt_info(item, item.turn_id)})
        start_turn(state, item)
    end
  end

  defp goal_before_effects?(%{goal_executor_control: nil}), do: false

  defp goal_before_effects?(state),
    do: :atomics.get(state.goal_executor_control, 1) in [0, 2, 3, 4, 5]

  defp fence_goal_executor_cancel(%{goal_executor_control: nil}), do: :active

  defp fence_goal_executor_cancel(state) do
    case :atomics.compare_exchange(state.goal_executor_control, 1, 0, 2) do
      4 ->
        :sealed

      1 ->
        case :atomics.compare_exchange(state.goal_executor_control, 1, 1, 5) do
          4 -> :sealed
          _ -> :active
        end

      _active ->
        :active
    end
  end

  defp finish_goal_unstarted(
         %{pending_goal_result: %{error: reason}, goal_executor_settlement: settlement} = state
       )
       when not is_nil(settlement) do
    cancelling? = state.turn_state.phase == :cancelling
    outcome = if cancelling?, do: :cancelled, else: :failed

    state =
      state
      |> clear_cancel_timer()
      |> Map.put(:current_turn_task, nil)
      |> Map.put(:pending_goal_result, nil)
      |> Map.put(:goal_executor_settlement, nil)
      |> Map.put(:goal_resume_pending, false)
      |> finish_turn(outcome, reason, interrupt_hooks?: false)

    unless cancelling?, do: emit(state, {:turn_error, reason})
    if match?({:error, _}, settlement), do: emit(state, {:turn_error, elem(settlement, 1)})
    emit(state, {:agent_end, state.messages})
    maybe_start_follow_up(state, outcome)
  end

  defp finish_goal_unstarted(
         %{
           pending_goal_result: %{host_result: result},
           goal_executor_settlement: settlement,
           current_turn_task: %{ref: ref}
         } = state
       )
       when not is_nil(settlement) do
    if match?({:error, _}, settlement), do: emit(state, {:turn_error, elem(settlement, 1)})

    # Settling an ordinary veto releases its reservation, not another prompt.
    # A later real prompt restores the normal idle continuation decision.
    state = %{state | pending_goal_result: nil, goal_executor_settlement: nil}
    {:noreply, state} = handle_info({ref, {:ok, %{result | goal_resume_pending: false}}}, state)
    state
  end

  defp finish_goal_unstarted(state), do: state

  defp reconcile_goal_instructions(%{goal_instruction_pending: false} = state, result),
    do: {state, result}

  defp reconcile_goal_instructions(state, result) do
    # A host Goal mutation records user provenance without sending another
    # Provider request. Its selected journal entry can arrive during this Task.
    case apply(Sigma.Session.Writer, :context_snapshot, [state.writer]) do
      {:ok, snapshot} ->
        result = %{
          result
          | messages: snapshot.messages,
            context_window: snapshot.context_window,
            context_excluded_message_ids:
              excluded_context_ids(snapshot.messages, snapshot.context_messages),
            context_snapshot: nil
        }

        {%{state | goal_instruction_pending: false}, result}

      error ->
        emit(state, {:turn_error, {:goal_instruction_reconciliation_failed, error}})
        {state, %{result | outcome: :failed}}
    end
  end

  defp init_goal(%{native_tools: true, writer: writer, transcript_path: path} = state)
       when not is_nil(writer) and is_binary(path) and path != "" do
    owner = self()

    callbacks = %{
      record_instruction: fn thread, instruction ->
        GenServer.call(owner, {:goal_record_instruction, thread, instruction}, 5_000)
      end,
      reserve_turn: fn thread, request ->
        GenServer.call(owner, {:goal_reserve, thread, request}, 5_000)
      end,
      release_turn: fn thread, admission ->
        GenServer.call(owner, {:goal_release, thread, admission}, 5_000)
      end
    }

    case GoalIntegration.open(
           writer: writer,
           transcript_path: path,
           cwd: state.cwd,
           root: Path.join(path <> ".subagents", "goal"),
           runtime_store: state.backplane_store,
           owner_pid: owner,
           host_context: callbacks
         ) do
      {:ok, handle} ->
        state = %{state | goal_integration: handle}
        {:ok, %{state | goal_resume_pending: goal_pending?(state)}}

      {:error, _} = error ->
        error
    end
  end

  defp init_goal(state), do: {:ok, state}

  defp reopen_runtime_store(%{backplane_store: nil} = state) do
    case init_backplane_store(backplane_runtime_path: state.backplane_store_path) do
      {:ok, store, owned?} ->
        {:ok, %{state | backplane_store: store, backplane_store_owned: owned?}}

      {:error, _} = error ->
        error
    end
  end

  defp reopen_runtime_store(state), do: {:ok, state}

  defp goal_thread?(%{goal_integration: %{thread_id: thread}}, thread), do: true
  defp goal_thread?(_state, _thread), do: false

  defp fence_goal_admission(state, reason) do
    # Queued input keeps the current released Task; only an actual replacement
    # or cancellation may fence that executor's first effect boundary.
    if not is_nil(state.goal_executor_control) and
         (reason == :cancelled or is_nil(state.current_turn_task)) do
      disposition = if reason == :cancelled, do: 2, else: 3
      :atomics.compare_exchange(state.goal_executor_control, 1, 0, disposition)
    end

    admission =
      case state.goal_admission do
        %{status: :reserved} = reservation -> %{reservation | status: reason}
        other -> other
      end

    %{state | goal_admission: admission, goal_generation: state.goal_generation + 1}
  end

  defp maybe_goal_idle(%{goal_integration: nil} = state), do: state
  defp maybe_goal_idle(%{goal_resume_pending: false} = state), do: state
  defp maybe_goal_idle(%{goal_idle_task: %Task{}} = state), do: state

  defp maybe_goal_idle(state) do
    counts = PromptQueue.counts(state.prompt_queue)

    if is_nil(state.current_turn_task) and
         state.turn_state.phase not in [:session_operation, :cancelling] and
         counts == %{steering: 0, follow_up: 0} do
      handle = state.goal_integration
      generation = state.goal_generation + 1

      task =
        Task.Supervisor.async_nolink(state.task_supervisor, fn ->
          result =
            with {:ok, false} <- RootRetirement.recovery_required?(state) do
              GoalIntegration.idle(handle, generation)
            else
              {:ok, true} ->
                {:not_reserved, :host_recovery_required}

              {:error, _} = error ->
                error
            end

          {:goal_idle, result}
        end)

      %{
        state
        | goal_idle_task: task,
          goal_generation: generation,
          goal_idle_generation: generation
      }
    else
      state
    end
  end

  defp stop_goal_idle_task(%{goal_idle_task: %Task{} = task}) do
    Task.shutdown(task, :brutal_kill)
    :ok
  end

  defp stop_goal_idle_task(_state), do: :ok

  defp goal_pending?(%{goal_integration: nil}), do: false

  defp goal_pending?(state) do
    case GoalIntegration.get(state.goal_integration) do
      {:ok, %{goal: %{status: :active}}} ->
        true

      {:ok, _} ->
        false

      {:error, error} ->
        emit(state, {:turn_error, error})
        false
    end
  end

  defp clear_cancel_timer(%{turn_state: %{cancel_timer: timer}} = state)
       when is_reference(timer) do
    Process.cancel_timer(timer)
    %{state | turn_state: %{state.turn_state | cancel_timer: nil}}
  end

  defp clear_cancel_timer(state), do: state

  defp attach_turn_resources(state, item) do
    resources = Enum.filter(item.prepared_resources, &valid_prepared_resource?/1)

    Enum.each(resources, &register_skill_grant(state.tool_state, item.turn_id, &1))
    %{state | current_turn_resources: resources ++ state.current_turn_resources}
  end

  defp valid_prepared_resource?(%{root: root, release: release}),
    do: is_binary(root) and is_function(release, 0)

  defp valid_prepared_resource?(_resource), do: false

  defp prepared_resource_roots(resources) do
    resources
    |> Enum.filter(&valid_prepared_resource?/1)
    |> Enum.map(& &1.root)
  end

  defp prepared_resource_metadata(resources) do
    resources
    |> Enum.filter(&valid_prepared_resource?/1)
    |> Enum.map(&Map.take(&1, [:ref, :digest]))
  end

  defp register_skill_grant(table, turn_id, resource) do
    :ets.insert(table, {{:skill_grant, turn_id, resource.root}, %{resource_root: resource.root}})
  rescue
    _ -> :ok
  end

  defp release_turn_resources(state) do
    release_resources(state.current_turn_resources)

    try do
      :ets.match_delete(state.tool_state, {{:skill_grant, state.turn_state.turn_id, :_}, :_})
      :ets.match_delete(state.tool_state, {{:skill_activation, state.turn_state.turn_id, :_}, :_})
    rescue
      _ -> :ok
    end

    %{state | current_turn_resources: []}
  end

  defp release_all_resources(state) do
    queued_resources =
      Enum.flat_map([:steering, :follow_up], fn queue ->
        state.prompt_queue
        |> Map.fetch!(queue)
        |> Enum.flat_map(& &1.prepared_resources)
      end)

    pending_resources =
      if state.pending_host_prompt,
        do: state.pending_host_prompt.item.prepared_resources,
        else: []

    (state.current_turn_resources ++ queued_resources ++ pending_resources)
    |> Enum.uniq_by(&Map.get(&1, :root))
    |> release_resources()
  end

  defp release_resources(resources) when is_list(resources) do
    Enum.each(resources, fn
      %{release: release} when is_function(release, 0) ->
        try do
          release.()
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end

      _resource ->
        :ok
    end)
  end

  defp release_resources(_resources), do: :ok

  defp cancel_pending_interactions(state) do
    Enum.each(pending_user_question_map(state), fn {question_id, pending} ->
      Process.demonitor(pending.monitor_ref, [:flush])
      send(pending.reply_to, {:ask_user_question_reply, question_id, {:error, :cancelled}})
      emit(state, {:ask_user_question_resolved, question_id})
    end)

    Enum.each(pending_mcp_elicitation_map(state), fn {elicitation_id, pending} ->
      Process.demonitor(pending.monitor_ref, [:flush])
      send(pending.reply_to, {:mcp_elicitation_reply, elicitation_id, :cancel})
      emit(state, {:mcp_elicitation_resolved, elicitation_id})
    end)

    state
    |> put_pending_user_questions(%{})
    |> put_pending_mcp_elicitations(%{})
  end

  defp restore_running_tools_phase(%{turn_state: %{phase: phase}} = state, phase) do
    %{state | turn_state: TurnState.transition(state.turn_state, :running_tools)}
  end

  defp restore_running_tools_phase(state, _phase), do: state

  # Internal — runs inside the turn Task

  defp execute_turn(state, item) do
    state = reconcile_context_after_interrupted_turn(state, item)
    emit(state, {:agent_start, state.cwd})

    emit(
      state,
      {:metrics, :turn_started,
       %{
         turn_id: item.turn_id,
         session_id: state.session_id,
         revision: 0,
         status: :running,
         reason: nil,
         started_at: state.turn_started_at
       }}
    )

    user_msg =
      Message.user(item.message_id, item.content)
      |> Map.put(:attachments, item.attachments)
      |> Map.put(
        :metadata,
        Map.merge(Map.get(item, :metadata, %{}), %{
          turn_id: item.turn_id,
          retry_of_turn_id: item.retry_of_turn_id,
          skill_preparations: prepared_resource_metadata(item.prepared_resources)
        })
      )

    {admission, state} =
      case run_session_start_hook(state) do
        {:ok, started_state} ->
          {run_user_prompt_submit_hook(started_state, user_msg), started_state}

        {:block, _reason} = blocked ->
          {blocked, state}
      end

    case admission do
      {:block, reason} ->
        notify_retry_admission(item, {:error, reason})
        emit(state, {:turn_blocked, reason})

        result = %{
          messages: Map.get(item, :retry_restore_messages, state.messages),
          context_window: Map.get(item, :retry_restore_context_window, state.context_window),
          context_excluded_message_ids:
            Map.get(item, :retry_restore_context_excluded_ids, state.context_excluded_message_ids),
          outcome: :failed,
          context_snapshot: state.context_snapshot,
          context_policy: state.context_policy,
          goal_resume_pending: goal_pending?(state)
        }

        if state.goal_execution_admission do
          Map.put(result, :goal_host_terminal, %{"status" => "blocked", "reason" => reason})
        else
          result
        end

      {:ok, user_msg, state} ->
        user_msg = prepare_hook_feedback(state, user_msg, item.turn_id)
        state = %{state | messages: state.messages ++ [user_msg]}
        emit(state, {:message_start, user_msg})
        emit(state, {:message_end, user_msg})
        notify_retry_admission(item, :committed)
        acknowledge_canonical(state)

        {state, outcome} = run_turn_loop(state, item.turn_id)

        {state, outcome} =
          if outcome == :completed, do: maybe_compact(state), else: {state, outcome}

        result = %{
          messages: state.messages,
          context_window: state.context_window,
          context_excluded_message_ids: state.context_excluded_message_ids,
          outcome: if(match?({:goal_host_stopped, _}, outcome), do: :failed, else: outcome),
          context_snapshot: state.context_snapshot,
          context_policy: state.context_policy,
          goal_resume_pending: goal_pending?(state)
        }

        case outcome do
          {:goal_host_stopped, terminal} -> Map.put(result, :goal_host_terminal, terminal)
          _ -> result
        end
    end
  end

  defp prepare_hook_feedback(%{native_tools: true, writer: writer} = state, message, turn_id)
       when not is_nil(writer) do
    case HookDelivery.prepare_prompt(writer, state.backplane_store, message, turn_id) do
      {:ok, message} -> message
      error -> throw({:event_persistence_failed, :hook_feedback, error})
    end
  end

  defp prepare_hook_feedback(_state, message, _turn_id), do: message

  defp reconcile_context_after_interrupted_turn(
         %{context_reconciliation_required: true, writer: writer} = state,
         item
       )
       when not is_nil(writer) do
    # A Writer append can commit after its Engine caller has died. Its selected
    # branch, rather than the last in-memory acknowledgement, owns the boundary.
    case apply(Sigma.Session.Writer, :context_snapshot, [writer]) do
      {:ok, snapshot} ->
        %{
          state
          | messages: snapshot.messages,
            context_window: snapshot.context_window,
            context_excluded_message_ids:
              excluded_context_ids(snapshot.messages, snapshot.context_messages)
        }
        |> invalidate_context(:journal_recovery)

      error ->
        reason = {:event_persistence_failed, :context_recovery, error}
        notify_retry_admission(item, {:error, reason})
        throw(reason)
    end
  end

  defp reconcile_context_after_interrupted_turn(state, _item), do: state

  defp notify_retry_admission(%{retry_admission_notify: {pid, ref}}, result)
       when is_pid(pid) and is_reference(ref) do
    send(pid, {:retry_admission, ref, result})
  end

  defp notify_retry_admission(_item, _result), do: :ok

  defp run_turn_loop(state, turn_id),
    do: Sigma.Agent.Backplane.Engine.run(state, turn_id)

  defp context_budget_error(state, context) do
    snapshot =
      ContextPolicy.snapshot(
        model: state.model,
        system: context.system,
        messages: context.messages,
        tools: context.tools
      )

    policy =
      ContextPolicy.policy(snapshot,
        model: state.model,
        context_limit: state.context_limit,
        output_reserve:
          Provider.output_token_limit(state.provider, state.model, state.provider_options)
      )

    if policy.overflow in [:overflow, :hard_overflow] do
      ProviderError.from_exception(
        "context token limit exceeded: estimated input " <>
          "#{snapshot.next_request_estimated_input_tokens}, output reserve " <>
          "#{policy.output_reserve}, context window #{policy.context_window}"
      )
    end
  end

  defp set_turn_phase(%{control_pid: control_pid}, turn_id, phase) when is_pid(control_pid),
    do: GenServer.cast(control_pid, {:turn_phase, turn_id, phase})

  defp set_turn_phase(_state, _turn_id, _phase), do: :ok

  defp set_current_request(%{control_pid: control_pid}, turn_id, request_id)
       when is_pid(control_pid),
       do: GenServer.cast(control_pid, {:current_request, turn_id, request_id})

  defp set_current_request(_state, _turn_id, _request_id), do: :ok

  defp run_state_change(persist) do
    case persist.() do
      :ok -> :ok
      {:ok, _result} = success -> success
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_state_change_result, other}}
    end
  rescue
    exception -> {:error, {:state_change_exception, exception.__struct__}}
  catch
    kind, reason -> {:error, {:state_change_failure, kind, reason}}
  end

  defp skill_grant_roots(table, turn_id) do
    activation_roots =
      :ets.match_object(table, {{:skill_activation, turn_id, :_}, %{resource_root: :_}})

    prompt_roots =
      :ets.match_object(table, {{:skill_grant, turn_id, :_}, %{resource_root: :_}})

    (activation_roots ++ prompt_roots)
    |> Enum.map(fn {_key, %{resource_root: root}} -> root end)
    |> Enum.uniq()
  rescue
    _ -> []
  end

  defp merge_skill_roots(opts, dynamic_roots) do
    (Keyword.get(opts, :skill_roots, []) ++ dynamic_roots)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp acknowledge_canonical(%{control_pid: control_pid, turn_state: %{turn_id: turn_id}} = state)
       when is_pid(control_pid) and is_binary(turn_id) do
    send(
      control_pid,
      {:canonical_context, turn_id, state.messages, state.context_window,
       state.context_excluded_message_ids}
    )

    :ok
  end

  defp acknowledge_canonical(_state), do: :ok

  defp maybe_emit_approval_required(
         state,
         {:error, %ToolError{kind: :approval_required}},
         tool_call
       ) do
    emit(state, {:approval_required, tool_call.id, tool_call.name})
  end

  defp maybe_emit_approval_required(_state, _result, _tool_call), do: :ok

  defp ai_to_agent_message(ai_msg, id, turn_id) do
    ai_to_agent_message(ai_msg, id, turn_id, nil)
  end

  defp ai_to_agent_message(ai_msg, id, turn_id, stop_reason) do
    metadata = if is_map(Map.get(ai_msg, :metadata)), do: ai_msg.metadata, else: %{}

    Message.assistant(id, %{
      content: ai_msg.content,
      model: ai_msg.model,
      provider: ai_msg.provider,
      usage: ai_msg.usage,
      stop_reason: normalized_stop_reason(stop_reason, ai_msg.stop_reason),
      timestamp: ai_msg.timestamp,
      response_id: Map.get(ai_msg, :response_id),
      metadata: Map.put(metadata, :turn_id, turn_id)
    })
  end

  defp normalized_stop_reason(%Sigma.Ai.ProviderStopReason{reason: reason}, _raw), do: reason
  defp normalized_stop_reason(_normalized, raw), do: raw

  defp maybe_compact(state) do
    input_tokens =
      state.messages
      |> Enum.reverse()
      |> Enum.find_value(0, fn msg ->
        if msg.role == :assistant and msg.usage != nil do
          get_in(msg.usage, [:input]) || 0
        end
      end)

    if input_tokens >= state.context_policy.threshold do
      case run_compact(state, trigger: :auto) do
        {state, {:error, {:hook_stopped, reason}}} ->
          emit(state, {:turn_blocked, reason})
          {state, :failed}

        {state, _result} ->
          {state, :completed}
      end
    else
      {state, :completed}
    end
  end

  defp run_compact(state, opts) do
    active_messages = __backplane_context_messages__(state)
    {to_summarize, to_keep} = find_compact_boundary(active_messages, 20)

    case to_summarize do
      [] ->
        {state, {:error, :nothing_to_compact}}

      _ ->
        compaction_id = "compact_#{System.unique_integer([:positive])}"
        started_at = DateTime.utc_now() |> DateTime.to_iso8601()
        before_tokens = latest_input_tokens(state.messages)
        trigger = Keyword.fetch!(opts, :trigger)
        source_leaf_id = Keyword.get(opts, :source_leaf_id) || current_source_leaf(state)

        emit(
          state,
          {:metrics, :compaction,
           %{
             compaction_id: compaction_id,
             revision: 0,
             status: :started,
             trigger: trigger,
             source_leaf_id: source_leaf_id,
             before_tokens: before_tokens,
             before_source: if(is_integer(before_tokens), do: :provider_usage, else: :unknown),
             started_at: started_at
           }}
        )

        pre_outcome =
          Hooks.dispatch(:pre_compact, state.hook_specs, hook_ctx(state), %{trigger: trigger})

        summary_result =
          case Outcome.control(pre_outcome) do
            {:halt, reason} -> {:error, {:hook_stopped, reason}, nil}
            _ -> generate_summary(state, to_summarize)
          end

        case summary_result do
          {:ok, summary_text, request_id}
          when is_binary(summary_text) and byte_size(summary_text) > 0 ->
            first_kept_id =
              case List.first(to_keep) do
                nil -> nil
                msg -> msg.id
              end

            summary_msg = %Message{
              id: "compaction_#{System.unique_integer([:positive])}",
              role: :compaction_summary,
              content: summary_text,
              timestamp: System.system_time(:millisecond)
            }

            excluded =
              Enum.filter(
                state.messages,
                &MapSet.member?(state.context_excluded_message_ids, &1.id)
              )

            new_state = %{state | messages: excluded ++ [summary_msg | to_keep]}
            emit(new_state, {:compact, summary_msg, first_kept_id})

            emit(
              new_state,
              {:metrics, :compaction,
               %{
                 compaction_id: compaction_id,
                 revision: 1,
                 status: :committed,
                 trigger: trigger,
                 source_leaf_id: source_leaf_id,
                 first_kept_id: first_kept_id,
                 summary_id: summary_msg.id,
                 request_ids: [request_id],
                 before_tokens: before_tokens,
                 after_tokens: compaction_token_estimate([summary_msg | to_keep]),
                 before_source:
                   if(is_integer(before_tokens), do: :provider_usage, else: :unknown),
                 after_source: :estimated,
                 started_at: started_at,
                 finished_at: DateTime.utc_now() |> DateTime.to_iso8601()
               }}
            )

            context =
              ContextBuilder.build(
                messages: __backplane_context_messages__(new_state),
                context_window: (new_state.context_window || %{})[:window] || 1,
                session_context: new_state.session_context,
                system_prompt: new_state.system_prompt,
                tools: Enum.map(new_state.tools, &Sigma.Coding.Tool.ai_definition/1),
                cwd: new_state.cwd,
                model: new_state.model
              )

            new_state = refresh_context_from_assembly(new_state, context, :compaction)

            post_outcome =
              Hooks.dispatch(:post_compact, new_state.hook_specs, hook_ctx(new_state), %{
                trigger: trigger
              })

            result =
              case Outcome.control(post_outcome) do
                {:halt, reason} ->
                  {:error, {:hook_stopped, reason}}

                _ ->
                  {:ok,
                   %{
                     compaction_id: compaction_id,
                     summary_id: summary_msg.id,
                     source_leaf_id: source_leaf_id
                   }}
              end

            {new_state, result}

          {:ok, _empty, request_id} ->
            emit_compaction_failure(
              state,
              compaction_id,
              started_at,
              :empty_summary,
              request_id,
              trigger,
              source_leaf_id
            )

            {state, {:error, :empty_summary}}

          {:error, reason, request_id} ->
            emit_compaction_failure(
              state,
              compaction_id,
              started_at,
              reason,
              request_id,
              trigger,
              source_leaf_id
            )

            {state, {:error, reason}}
        end
    end
  end

  defp emit_compaction_failure(
         state,
         compaction_id,
         started_at,
         reason,
         request_id,
         trigger,
         source_leaf_id
       ) do
    emit(
      state,
      {:metrics, :compaction,
       %{
         compaction_id: compaction_id,
         revision: 1,
         status: :failed,
         trigger: trigger,
         source_leaf_id: source_leaf_id,
         request_ids: [request_id],
         started_at: started_at,
         finished_at: DateTime.utc_now() |> DateTime.to_iso8601(),
         failure_reason: inspect(reason)
       }}
    )
  end

  defp current_source_leaf(%{writer: nil}), do: nil

  defp current_source_leaf(%{writer: writer}) do
    case apply(Sigma.Session.Writer, :flush, [writer]) do
      {:ok, %{active_leaf_id: active_leaf_id}} -> active_leaf_id
      _result -> nil
    end
  catch
    :exit, _reason -> nil
  end

  defp latest_input_tokens(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{role: :assistant, usage: usage} when is_map(usage) ->
        value = usage[:input] || usage["input"]
        if is_integer(value) and value >= 0, do: value

      _message ->
        nil
    end)
  end

  defp compaction_token_estimate(messages) do
    messages
    |> Enum.map(&inspect/1)
    |> Enum.join("\n")
    |> byte_size()
    |> Kernel.+(3)
    |> div(4)
    |> max(1)
  end

  # Split messages so to_keep starts at the first user message at or after
  # the (total - keep_count) boundary. This ensures the compaction summary
  # (which becomes an assistant message in convert_to_llm) is followed by a
  # user message, producing a valid alternating sequence for all providers.
  defp find_compact_boundary(messages, keep_count) do
    split_at = max(0, length(messages) - keep_count)
    {prefix, suffix} = Enum.split(messages, split_at)
    {leading, rest} = Enum.split_while(suffix, fn msg -> msg.role != :user end)
    {prefix ++ leading, rest}
  end

  defp generate_summary(state, messages) do
    transcript =
      messages
      |> Enum.reject(fn m -> m.role in [:status, :notification] end)
      |> Enum.map_join("\n\n---\n\n", fn msg ->
        label =
          case msg.role do
            :user -> "User"
            :assistant -> "Assistant"
            :tool_result -> "Tool (#{msg.tool_name})"
            :compaction_summary -> "Previous summary"
            r -> to_string(r)
          end

        text =
          case msg.content do
            s when is_binary(s) ->
              s

            blocks when is_list(blocks) ->
              Enum.map_join(blocks, "\n", fn
                %{type: :text, text: t} -> t
                %{type: :thinking, thinking: t} -> "[thinking: #{t}]"
                %{"type" => "text", "text" => t} -> t
                b -> inspect(b)
              end)

            nil ->
              ""
          end

        "#{label}: #{text}"
      end)

    prompt = """
    Create a detailed summary of the following coding session transcript. Preserve all important information: files read and their key content, files edited and what changed, commands run and their output, decisions made and why, and the current state of any work in progress.

    <transcript>
    #{transcript}
    </transcript>

    Reply with the summary only.
    """

    params = %{
      model: state.model,
      session_id: state.session_id,
      log_session_id: state.log_session_id,
      turn_id: state.turn_state.turn_id,
      purpose: :compaction,
      context: %{
        messages: [%{role: :user, content: [%{type: :text, text: prompt}]}],
        system_prompt: nil,
        tools: []
      },
      options: state.provider_options
    }

    request =
      params
      |> Map.put(:origin_session_id, state.session_id)
      |> ProviderRequest.new()
      |> ProviderRequest.begin(System.monotonic_time(:millisecond), DateTime.utc_now())

    emit(state, {:metrics, :request_started, request_fact(request)})
    meter_summary_request(state, request)
  end

  defp meter_summary_request(state, request) do
    {text, request, status, reason} =
      state.provider
      |> Provider.stream(request)
      |> Enum.reduce_while({"", request, nil, nil}, &reduce_summary_event/2)

    status = status || :failed

    finished =
      ProviderRequest.finish(
        request,
        status,
        System.monotonic_time(:millisecond),
        DateTime.utc_now()
      )

    fact =
      if status == :completed,
        do: request_fact(finished),
        else: Map.put(request_fact(finished), :failure_reason, inspect(reason))

    emit(state, {:metrics, :request_finished, fact})

    if status == :completed,
      do: {:ok, text, request.request_id},
      else: {:error, reason || :stream_ended_without_terminal, request.request_id}
  rescue
    exception ->
      finished =
        ProviderRequest.finish(
          request,
          :failed,
          System.monotonic_time(:millisecond),
          DateTime.utc_now()
        )

      emit(
        state,
        {:metrics, :request_finished,
         Map.put(request_fact(finished), :failure_reason, inspect(exception))}
      )

      {:error, ProviderError.from_exception(exception), request.request_id}
  catch
    kind, reason ->
      finished =
        ProviderRequest.finish(
          request,
          :failed,
          System.monotonic_time(:millisecond),
          DateTime.utc_now()
        )

      emit(
        state,
        {:metrics, :request_finished,
         Map.put(request_fact(finished), :failure_reason, inspect({kind, reason}))}
      )

      {:error, ProviderError.from_exception({kind, reason}), request.request_id}
  end

  defp reduce_summary_event(
         %ProviderEvent{type: :content_text_delta},
         {text, request, status, reason}
       ) do
    request = ProviderRequest.mark_output(request, System.monotonic_time(:millisecond), :text)
    {:cont, {text, request, status, reason}}
  end

  defp reduce_summary_event(%ProviderEvent{type: :content_thinking_delta}, acc) do
    {text, request, status, reason} = acc
    request = ProviderRequest.mark_output(request, System.monotonic_time(:millisecond), :thinking)
    {:cont, {text, request, status, reason}}
  end

  defp reduce_summary_event(%ProviderEvent{type: :usage_updated, usage: usage}, acc) do
    {text, request, status, reason} = acc
    {:cont, {text, put_request_usage(request, usage), status, reason}}
  end

  defp reduce_summary_event(
         %ProviderEvent{type: :response_completed, message: message, usage: usage},
         {_text, request, _status, _reason}
       ) do
    text = summary_message_text(message)
    request = put_request_usage(request, usage || ProviderUsage.from_map(message[:usage]))

    request =
      if text == "",
        do: request,
        else: ProviderRequest.mark_output(request, System.monotonic_time(:millisecond), :text)

    {:halt, {text, request, :completed, nil}}
  end

  defp reduce_summary_event(
         %ProviderEvent{type: :response_failed, error: error},
         {text, request, _, _}
       ) do
    status = if match?(%ProviderError{kind: :cancelled}, error), do: :cancelled, else: :failed
    {:halt, {text, request, status, error}}
  end

  defp reduce_summary_event(_event, acc), do: {:cont, acc}

  defp summary_message_text(%{content: blocks}) when is_list(blocks) do
    Enum.map_join(blocks, "", fn
      %{type: :text, text: text} -> text
      _block -> ""
    end)
  end

  defp summary_message_text(%{content: text}) when is_binary(text), do: text
  defp summary_message_text(_message), do: ""

  defp resolve_policy(policy) when is_pid(policy), do: policy
  defp resolve_policy(policy) when is_atom(policy), do: policy
  defp resolve_policy(policy), do: GenServer.whereis(policy)

  defp transcript_path(%{transcript_path: transcript_path}) when is_binary(transcript_path),
    do: transcript_path

  defp transcript_path(_state), do: ""

  # ---------------------------------------------------------------------------
  # Hook helpers
  # ---------------------------------------------------------------------------

  defp hook_ctx(state, turn_id \\ nil) do
    Hooks.context(Map.from_struct(state), %{
      turn_id: turn_id || state.turn_state.turn_id,
      transcript_path: transcript_path(state),
      mcp_hook_executor: Sigma.Coding.MCP.hook_executor(state.mcp_session, with_evidence: true),
      hook_async_runtime: state.hook_async_runtime,
      hook_execution: state.hook_execution,
      hook_async_callback: Hooks.async_callback(state.hook_async_contexts)
    })
  end

  defp start_mcp_clients(%{mcp_servers: servers} = state) when map_size(servers) == 0 do
    %{state | tools: state.base_tools, mcp_session: empty_mcp_session()}
  end

  defp start_mcp_clients(state) do
    agent = self()

    opts = [
      cwd: state.cwd,
      subscriber: agent,
      elicitation_callback: fn message, schema ->
        case request_mcp_elicitation(agent, message, schema) do
          {:accept, content} when is_map(content) -> {:accept, content}
          :decline -> :decline
          :cancel -> :cancel
          {:error, _reason} -> :cancel
          other -> other
        end
      end,
      sampling_callback: fn params ->
        GenServer.call(agent, {:mcp_sampling, params}, @mcp_sampling_timeout_ms + 5_000)
      end
    ]

    {:ok, mcp_tools, session} =
      Sigma.Coding.MCP.start_session(state.session_id, state.mcp_servers, opts)

    %{state | tools: state.base_tools ++ mcp_tools, mcp_session: session}
  end

  defp empty_mcp_session, do: %{handles: [], subscriptions: [], clients: %{}}

  defp notification_method(%{"method" => method}) when is_binary(method), do: method
  defp notification_method(%{method: method}) when is_binary(method), do: method
  defp notification_method(_), do: nil

  defp refresh_mcp_tools_from_notification(state, _notification) do
    Enum.reduce(state.mcp_session.subscriptions, state, fn {server_id, client, _sub}, acc ->
      case Sigma.Coding.MCP.refresh_server_tools(server_id, client) do
        {:ok, tools} -> replace_mcp_tools_for_server(acc, server_id, tools)
        {:error, _reason} -> acc
      end
    end)
  end

  defp replace_mcp_tools_for_server(state, server_id, new_tools) do
    kept =
      Enum.reject(state.tools, fn
        %Sigma.Coding.MCP.Tool{server_id: ^server_id} -> true
        _ -> false
      end)

    %{state | tools: kept ++ new_tools}
  end

  defp run_mcp_sampling(state, params) when is_map(params) do
    messages = Map.get(params, "messages") || Map.get(params, :messages) || []
    prompt = sampling_messages_to_prompt(messages)
    model = state.model || %{}
    model_id = Map.get(model, "id") || Map.get(model, :id) || "unknown"

    max_tokens =
      Map.get(params, "maxTokens") || Map.get(params, "max_tokens") || 1024

    context = %{
      system: Map.get(params, "systemPrompt") || Map.get(params, "system_prompt"),
      messages: [%{role: :user, content: prompt}],
      tools: []
    }

    request =
      %{
        model: model,
        context: context,
        session_id: state.session_id,
        log_session_id: state.log_session_id,
        origin_session_id: state.session_id,
        turn_id: state.turn_state.turn_id,
        purpose: :auxiliary,
        options: Keyword.put(state.provider_options, :max_tokens, max_tokens)
      }
      |> ProviderRequest.new()
      |> ProviderRequest.begin(System.monotonic_time(:millisecond), DateTime.utc_now())

    emit(state, {:metrics, :request_started, request_fact(request)})

    try do
      {result, request} = reduce_sampling_stream(state, request)
      emit(state, {:metrics, :request_finished, request_fact(request)})

      case result do
        {:ok, stop_reason, ai_msg} ->
          text = message_text(ai_msg)

          {:ok,
           %{
             "role" => "assistant",
             "content" => %{"type" => "text", "text" => text},
             "model" => to_string(model_id),
             "stopReason" => sampling_stop_reason(stop_reason)
           }}

        {:error, reason} ->
          {:error, reason}

        :missing ->
          {:error, "MCP sampling produced no completion"}
      end
    rescue
      error ->
        emit_failed_auxiliary_request(state, request, error)
        {:error, Exception.message(error)}
    catch
      :exit, reason ->
        emit_failed_auxiliary_request(state, request, reason)
        {:error, inspect(reason)}
    end
  end

  defp run_mcp_sampling(_state, _params), do: {:error, "Invalid sampling params"}

  defp reduce_sampling_stream(state, request) do
    {result, request} =
      state.provider
      |> Provider.stream(request)
      |> Enum.reduce_while({:missing, request}, fn
        %ProviderEvent{type: :usage_updated, usage: usage}, {result, request} ->
          {:cont, {result, put_request_usage(request, usage)}}

        %ProviderEvent{
          type: :response_completed,
          message: message,
          usage: usage,
          stop_reason: stop
        },
        {_result, request} ->
          request = put_request_usage(request, usage || ProviderUsage.from_map(message[:usage]))
          {:halt, {{:ok, stop, message}, request}}

        %ProviderEvent{type: :response_failed, error: error}, {_result, request} ->
          {:halt, {{:error, inspect(error)}, request}}

        _event, acc ->
          {:cont, acc}
      end)

    status = if match?({:ok, _, _}, result), do: :completed, else: :failed

    {result,
     ProviderRequest.finish(
       request,
       status,
       System.monotonic_time(:millisecond),
       DateTime.utc_now()
     )}
  end

  defp emit_failed_auxiliary_request(state, request, reason) do
    failed =
      ProviderRequest.finish(
        request,
        :failed,
        System.monotonic_time(:millisecond),
        DateTime.utc_now()
      )

    emit(
      state,
      {:metrics, :request_finished,
       Map.put(request_fact(failed), :failure_reason, inspect(reason))}
    )
  end

  defp sampling_messages_to_prompt(messages) when is_list(messages) do
    Enum.map_join(messages, "\n\n", fn
      %{"content" => content} when is_binary(content) ->
        content

      %{"content" => %{"type" => "text", "text" => text}} ->
        text

      %{"content" => blocks} when is_list(blocks) ->
        Enum.map_join(blocks, "\n", fn
          %{"type" => "text", "text" => text} -> text
          other -> inspect(other)
        end)

      other ->
        inspect(other)
    end)
  end

  defp sampling_messages_to_prompt(_), do: ""

  defp sampling_stop_reason(:stop), do: "endTurn"
  defp sampling_stop_reason(:end_turn), do: "endTurn"
  defp sampling_stop_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp sampling_stop_reason(reason) when is_binary(reason), do: reason
  defp sampling_stop_reason(_), do: "endTurn"

  defp elicitation_fields(%{"type" => "object", "properties" => properties})
       when is_map(properties) and map_size(properties) > 0 do
    fields =
      Enum.reduce_while(properties, [], fn {name, schema}, acc ->
        case elicitation_field(name, schema) do
          {:ok, field} -> {:cont, [field | acc]}
          :error -> {:halt, :unsupported}
        end
      end)

    case fields do
      :unsupported -> :unsupported
      list -> Enum.reverse(list)
    end
  end

  defp elicitation_fields(_), do: :unsupported

  defp elicitation_field(name, %{"type" => type} = schema)
       when type in ["string", "number", "integer", "boolean"] do
    {:ok,
     %{
       name: to_string(name),
       type: type,
       title: Map.get(schema, "title") || to_string(name),
       description: Map.get(schema, "description")
     }}
  end

  defp elicitation_field(_name, _schema), do: :error

  defp wait_for_mcp_elicitation_answer(pid, elicitation_id, timeout) do
    receive do
      {:mcp_elicitation_reply, ^elicitation_id, reply} ->
        reply
    after
      timeout ->
        GenServer.cast(pid, {:expire_mcp_elicitation, elicitation_id})
        {:error, "Timed out waiting for MCP elicitation."}
    end
  end

  defp public_mcp_elicitations(state) do
    state
    |> pending_mcp_elicitation_map()
    |> Map.values()
    |> Enum.sort_by(& &1.created_at)
    |> Enum.map(&public_mcp_elicitation/1)
  end

  defp public_mcp_elicitation(pending) do
    %{
      id: pending.id,
      message: pending.message,
      schema: pending.schema,
      fields: pending.fields
    }
  end

  defp pending_mcp_elicitation_map(%{pending_mcp_elicitations: map}) when is_map(map), do: map
  defp pending_mcp_elicitation_map(_), do: %{}

  defp put_pending_mcp_elicitation(state, id, pending) do
    put_pending_mcp_elicitations(state, Map.put(pending_mcp_elicitation_map(state), id, pending))
  end

  defp put_pending_mcp_elicitations(state, map) do
    %{state | pending_mcp_elicitations: map}
  end

  defp remove_mcp_elicitation_by_monitor(state, monitor_ref) do
    pending = pending_mcp_elicitation_map(state)

    case Enum.find(pending, fn {_id, item} -> item.monitor_ref == monitor_ref end) do
      {id, _item} ->
        {:ok, id, put_pending_mcp_elicitations(state, Map.delete(pending, id))}

      nil ->
        :error
    end
  end

  defp run_session_start_hook(state) do
    if :atomics.compare_exchange(state.start_hook_pending, 1, 0, 1) == :ok do
      outcome =
        Hooks.dispatch(:session_start, state.hook_specs, hook_ctx(state), %{
          source: state.resume_source
        })

      case Outcome.control(outcome) do
        {:halt, reason} ->
          {:block, reason || "SessionStart hook stopped the turn"}

        _ ->
          {:ok,
           %{state | messages: Hooks.prepend_context(state.messages, Outcome.context(outcome))}}
      end
    else
      {:ok, state}
    end
  end

  defp run_session_end_hook(state) do
    if state.writer do
      try do
        apply(Sigma.Session.Writer, :flush, [state.writer])
      catch
        :exit, reason ->
          Logger.warning(
            "[Sigma.Agent] Could not flush SessionEnd transcript: #{inspect(reason)}"
          )
      end
    end

    # Async hooks have already been joined. SessionEnd is synchronous and owned
    # by this final shutdown call, rather than the now-closed async runtime.
    context = Map.delete(hook_ctx(state), :hook_async_runtime)
    Hooks.dispatch(:session_end, state.hook_specs, context, %{reason: "other"})
  rescue
    e -> Logger.warning("[Sigma.Agent] SessionEnd hook crashed: #{Exception.message(e)}")
  catch
    :exit, reason ->
      Logger.warning("[Sigma.Agent] SessionEnd hook unavailable: #{inspect(reason)}")
  end

  defp run_user_prompt_submit_hook(state, user_msg) do
    if Sigma.Coding.Hooks.any_for_event?(state.hook_specs, :user_prompt_submit) do
      ctx = hook_ctx(state, Map.get(user_msg.metadata, :turn_id))
      prompt_text = message_text(user_msg)
      event_data = %{prompt: prompt_text}

      outcome = Hooks.dispatch(:user_prompt_submit, state.hook_specs, ctx, event_data)

      case Outcome.control(outcome) do
        {control, reason} when control in [:block, :halt] ->
          {:block, reason || "UserPromptSubmit hook stopped the turn"}

        _ ->
          updated_msg =
            case Outcome.context(outcome) do
              nil -> user_msg
              extra -> append_text_to_message(user_msg, extra)
            end

          {:ok, updated_msg, state}
      end
    else
      {:ok, user_msg, state}
    end
  end

  defp message_text(%{content: content}) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{type: :text, text: t} -> t
      _ -> ""
    end)
  end

  defp message_text(%{content: text}) when is_binary(text), do: text
  defp message_text(_), do: ""

  defp append_text_to_message(%{content: content} = msg, extra) when is_list(content) do
    {text_blocks, other_blocks} =
      Enum.split_with(content, &match?(%{type: :text, text: text} when is_binary(text), &1))

    text_block =
      text_blocks
      |> Enum.map(& &1.text)
      |> Enum.reject(&(&1 == ""))
      |> Kernel.++(["[Additional context from hook]\n#{extra}"])
      |> Enum.join("\n\n")
      |> then(&%{type: :text, text: &1})

    %{msg | content: [text_block | other_blocks]}
  end

  defp append_text_to_message(%{content: text} = msg, extra) when is_binary(text) do
    %{msg | content: text <> "\n\n[Additional context from hook]\n#{extra}"}
  end

  defp append_text_to_message(msg, _extra), do: msg

  defp request_fact(%ProviderRequest{} = request) do
    usage = request.usage && ProviderUsage.to_fact(request.usage)

    %{
      request_id: request.request_id,
      message_id: request.message_id,
      session_id: request.session_id,
      origin_session_id: request.origin_session_id,
      turn_id: request.turn_id,
      purpose: request.purpose,
      provider: model_value(request.model, [:provider, "provider"]),
      model: model_value(request.model, [:id, "id", :model, "model"]),
      revision: request.usage_revision,
      status: request.status,
      started_at: iso_datetime(request.started_at),
      finished_at: iso_datetime(request.finished_at),
      elapsed_ms: request.elapsed_ms,
      first_output_ms: request.first_output_ms,
      ttft_ms: request.ttft_ms,
      input_tokens_total: usage && usage.input_tokens_total,
      output_tokens_total: usage && usage.output_tokens_total,
      cache_read_tokens: usage && usage.cache_read_tokens,
      cache_write_tokens: usage && usage.cache_write_tokens,
      reasoning_tokens: usage && usage.reasoning_tokens,
      visible_output_tokens: usage && usage.visible_output_tokens,
      usage_status: usage && usage.usage_status,
      provenance: usage && usage.provenance
    }
  end

  defp put_request_usage(request, %ProviderUsage{} = usage),
    do: ProviderRequest.put_usage(request, usage)

  defp put_request_usage(request, _usage), do: request

  defp iso_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso_datetime(value) when is_binary(value), do: value
  defp iso_datetime(_value), do: nil

  defp model_value(model, keys) when is_map(model),
    do: Enum.find_value(keys, &Map.get(model, &1))

  defp model_value(_model, _keys), do: nil

  defp refresh_context_from_assembly(state, context, source \\ :assembled_context) do
    previous = state.context_snapshot

    snapshot =
      ContextPolicy.snapshot(
        context_revision: next_context_revision(previous),
        active_leaf: current_source_leaf(state) || context_active_leaf(previous),
        model: state.model,
        source: source,
        system: context.system,
        messages: context.messages,
        tools: context.tools,
        last_request_input_tokens: previous.last_request_input_tokens,
        last_request_id: previous.last_request_id,
        last_measured_at: previous.last_measured_at,
        last_measurement_source: previous.last_measurement_source
      )

    %{
      state
      | context_snapshot: snapshot,
        context_policy:
          context_policy(
            snapshot,
            state.provider,
            state.model,
            state.provider_options,
            state.context_limit
          )
    }
  end

  defp refresh_context_after_request(state, %ProviderRequest{} = request) do
    previous = state.context_snapshot
    input_tokens = request.usage && request.usage.input_tokens
    measured? = is_integer(input_tokens) and input_tokens >= 0
    active_leaf = current_source_leaf(state) || context_active_leaf(previous)

    snapshot =
      ContextPolicy.snapshot(
        context_revision: next_context_revision(previous),
        active_leaf: active_leaf,
        model: state.model,
        source: if(measured?, do: :provider_usage, else: :provider_usage_unknown),
        system_tokens: previous.estimate_components[:system],
        message_tokens: previous.estimate_components[:messages],
        tool_tokens: previous.estimate_components[:tools],
        skill_tokens: previous.estimate_components[:skills],
        attachment_tokens: previous.estimate_components[:attachments],
        reserved_messages: previous.estimate_components[:reserved_messages],
        next_request_estimated_input_tokens: previous.next_request_estimated_input_tokens,
        last_request_input_tokens: input_tokens,
        last_request_id: request.request_id,
        last_measured_at: iso_datetime(request.finished_at),
        last_measurement_source: if(measured?, do: :provider_usage, else: :unknown),
        stale: not measured? or active_leaf != context_active_leaf(previous)
      )

    %{
      state
      | context_snapshot: snapshot,
        context_policy:
          context_policy(
            snapshot,
            state.provider,
            state.model,
            state.provider_options,
            state.context_limit
          )
    }
  end

  defp invalidate_context(state, source) do
    previous = state.context_snapshot

    snapshot =
      ContextPolicy.invalidate(previous,
        active_leaf: current_source_leaf(state) || context_active_leaf(previous),
        model: state.model,
        source: source
      )

    %{
      state
      | context_snapshot: snapshot,
        context_policy:
          context_policy(
            snapshot,
            state.provider,
            state.model,
            state.provider_options,
            state.context_limit
          )
    }
  end

  defp context_policy(snapshot, provider, model, options, limit) do
    ContextPolicy.policy(snapshot,
      model: model,
      context_limit: limit,
      output_reserve: Provider.output_token_limit(provider, model, options),
      check_phase: :before_provider_dispatch
    )
  end

  defp next_context_revision(%ContextPolicy{context_revision: revision})
       when is_integer(revision) and revision >= 0,
       do: revision + 1

  defp next_context_revision(_snapshot), do: 1

  defp context_active_leaf(%ContextPolicy{active_leaf: active_leaf}), do: active_leaf
  defp context_active_leaf(_snapshot), do: nil

  defp elapsed_since(started) when is_integer(started),
    do: max(System.monotonic_time(:millisecond) - started, 0)

  defp elapsed_since(_started), do: nil

  defp emit(state, event) do
    case persist_event(state.on_event, event) do
      :ok ->
        notify_subscribers(state, event)
        :ok

      {:error, reason} ->
        throw({:event_persistence_failed, persisted_event_type(event), reason})
    end
  end

  defp notify_subscribers(%{control_pid: control_pid}, event)
       when is_pid(control_pid) and control_pid != self() do
    GenServer.cast(control_pid, {:notify_subscribers, event})
  end

  defp notify_subscribers(state, event) do
    Enum.each(state.subscribers, fn sub -> send(sub, event) end)
    :ok
  end

  @doc false
  def __backplane_messages_changed__(state),
    do: invalidate_context(state, state.context_snapshot.source)

  @doc false
  def __backplane_emit__(state, event), do: emit(state, event)

  @doc false
  def __backplane_acknowledge__(state), do: acknowledge_canonical(state)

  @doc false
  def __backplane_phase__(state, phase),
    do: set_turn_phase(state, state.turn_state.turn_id, phase)

  @doc false
  def __backplane_build_context__(state, messages, tools \\ nil, window \\ nil) do
    ContextBuilder.build(
      messages: Hooks.async_messages(messages, state.hook_async_contexts),
      session_context: state.session_context,
      system_prompt: state.system_prompt,
      tools: tools || Enum.map(state.tools, &Sigma.Coding.Tool.ai_definition/1),
      cwd: state.cwd,
      model: state.model,
      context_window: (window || state.context_window || %{})[:window] || 1
    )
  end

  defp excluded_context_ids(_messages, nil), do: MapSet.new()

  defp excluded_context_ids(messages, context_messages) do
    included = MapSet.new(context_messages, & &1.id)
    messages |> Enum.reject(&MapSet.member?(included, &1.id)) |> MapSet.new(& &1.id)
  end

  @doc false
  def __backplane_context_messages__(state) do
    Enum.reject(state.messages, &MapSet.member?(state.context_excluded_message_ids, &1.id))
  end

  @doc false
  def __backplane_context_window__(state, window) do
    event = {:context_window_started, window}

    if state.writer do
      case apply(Sigma.Session.Writer, :append, [state.writer, event]) do
        {:ok, _id} -> :ok
        error -> throw({:event_persistence_failed, :context_window, error})
      end
    end

    emit(state, event)

    %{
      state
      | context_window: window,
        context_excluded_message_ids: MapSet.new(state.messages, & &1.id)
    }
    |> invalidate_context(:context_window_started)
  end

  @doc false
  def __backplane_context_error__(state, context), do: context_budget_error(state, context)

  @doc false
  def __backplane_hook_context__(state, turn_id), do: hook_ctx(state, turn_id)

  @doc false
  def __backplane_prompt_hook__(state, message), do: run_user_prompt_submit_hook(state, message)

  @doc false
  def __backplane_stop_hook__(state, turn_id, messages, stop_hook_active) do
    Hooks.stop(:stop, state.hook_specs, hook_ctx(state, turn_id), messages, stop_hook_active)
  end

  @doc false
  def __backplane_request_started__(state, request, context) do
    set_turn_phase(state, request.turn_id, :streaming_provider)
    emit(state, {:turn_start})
    state = refresh_context_from_assembly(state, context)
    set_current_request(state, request.turn_id, request.request_id)
    emit(state, {:metrics, :request_started, request_fact(request)})
    %{state | current_request_id: request.request_id, backplane_request: request}
  end

  @doc false
  def __backplane_request_finished__(
        %{backplane_request: %{request_id: id}} = state,
        %{request_id: id} = request
      ) do
    emit(state, {:metrics, :request_finished, request_fact(request)})
    set_current_request(state, request.turn_id, nil)
    state = refresh_context_after_request(state, request)
    %{state | backplane_request: nil}
  end

  def __backplane_request_finished__(state, _request), do: state

  @doc false
  def __backplane_assistant_message__(message, id, turn_id),
    do: ai_to_agent_message(message, id, turn_id)

  @doc false
  def __backplane_dispatch_tool__(state, turn_id, operation, owner) do
    tool_call = %{
      id: operation.tool_call_id,
      name: operation.tool_name,
      arguments: operation.arguments,
      type: :tool_call
    }

    opts =
      __backplane_permission_options__(state, turn_id)
      |> Keyword.put(:on_tool_update, fn update ->
        send(owner, {:backplane_tool_update, tool_call, update})
      end)

    opts =
      if state.native_tools,
        do:
          Keyword.put(
            opts,
            :hook_async_callback_factory,
            HookDelivery.factory(state.writer, operation)
          ),
        else: opts

    case Sigma.Coding.Dispatcher.dispatch(tool_call, state.tools, opts) do
      {:ok, result} ->
        {:ok, Map.from_struct(result)}

      {:error, %ToolError{} = error} ->
        maybe_emit_approval_required(state, {:error, error}, tool_call)
        {:error, error}

      other ->
        other
    end
  end

  @doc false
  def __backplane_permission_options__(state, turn_id) do
    state.dispatcher_opts
    |> Keyword.put(:cwd, state.cwd)
    |> Keyword.put(:permission_policy, resolve_policy(state.policy))
    |> Keyword.put(:session_id, state.session_id)
    |> Keyword.put(:log_session_id, state.log_session_id)
    |> Keyword.put(:turn_id, turn_id)
    |> Keyword.put(:request_id, state.current_request_id)
    |> Keyword.put(
      :skill_roots,
      merge_skill_roots(state.dispatcher_opts, skill_grant_roots(state.tool_state, turn_id))
    )
    |> Keyword.put(:transcript_path, transcript_path(state))
    |> Keyword.put(:hook_specs, state.hook_specs)
    |> Keyword.put(:model, hook_ctx(state).model)
    |> Keyword.put(
      :mcp_hook_executor,
      Sigma.Coding.MCP.hook_executor(state.mcp_session, with_evidence: true)
    )
    |> Keyword.put(:hook_async_runtime, state.hook_async_runtime)
    |> Keyword.put(:hook_async_callback, Hooks.async_callback(state.hook_async_contexts))
    |> Keyword.put(:tool_state, state.tool_state)
    |> Keyword.put(:on_tool_fact, fn fact -> emit(state, {:metrics, :tool_finished, fact}) end)
  end

  defp subagents_can_stop?(%{subagents: nil}), do: true
  defp subagents_can_stop?(state), do: Sigma.Agent.Subagents.can_stop(state.subagents) == :ok

  defp init_backplane_store(opts) do
    case Keyword.get(opts, :backplane_store) do
      pid when is_pid(pid) ->
        if Process.alive?(pid),
          do: {:ok, pid, false},
          else: {:error, :backplane_store_unavailable}

      nil ->
        path =
          Keyword.get(opts, :backplane_runtime_path) ||
            backplane_runtime_path(opts[:transcript_path])

        if is_nil(path) do
          {:error, :backplane_runtime_path_required}
        else
          case Sigma.Agent.Backplane.Store.start_link(path: path) do
            {:ok, pid} -> {:ok, pid, true}
            {:error, {:already_started, _pid}} -> {:error, :backplane_runtime_path_in_use}
            {:error, reason} -> {:error, {:backplane_store_unavailable, reason}}
          end
        end

      _invalid ->
        {:error, :invalid_backplane_store}
    end
  end

  defp backplane_runtime_path(path) when is_binary(path) and path != "", do: path <> ".runtime"
  defp backplane_runtime_path(_path), do: nil

  defp stop_backplane_store(%{backplane_store_owned: true, backplane_store: pid})
       when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
  catch
    :exit, _reason -> :ok
  end

  defp stop_backplane_store(_state), do: :ok

  defp persist_event(nil, _event), do: :ok

  defp persist_event(on_event, event) do
    case on_event.(event) do
      {:error, _reason} = error -> error
      _result -> :ok
    end
  rescue
    exception -> {:error, {:event_callback_exception, exception.__struct__}}
  catch
    kind, reason -> {:error, {:event_callback_failure, kind, reason}}
  end

  defp persisted_event_type({:agent_start, _cwd}), do: :session
  defp persisted_event_type({:message_end, _message}), do: :message
  defp persisted_event_type({:compact, _summary, _first_kept_id}), do: :compaction
  defp persisted_event_type({event_type, _rest}) when is_atom(event_type), do: event_type
  defp persisted_event_type({event_type}) when is_atom(event_type), do: event_type
  defp persisted_event_type(_event), do: :runtime

  defp wait_for_user_question_answer(pid, question_id, timeout) do
    receive do
      {:ask_user_question_reply, ^question_id, reply} ->
        reply
    after
      timeout ->
        GenServer.cast(pid, {:expire_user_question, question_id})
        {:error, "Timed out waiting for the user to answer."}
    end
  end

  defp public_user_questions(state) do
    state
    |> pending_user_question_map()
    |> Map.values()
    |> Enum.sort_by(& &1.created_at)
    |> Enum.map(&public_user_question/1)
  end

  defp public_user_question(pending_question) do
    pending_question.request
    |> Map.put(:id, pending_question.id)
    |> Map.drop([:reply_to, :monitor_ref, :created_at])
  end

  defp remove_user_question_by_monitor(state, monitor_ref) do
    pending_questions = pending_user_question_map(state)

    case Enum.find(pending_questions, fn {_id, question} ->
           question.monitor_ref == monitor_ref
         end) do
      {question_id, _question} ->
        state = put_pending_user_questions(state, Map.delete(pending_questions, question_id))

        {:ok, question_id, state}

      nil ->
        :error
    end
  end

  defp pending_user_question_map(state) do
    Map.get(state, :pending_user_questions, %{})
  end

  defp put_pending_user_question(state, question_id, pending_question) do
    pending_questions =
      state
      |> pending_user_question_map()
      |> Map.put(question_id, pending_question)

    put_pending_user_questions(state, pending_questions)
  end

  defp put_pending_user_questions(state, pending_questions) do
    Map.put(state, :pending_user_questions, pending_questions)
  end
end
