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
    :turn_started_at,
    :turn_started_monotonic,
    :control_pid,
    :last_cancelled_turn_id,
    :policy,
    :execution_engine,
    :backplane_store,
    :backplane_store_owned,
    :backplane_request,
    messages: [],
    subscribers: [],
    current_turn_assistant_message: nil,
    current_turn_resources: [],
    pending_user_questions: %{},
    pending_mcp_elicitations: %{},
    prompt_queue: %PromptQueue{},
    turn_state: %TurnState{},
    hook_specs: [],
    stop_hook_active: false,
    backplane_tool_results: [],
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
    with {:ok, engine} <- execution_engine(opts) do
      {name, opts} = Keyword.pop(Keyword.put(opts, :execution_engine, engine), :name)
      gen_opts = if name, do: [name: name], else: []
      GenServer.start_link(__MODULE__, opts, gen_opts)
    end
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

  def status(pid), do: GenServer.call(pid, :status)

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
  def end_session_operation(pid), do: GenServer.call(pid, :end_session_operation)
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
    case init_backplane_store(opts) do
      {:ok, store, owned?} -> init_agent(opts, store, owned?)
      {:error, reason} -> {:stop, reason}
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
        messages: opts[:messages] || [],
        system: :unknown,
        tools: :unknown,
        skills: :unknown,
        stale: true
      )

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
      context_policy: context_policy(context_snapshot, opts[:model], opts[:options] || []),
      hook_specs: hook_specs,
      prompt_queue: PromptQueue.new(),
      turn_state: TurnState.idle(),
      resume_source: Keyword.get(opts, :resume_source, :startup),
      execution_engine: Keyword.fetch!(opts, :execution_engine),
      backplane_store: backplane_store,
      backplane_store_owned: backplane_store_owned
    }

    {:ok, state, {:continue, :session_start}}
  end

  @impl true
  def handle_continue(:session_start, state) do
    {:noreply, state |> start_mcp_clients() |> run_session_start_hook()}
  end

  @impl true
  def terminate(reason, state) do
    release_all_resources(state)

    if Sigma.Coding.Hooks.any_for_event?(state.hook_specs, :session_end) do
      task = Task.async(fn -> run_session_end_hook(state, reason) end)

      case Task.yield(task, 2_000) do
        nil ->
          Task.shutdown(task, :brutal_kill)
          Logger.warning("[Sigma.Agent] SessionEnd hooks exceeded 2s budget, killed")

        _ ->
          :ok
      end
    end

    Sigma.Coding.MCP.stop(state.mcp_session)
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
    if is_nil(state.current_turn_task) and state.turn_state.phase != :session_operation do
      {:reply, :ok,
       %{state | turn_state: TurnState.transition(state.turn_state, :session_operation)}}
    else
      {:reply, {:error, :session_busy}, state}
    end
  end

  @impl true
  def handle_call(:end_session_operation, _from, state) do
    if state.turn_state.phase == :session_operation do
      {:reply, :ok, %{state | turn_state: TurnState.transition(state.turn_state, :idle)}}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:compact, opts}, _from, state) do
    if state.turn_state.phase == :session_operation and is_nil(state.current_turn_task) do
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
      state.turn_state.phase != :session_operation or not is_nil(state.current_turn_task) ->
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
            item = Map.put(item, :retry_restore_messages, state.messages)
            state = %{state | messages: context_messages}
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
        {:ok, queue} -> {:reply, :ok, %{state | prompt_queue: queue}}
        {:error, _reason} = error -> {:reply, error, state}
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
  def handle_call(:reload_mcp_tools, _from, state) do
    Sigma.Coding.MCP.stop(state.mcp_session)
    state = %{state | mcp_session: empty_mcp_session()} |> start_mcp_clients()
    mcp_count = length(state.tools) - length(state.base_tools)
    {:reply, {:ok, mcp_count}, state}
  end

  @impl true
  def handle_call(:cancel, _from, state) do
    cond do
      state.turn_state.phase == :cancelling ->
        {:reply, {:already_cancelling, state.turn_state.turn_id}, state}

      is_nil(state.current_turn_task) and not is_nil(state.last_cancelled_turn_id) ->
        {:reply, {:already_cancelled, state.last_cancelled_turn_id}, state}

      is_nil(state.current_turn_task) ->
        {:reply, {:error, :no_active_turn}, state}

      true ->
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
      state.turn_state.turn_id == turn_id and not is_nil(state.current_turn_task) ->
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
    if state.turn_state.turn_id == turn_id and state.turn_state.phase != :cancelling do
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
        {ref,
         {:ok,
          %{
            messages: new_messages,
            outcome: task_outcome,
            context_snapshot: context_snapshot,
            context_policy: context_policy
          }}},
        state
      )
      when is_reference(ref) do
    case state.current_turn_task do
      %Task{ref: ^ref} ->
        Process.demonitor(ref, [:flush])
        outcome = if state.turn_state.phase == :cancelling, do: :cancelled, else: task_outcome

        new_state =
          state
          |> clear_cancel_timer()
          |> Map.put(:messages, new_messages)
          |> Map.put(:context_snapshot, context_snapshot)
          |> Map.put(:context_policy, context_policy)
          |> Map.put(:current_turn_task, nil)
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
          |> finish_turn(if(cancelling?, do: :cancelled, else: :failed), reason)

        unless cancelling?, do: emit(new_state, {:turn_error, reason})

        {:noreply,
         maybe_start_follow_up(new_state, if(cancelling?, do: :cancelled, else: :failed))}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:canonical_messages, turn_id, messages}, state) do
    if state.turn_state.turn_id == turn_id and is_list(messages) do
      {:noreply, %{state | messages: messages}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case state.current_turn_task do
      %Task{ref: ^ref} ->
        cancelling? = state.turn_state.phase == :cancelling

        if not cancelling? and reason not in [:normal, :shutdown, :killed] do
          emit(state, {:turn_error, reason})
        end

        outcome = if cancelling?, do: :cancelled, else: :failed

        new_state =
          state
          |> clear_cancel_timer()
          |> Map.put(:current_turn_task, nil)
          |> finish_turn(outcome, reason)

        {:noreply, maybe_start_follow_up(new_state, outcome)}

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
        Task.shutdown(task, :brutal_kill)

        new_state =
          state
          |> clear_cancel_timer()
          |> Map.put(:current_turn_task, nil)
          |> finish_turn(:cancelled)

        {:noreply, maybe_start_follow_up(new_state, :cancelled)}

      _task ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

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
        state = start_turn(state, item)
        info = prompt_info(item, item.turn_id)
        emit(state, {:prompt_admitted, :accepted, info})
        emit_prompt_telemetry(state, :accepted)
        {{:accepted, info}, state}

      {:ok, item} ->
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
           dispatcher_opts: Keyword.get(opts, :dispatcher_opts, []),
           prepared_resources: prepared_resources
         }}
    end
  end

  defp new_prompt_item(_content, _opts), do: {:error, :invalid_prompt}

  defp admission_mode(:steering, _opts), do: :steering
  defp admission_mode(:follow_up, _opts), do: :follow_up

  defp admission_mode(:auto, opts) do
    case Keyword.get(opts, :admission, :follow_up) do
      :steering -> :steering
      _mode -> :follow_up
    end
  end

  defp start_turn(state, item) do
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
        turn_state: TurnState.start(item.turn_id, cancellation_ref)
    }

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        try do
          {:ok, execute_turn(task_state, item)}
        catch
          {:event_persistence_failed, event_type, reason} ->
            {:error, {:event_persistence_failed, event_type, reason}}
        end
      end)

    %{
      state
      | current_turn_task: task,
        current_turn_resources: state.current_turn_resources,
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

    state = %{
      state
      | turn_started_at: nil,
        turn_started_monotonic: nil,
        current_request_id: nil
    }

    case outcome do
      :completed ->
        emit(state, {:turn_completed, turn_id})
        state

      :failed ->
        emit(state, {:turn_failed, turn_id})
        state

      :cancelled ->
        emit(state, {:turn_cancelled})
        %{state | last_cancelled_turn_id: turn_id}
    end
  end

  defp maybe_start_follow_up(state, outcome) when outcome in [:completed, :failed, :cancelled] do
    case PromptQueue.pop(state.prompt_queue, :follow_up) do
      {nil, _queue} ->
        state

      {item, queue} ->
        state = %{state | prompt_queue: queue}
        emit(state, {:prompt_consumed, :follow_up, prompt_info(item, item.turn_id)})
        start_turn(state, item)
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

    (state.current_turn_resources ++ queued_resources)
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

    state = %{state | stop_hook_active: false}

    user_msg =
      Message.user(item.message_id, item.content)
      |> Map.put(:attachments, item.attachments)
      |> Map.put(:metadata, %{
        turn_id: item.turn_id,
        retry_of_turn_id: item.retry_of_turn_id,
        skill_preparations: prepared_resource_metadata(item.prepared_resources)
      })

    case run_user_prompt_submit_hook(state, user_msg) do
      {:block, reason} ->
        notify_retry_admission(item, {:error, reason})
        emit(state, {:turn_blocked, reason})

        %{
          messages: Map.get(item, :retry_restore_messages, state.messages),
          outcome: :failed,
          context_snapshot: state.context_snapshot,
          context_policy: state.context_policy
        }

      {:ok, user_msg, state} ->
        state = %{state | messages: state.messages ++ [user_msg]}
        emit(state, {:message_start, user_msg})
        emit(state, {:message_end, user_msg})
        notify_retry_admission(item, :committed)
        acknowledge_canonical(state)

        {state, outcome} = run_turn_loop(state, item.turn_id)
        state = if outcome == :completed, do: maybe_compact(state), else: state

        %{
          messages: state.messages,
          outcome: outcome,
          context_snapshot: state.context_snapshot,
          context_policy: state.context_policy
        }
    end
  end

  defp notify_retry_admission(%{retry_admission_notify: {pid, ref}}, result)
       when is_pid(pid) and is_reference(ref) do
    send(pid, {:retry_admission, ref, result})
  end

  defp notify_retry_admission(_item, _result), do: :ok

  defp run_turn_loop(%{execution_engine: :backplane} = state, turn_id),
    do: Sigma.Agent.Backplane.Engine.run(state, turn_id)

  defp run_turn_loop(state, turn_id) do
    set_turn_phase(state, turn_id, :streaming_provider)
    emit(state, {:turn_start})

    ai_tools = Enum.map(state.tools, &Sigma.Coding.Tool.ai_definition/1)

    context =
      ContextBuilder.build(
        messages: state.messages,
        session_context: state.session_context,
        system_prompt: state.system_prompt,
        tools: ai_tools,
        cwd: state.cwd,
        model: state.model
      )

    state = refresh_context_from_assembly(state, context)

    case context_budget_error(state, context) do
      nil ->
        run_provider_step(state, turn_id, context)

      error ->
        emit(state, {:turn_error, error})
        {state, :failed}
    end
  end

  defp run_provider_step(state, turn_id, context) do
    params = %{
      model: state.model,
      session_id: state.session_id,
      log_session_id: state.log_session_id,
      turn_id: turn_id,
      origin_session_id: state.session_id,
      purpose: :turn,
      context: context,
      options: state.provider_options
    }

    case run_stream(state, params) do
      {:error, state} ->
        outcome = if turn_cancelled?(state, turn_id), do: :cancelled, else: :failed
        {state, outcome}

      {state, assistant_msg} ->
        tool_calls = extract_tool_calls(assistant_msg)

        if tool_calls != [] do
          set_turn_phase(state, turn_id, :running_tools)
          {state, tool_result_messages} = execute_tools(state, tool_calls)
          emit(state, {:turn_end, assistant_msg, tool_result_messages})

          if turn_cancelled?(state, turn_id) do
            {state, :cancelled}
          else
            continue_after_safe_boundary(state, turn_id)
          end
        else
          emit(state, {:turn_end, assistant_msg, []})

          case consume_steering(state, turn_id) do
            {:consumed, state} -> run_turn_loop(state, turn_id)
            {:none, state} -> run_stop_hook(state, assistant_msg, turn_id)
            {:cancelled, state} -> {state, :cancelled}
          end
        end
    end
  end

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
        output_reserve: provider_output_reserve(state.provider_options)
      )

    if policy.overflow in [:overflow, :hard_overflow] do
      ProviderError.from_exception(
        "context token limit exceeded: estimated input " <>
          "#{snapshot.next_request_estimated_input_tokens}, output reserve " <>
          "#{policy.output_reserve}, context window #{policy.context_window}"
      )
    end
  end

  defp provider_output_reserve(options) do
    Keyword.get(options, :max_tokens) || Keyword.get(options, :max_output_tokens)
  end

  defp continue_after_safe_boundary(state, turn_id) do
    case consume_steering(state, turn_id) do
      {:consumed, state} -> run_turn_loop(state, turn_id)
      {:none, state} -> run_turn_loop(state, turn_id)
      {:cancelled, state} -> {state, :cancelled}
    end
  end

  defp consume_steering(%{control_pid: control_pid} = state, turn_id)
       when is_pid(control_pid) do
    case GenServer.call(control_pid, {:peek_steering, turn_id}, :infinity) do
      nil ->
        {:none, state}

      :cancelled ->
        {:cancelled, state}

      item ->
        user_msg = Message.user(item.message_id, item.content)

        case run_user_prompt_submit_hook(state, user_msg) do
          {:block, reason} ->
            emit(state, {:prompt_rejected, item.message_id, reason})

            :ok =
              GenServer.call(control_pid, {:ack_steering, turn_id, item.message_id}, :infinity)

            {:none, state}

          {:ok, user_msg, state} ->
            state = %{state | messages: state.messages ++ [user_msg]}
            emit(state, {:message_start, user_msg})
            emit(state, {:message_end, user_msg})
            acknowledge_canonical(state)

            :ok =
              GenServer.call(control_pid, {:ack_steering, turn_id, item.message_id}, :infinity)

            emit(state, {:prompt_consumed, :steering, prompt_info(item, turn_id)})
            {:consumed, state}
        end
    end
  end

  defp consume_steering(state, _turn_id), do: {:none, state}

  defp turn_cancelled?(%{control_pid: control_pid}, turn_id) when is_pid(control_pid),
    do: GenServer.call(control_pid, {:cancelled?, turn_id}, :infinity)

  defp turn_cancelled?(_state, _turn_id), do: false

  defp set_turn_phase(%{control_pid: control_pid}, turn_id, phase) when is_pid(control_pid),
    do: GenServer.cast(control_pid, {:turn_phase, turn_id, phase})

  defp set_turn_phase(_state, _turn_id, _phase), do: :ok

  defp set_current_request(%{control_pid: control_pid}, turn_id, request_id)
       when is_pid(control_pid),
       do: GenServer.cast(control_pid, {:current_request, turn_id, request_id})

  defp set_current_request(_state, _turn_id, _request_id), do: :ok

  defp run_stream(state, params) do
    assistant_id = "msg_assistant_#{System.unique_integer([:positive])}"

    request =
      params
      |> Map.put(:message_id, assistant_id)
      |> ProviderRequest.new()
      |> ProviderRequest.begin(System.monotonic_time(:millisecond), DateTime.utc_now())

    state = %{state | current_request_id: request.request_id}
    set_current_request(state, request.turn_id, request.request_id)
    emit(state, {:metrics, :request_started, request_fact(request)})

    run_stream_request(state, request, assistant_id)
  end

  defp run_stream_request(state, request, assistant_id) do
    stream = Provider.stream(state.provider, request)

    {final_state, failed?, final_request, terminal_status} =
      Enum.reduce_while(stream, {state, false, request, nil}, fn event,
                                                                 {acc_state, _failed?,
                                                                  acc_request, terminal_status} ->
        case event do
          %ProviderEvent{type: :response_started, message: ai_msg} ->
            agent_msg = ai_to_agent_message(ai_msg, assistant_id, request.turn_id)
            emit(acc_state, {:message_start, agent_msg})

            {:cont,
             {%{acc_state | current_turn_assistant_message: agent_msg}, false, acc_request,
              terminal_status}}

          %ProviderEvent{type: :content_text_delta, message: ai_msg} = normalized_event ->
            agent_msg = ai_to_agent_message(ai_msg, assistant_id, request.turn_id)
            emit(acc_state, {:message_update, agent_msg, legacy_stream_event(normalized_event)})

            next_request =
              ProviderRequest.mark_output(acc_request, System.monotonic_time(:millisecond), :text)

            {:cont,
             {%{acc_state | current_turn_assistant_message: agent_msg}, false, next_request,
              terminal_status}}

          %ProviderEvent{type: :content_thinking_delta, message: ai_msg} = normalized_event ->
            agent_msg = ai_to_agent_message(ai_msg, assistant_id, request.turn_id)
            emit(acc_state, {:message_update, agent_msg, legacy_stream_event(normalized_event)})

            next_request =
              ProviderRequest.mark_output(
                acc_request,
                System.monotonic_time(:millisecond),
                :thinking
              )

            {:cont,
             {%{acc_state | current_turn_assistant_message: agent_msg}, false, next_request,
              terminal_status}}

          %ProviderEvent{type: :tool_call_started, message: ai_msg} = normalized_event ->
            agent_msg = ai_to_agent_message(ai_msg, assistant_id, request.turn_id)
            emit(acc_state, {:message_update, agent_msg, legacy_stream_event(normalized_event)})

            next_request =
              ProviderRequest.mark_output(
                acc_request,
                System.monotonic_time(:millisecond),
                :tool_arguments
              )

            {:cont,
             {%{acc_state | current_turn_assistant_message: agent_msg}, false, next_request,
              terminal_status}}

          %ProviderEvent{type: :tool_call_arguments_delta, message: ai_msg} = normalized_event ->
            agent_msg = ai_to_agent_message(ai_msg, assistant_id, request.turn_id)
            emit(acc_state, {:message_update, agent_msg, legacy_stream_event(normalized_event)})

            next_request =
              ProviderRequest.mark_output(
                acc_request,
                System.monotonic_time(:millisecond),
                :tool_arguments
              )

            {:cont,
             {%{acc_state | current_turn_assistant_message: agent_msg}, false, next_request,
              terminal_status}}

          %ProviderEvent{type: :tool_call_completed, message: ai_msg} = normalized_event ->
            agent_msg = ai_to_agent_message(ai_msg, assistant_id, request.turn_id)
            emit(acc_state, {:message_update, agent_msg, legacy_stream_event(normalized_event)})

            next_request =
              ProviderRequest.mark_output(
                acc_request,
                System.monotonic_time(:millisecond),
                :tool_arguments
              )

            {:cont,
             {%{acc_state | current_turn_assistant_message: agent_msg}, false, next_request,
              terminal_status}}

          %ProviderEvent{type: :usage_updated, usage: usage, message: ai_msg} ->
            next_request =
              case usage || (is_map(ai_msg) && ProviderUsage.from_map(ai_msg[:usage])) do
                %ProviderUsage{} = normalized ->
                  %{acc_request | usage: normalized, usage_revision: normalized.usage_revision}

                _missing ->
                  acc_request
              end

            next_state =
              if is_map(ai_msg) do
                %{
                  acc_state
                  | current_turn_assistant_message:
                      ai_to_agent_message(ai_msg, assistant_id, request.turn_id)
                }
              else
                acc_state
              end

            {:cont, {next_state, false, next_request, terminal_status}}

          %ProviderEvent{
            type: :response_completed,
            message: ai_msg,
            usage: usage,
            stop_reason: stop_reason
          } ->
            agent_msg = ai_to_agent_message(ai_msg, assistant_id, request.turn_id, stop_reason)
            emit(acc_state, {:message_end, agent_msg})

            next_request =
              put_request_usage(acc_request, usage || ProviderUsage.from_map(ai_msg[:usage]))

            next_state = %{
              acc_state
              | messages: acc_state.messages ++ [agent_msg],
                current_turn_assistant_message: agent_msg
            }

            acknowledge_canonical(next_state)

            {:cont, {next_state, false, next_request, :completed}}

          %ProviderEvent{type: :response_failed, error: %ProviderError{kind: :cancelled}} ->
            {:halt, {acc_state, true, acc_request, :cancelled}}

          %ProviderEvent{type: :response_failed, error: error} ->
            emit(acc_state, {:turn_error, error})
            {:halt, {acc_state, true, acc_request, :failed}}
        end
      end)

    final_request =
      ProviderRequest.finish(
        final_request,
        terminal_status || if(failed?, do: :failed, else: :completed),
        System.monotonic_time(:millisecond),
        DateTime.utc_now()
      )

    final_state = refresh_context_after_request(final_state, final_request)
    emit(final_state, {:metrics, :request_finished, request_fact(final_request)})
    set_current_request(final_state, request.turn_id, nil)
    assistant_msg = final_state.current_turn_assistant_message

    cond do
      failed? ->
        {:error, final_state}

      assistant_msg ->
        {%{final_state | current_turn_assistant_message: nil}, assistant_msg}

      true ->
        error = ProviderError.malformed(:empty_response)
        emit(state, {:turn_error, error})
        {:error, state}
    end
  rescue
    exception ->
      failed =
        ProviderRequest.finish(
          request,
          :failed,
          System.monotonic_time(:millisecond),
          DateTime.utc_now()
        )

      emit(
        state,
        {:metrics, :request_finished, request_fact(failed)}
      )

      emit(state, {:turn_error, ProviderError.from_exception(exception)})
      {:error, state}
  catch
    kind, reason ->
      failed =
        ProviderRequest.finish(
          request,
          :failed,
          System.monotonic_time(:millisecond),
          DateTime.utc_now()
        )

      emit(
        state,
        {:metrics, :request_finished, request_fact(failed)}
      )

      emit(state, {:turn_error, ProviderError.from_exception({kind, reason})})
      {:error, state}
  end

  defp legacy_stream_event(%ProviderEvent{
         type: :content_text_delta,
         index: index,
         delta: delta,
         message: message
       }),
       do: {:text_delta, index, delta, message}

  defp legacy_stream_event(%ProviderEvent{
         type: :content_thinking_delta,
         index: index,
         delta: delta,
         message: message
       }),
       do: {:thinking_delta, index, delta, message}

  defp legacy_stream_event(%ProviderEvent{
         type: :tool_call_started,
         index: index,
         message: message
       }),
       do: {:toolcall_start, index, message}

  defp legacy_stream_event(%ProviderEvent{
         type: :tool_call_arguments_delta,
         index: index,
         delta: delta,
         message: message
       }),
       do: {:toolcall_delta, index, delta, message}

  defp legacy_stream_event(%ProviderEvent{
         type: :tool_call_completed,
         index: index,
         tool_call: tool_call,
         message: message
       }),
       do: {:toolcall_end, index, tool_call, message}

  defp extract_tool_calls(msg) do
    case msg && msg.content do
      content when is_list(content) ->
        Enum.filter(content, &executable_tool_call?/1)

      _ ->
        []
    end
  end

  defp executable_tool_call?(%{type: :tool_call, id: id, name: name, arguments: args})
       when is_binary(id) and is_binary(name) and is_map(args),
       do: true

  defp executable_tool_call?(_block), do: false

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

  defp execute_tools(state, tool_calls) do
    Enum.each(tool_calls, fn tc ->
      emit(state, {:tool_execution_start, tc.id, tc.name, tc.arguments})
    end)

    tool_calls_by_id = Map.new(tool_calls, &{&1.id, &1})

    opts =
      state.dispatcher_opts
      |> Keyword.put(:cwd, state.cwd)
      |> Keyword.put(:permission_policy, resolve_policy(state.policy))
      |> Keyword.put(:session_id, state.session_id)
      |> Keyword.put(:log_session_id, state.log_session_id)
      |> Keyword.put(:turn_id, state.turn_state.turn_id)
      |> Keyword.put(
        :skill_roots,
        merge_skill_roots(
          state.dispatcher_opts,
          skill_grant_roots(state.tool_state, state.turn_state.turn_id)
        )
      )
      |> Keyword.put(:transcript_path, transcript_path(state))
      |> Keyword.put(:hook_specs, state.hook_specs)
      |> Keyword.put(:tool_state, state.tool_state)
      |> Keyword.put(:request_id, state.current_request_id)
      |> Keyword.put(:on_tool_fact, fn fact -> emit(state, {:metrics, :tool_finished, fact}) end)
      |> Keyword.put(:on_tool_update, fn update ->
        case Map.get(tool_calls_by_id, update.tool_call_id) do
          nil ->
            :ok

          tool_call ->
            emit(
              state,
              {:tool_execution_update, tool_call.id, tool_call.name, tool_call.arguments, update}
            )
        end
      end)

    results = Sigma.Coding.Dispatcher.dispatch_batch(tool_calls, state.tools, opts)

    {tool_result_messages, state} =
      Enum.map_reduce(results, state, fn {tool_call, result}, acc_state ->
        msg_id = "msg_tool_res_#{System.unique_integer([:positive])}"

        {content, is_error, error_kind} =
          case result do
            {:ok, %{content: content} = result} ->
              {content, Map.get(result, :is_error, false), nil}

            {:error, %ToolError{message: message, kind: kind}} ->
              maybe_emit_approval_required(acc_state, result, tool_call)
              {[%{type: :text, text: "Error: #{message}"}], true, kind}

            _malformed ->
              {[%{type: :text, text: "Error: malformed tool runtime result"}], true, :malformed}
          end

        tool_res_msg =
          Message.tool_result(msg_id, %{
            tool_call_id: tool_call.id,
            tool_name: tool_call.name,
            content: content,
            is_error: is_error,
            timestamp: DateTime.to_unix(DateTime.utc_now(), :millisecond)
          })

        emit(acc_state, {:tool_execution_end, tool_call.id, tool_call.name, content, is_error})
        emit(acc_state, {:message_start, tool_res_msg})
        emit(acc_state, {:message_end, tool_res_msg})

        acc_state =
          acc_state
          |> Map.update!(:messages, &(&1 ++ [tool_res_msg]))
          |> track_tool_failure(tool_call, error_kind)

        acknowledge_canonical(acc_state)
        {tool_res_msg, acc_state}
      end)

    state = maybe_inject_loop_breaker_nudge(state, results)
    {state, tool_result_messages}
  end

  defp acknowledge_canonical(%{control_pid: control_pid, turn_state: %{turn_id: turn_id}} = state)
       when is_pid(control_pid) and is_binary(turn_id) do
    send(control_pid, {:canonical_messages, turn_id, state.messages})
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

  # MCP transport-failure loop breaker
  # -------------------------------------------------------------------------
  # When an MCP tool call fails (e.g. transport down, server unreachable),
  # a naive model will keep calling it. Track consecutive failures per
  # `(tool_name, args)` key in `state.tool_state` (ETS) and, once the
  # threshold is hit, inject a synthetic user-role message that tells the
  # model to switch tools or stop and report.

  @tool_loop_breaker_threshold 3
  @tool_loop_breaker_window_ms 5 * 60 * 1_000

  defp track_tool_failure(state, tool_call, error_kind) do
    if error_kind in [:transport_failure, :execution, :malformed] do
      key = tool_failure_key(tool_call)
      :ets.update_counter(state.tool_state, key, {2, 1}, {key, 0})
    else
      :ets.delete(state.tool_state, tool_failure_key(tool_call))
    end

    state
  end

  defp tool_failure_key(%{name: name, arguments: args}) do
    {:tool_loop, to_string(name), :erlang.phash2(args)}
  end

  defp maybe_inject_loop_breaker_nudge(state, results) do
    triggers =
      Enum.flat_map(results, fn {tool_call, result} ->
        if failure_to_bump?(result) and
             failure_count_at_least?(
               state,
               tool_failure_key(tool_call),
               @tool_loop_breaker_threshold
             ) and
             never_nudged_recently?(state, tool_failure_key(tool_call)) do
          record_nudge(state, tool_failure_key(tool_call))
          [tool_call]
        else
          []
        end
      end)

    Enum.reduce(triggers, state, fn tool_call, acc -> inject_nudge(acc, tool_call) end)
  end

  defp failure_to_bump?({:error, %ToolError{kind: :transport_failure}}), do: true
  defp failure_to_bump?({:error, %ToolError{kind: :execution}}), do: true
  defp failure_to_bump?(_), do: false

  defp failure_count_at_least?(state, key, threshold) do
    case :ets.lookup(state.tool_state, key) do
      [{^key, count}] -> count >= threshold
      _ -> false
    end
  end

  defp never_nudged_recently?(state, key) do
    case :ets.lookup(state.tool_state, {:tool_loop_nudge_at, key}) do
      [] -> true
      [{_, ts}] -> System.monotonic_time(:millisecond) - ts > @tool_loop_breaker_window_ms
      _ -> true
    end
  end

  defp record_nudge(state, key) do
    :ets.insert(
      state.tool_state,
      {{:tool_loop_nudge_at, key}, System.monotonic_time(:millisecond)}
    )

    :ets.delete(state.tool_state, key)
  end

  defp inject_nudge(state, tool_call) do
    text =
      "[Loop breaker] The tool `#{tool_call.name}` has failed #{@tool_loop_breaker_threshold} times " <>
        "in a row. Stop calling it and either pick a different tool, ask the user, or " <>
        "report the failure. Arguments: #{inspect(tool_call.arguments)}."

    msg = Message.user("loop_breaker_#{System.unique_integer([:positive])}", text)
    state = %{state | messages: state.messages ++ [msg]}
    emit(state, {:message_start, msg})
    emit(state, {:message_end, msg})
    state
  end

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

  @default_compact_threshold 80_000
  @compact_context_ratio 0.8

  defp maybe_compact(state) do
    input_tokens =
      state.messages
      |> Enum.reverse()
      |> Enum.find_value(0, fn msg ->
        if msg.role == :assistant and msg.usage != nil do
          get_in(msg.usage, [:input]) || 0
        end
      end)

    if input_tokens >= compact_threshold(state.model) do
      {state, _result} = run_compact(state, trigger: :auto)
      state
    else
      state
    end
  end

  defp compact_threshold(model) do
    case model_context_window(model) do
      nil -> @default_compact_threshold
      context_window -> floor(context_window * @compact_context_ratio)
    end
  end

  defp model_context_window(model) when is_map(model) do
    [
      :context_window,
      "context_window",
      :contextWindow,
      "contextWindow",
      :context_length,
      "context_length",
      :contextLength,
      "contextLength",
      :max_context_tokens,
      "max_context_tokens",
      :maxContextTokens,
      "maxContextTokens",
      :input_token_limit,
      "input_token_limit",
      :inputTokenLimit,
      "inputTokenLimit"
    ]
    |> Enum.find_value(fn key -> positive_integer(Map.get(model, key)) end)
  end

  defp model_context_window(_model), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _ -> nil
    end
  end

  defp positive_integer(_value), do: nil

  defp run_compact(state, opts) do
    {to_summarize, to_keep} = find_compact_boundary(state.messages, 20)

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

        case generate_summary(state, to_summarize) do
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

            new_state = %{state | messages: [summary_msg | to_keep]}
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
                messages: new_state.messages,
                session_context: new_state.session_context,
                system_prompt: new_state.system_prompt,
                tools: Enum.map(new_state.tools, &Sigma.Coding.Tool.ai_definition/1),
                cwd: new_state.cwd,
                model: new_state.model
              )

            new_state = refresh_context_from_assembly(new_state, context, :compaction)

            {new_state,
             {:ok,
              %{
                compaction_id: compaction_id,
                summary_id: summary_msg.id,
                source_leaf_id: source_leaf_id
              }}}

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

  defp hook_ctx(state) do
    %{
      session_id: state.session_id,
      cwd: state.cwd,
      transcript_path: transcript_path(state),
      permission_mode: "default",
      model: state.model && Map.get(state.model, "id", "")
    }
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
    if Sigma.Coding.Hooks.any_for_event?(state.hook_specs, :session_start) do
      ctx = hook_ctx(state)
      event_data = %{source: state.resume_source}

      {outcome, _warnings} =
        Sigma.Coding.Hooks.dispatch(:session_start, state.hook_specs, ctx, event_data)

      case outcome do
        {:context, text} ->
          dev_msg =
            Message.user(
              "hook_ctx_#{System.unique_integer([:positive])}",
              "[Developer context from hook]\n#{text}"
            )

          %{state | messages: [dev_msg | state.messages]}

        _ ->
          state
      end
    else
      state
    end
  end

  defp run_session_end_hook(state, otp_reason) do
    ctx = hook_ctx(state)

    reason =
      case otp_reason do
        :normal -> "user_close"
        :shutdown -> "user_close"
        {:shutdown, _} -> "user_close"
        _ -> "crash"
      end

    event_data = %{reason: reason, last_activity_at: ""}

    try do
      Sigma.Coding.Hooks.dispatch(:session_end, state.hook_specs, ctx, event_data)
    rescue
      e -> Logger.warning("[Sigma.Agent] SessionEnd hook crashed: #{Exception.message(e)}")
    end
  end

  defp run_user_prompt_submit_hook(state, user_msg) do
    if Sigma.Coding.Hooks.any_for_event?(state.hook_specs, :user_prompt_submit) do
      ctx = Map.put(hook_ctx(state), :turn_id, user_msg.id)
      prompt_text = message_text(user_msg)
      event_data = %{prompt: prompt_text}

      {outcome, _warnings} =
        Sigma.Coding.Hooks.dispatch(:user_prompt_submit, state.hook_specs, ctx, event_data)

      case outcome do
        {:block, reason} ->
          {:block, reason}

        {:context, extra} ->
          updated_msg = append_text_to_message(user_msg, extra)
          {:ok, updated_msg, state}

        _ ->
          {:ok, user_msg, state}
      end
    else
      {:ok, user_msg, state}
    end
  end

  defp run_stop_hook(state, assistant_msg, turn_id) do
    if Sigma.Coding.Hooks.any_for_event?(state.hook_specs, :stop) do
      ctx = hook_ctx(state)
      last_text = message_text(assistant_msg)

      event_data = %{
        stop_hook_active: state.stop_hook_active,
        last_assistant_message: last_text
      }

      {outcome, _warnings} =
        Sigma.Coding.Hooks.dispatch(:stop, state.hook_specs, ctx, event_data)

      case outcome do
        {:halt, _} ->
          {state, :completed}

        {:block, reason} when not state.stop_hook_active ->
          # Inject synthetic user turn and continue
          synth_id = "hook_stop_#{System.unique_integer([:positive])}"
          synth_msg = Message.user(synth_id, reason)
          state = %{state | messages: state.messages ++ [synth_msg], stop_hook_active: true}
          emit(state, {:message_start, synth_msg})
          emit(state, {:message_end, synth_msg})
          run_turn_loop(state, turn_id)

        _ ->
          {state, :completed}
      end
    else
      {state, :completed}
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
        context_policy: context_policy(snapshot, state.model, state.provider_options)
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
        context_policy: context_policy(snapshot, state.model, state.provider_options)
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
        context_policy: context_policy(snapshot, state.model, state.provider_options)
    }
  end

  defp context_policy(snapshot, model, options) do
    ContextPolicy.policy(snapshot,
      model: model,
      output_reserve: provider_output_reserve(options),
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
        Enum.each(state.subscribers, fn sub -> send(sub, event) end)
        :ok

      {:error, reason} ->
        throw({:event_persistence_failed, persisted_event_type(event), reason})
    end
  end

  @doc false
  def __backplane_emit__(state, event), do: emit(state, event)

  @doc false
  def __backplane_acknowledge__(state), do: acknowledge_canonical(state)

  @doc false
  def __backplane_phase__(state, phase),
    do: set_turn_phase(state, state.turn_state.turn_id, phase)

  @doc false
  def __backplane_build_context__(state, messages) do
    ContextBuilder.build(
      messages: messages,
      session_context: state.session_context,
      system_prompt: state.system_prompt,
      tools: Enum.map(state.tools, &Sigma.Coding.Tool.ai_definition/1),
      cwd: state.cwd,
      model: state.model
    )
  end

  @doc false
  def __backplane_context_error__(state, context), do: context_budget_error(state, context)

  @doc false
  def __backplane_prompt_hook__(state, message), do: run_user_prompt_submit_hook(state, message)

  @doc false
  def __backplane_stop_hook__(state, _turn_id, messages, stop_hook_active) do
    if Sigma.Coding.Hooks.any_for_event?(state.hook_specs, :stop) do
      assistant = Enum.find(Enum.reverse(messages), &match?(%{role: :assistant}, &1))
      ctx = hook_ctx(state)

      event_data = %{
        stop_hook_active: stop_hook_active,
        last_assistant_message: message_text(assistant)
      }

      {outcome, _warnings} = Sigma.Coding.Hooks.dispatch(:stop, state.hook_specs, ctx, event_data)

      case outcome do
        {:block, reason} when not stop_hook_active ->
          {:continue, Message.user("hook_stop_#{System.unique_integer([:positive])}", reason)}

        _outcome ->
          :stop
      end
    else
      :stop
    end
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
      |> Keyword.put(:tool_state, state.tool_state)
      |> Keyword.put(:on_tool_fact, fn fact -> emit(state, {:metrics, :tool_finished, fact}) end)
      |> Keyword.put(:on_tool_update, fn update ->
        send(owner, {:backplane_tool_update, tool_call, update})
      end)

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

  defp execution_engine(opts) do
    case Keyword.get(
           opts,
           :execution_engine,
           Application.get_env(:sigma_agent, :execution_engine, :backplane)
         ) do
      engine when engine in [:sigma, :backplane] -> {:ok, engine}
      engine -> {:error, {:invalid_execution_engine, engine}}
    end
  end

  defp init_backplane_store(opts) do
    if Keyword.fetch!(opts, :execution_engine) == :sigma do
      {:ok, nil, false}
    else
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
