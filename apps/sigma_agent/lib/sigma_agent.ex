defmodule Sigma.Agent do
  @moduledoc """
  A GenServer that manages a single agent session.
  """
  use GenServer

  require Logger

  alias Sigma.Agent.Message
  alias Sigma.Agent.ContextBuilder
  alias Sigma.Agent.SessionContext
  alias Sigma.Ai.Providers.Anthropic

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
    :dispatcher_opts,
    :tool_state,
    :provider_options,
    :task_supervisor,
    :current_turn_task,
    :policy,
    messages: [],
    subscribers: [],
    current_turn_assistant_message: nil,
    pending_user_questions: %{},
    pending_mcp_elicitations: %{},
    hook_specs: [],
    stop_hook_active: false,
    resume_source: :startup,
    mcp_session: %{handles: [], subscriptions: [], clients: %{}}
  ]

  @default_user_question_timeout_ms 300_000
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

  def prompt(pid, prompt_text, opts \\ []) do
    GenServer.cast(pid, {:prompt, prompt_text, opts})
  end

  def ask_user_question(pid, request, opts \\ []) when is_map(request) do
    question_id = "ask_#{System.unique_integer([:positive])}"

    timeout =
      request[:timeout_ms] || Keyword.get(opts, :timeout, @default_user_question_timeout_ms)

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
    hook_specs = Sigma.Coding.Hooks.Discovery.load(cwd)

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
      hook_specs: hook_specs,
      resume_source: Keyword.get(opts, :resume_source, :startup)
    }

    {:ok, state, {:continue, :session_start}}
  end

  @impl true
  def handle_continue(:session_start, state) do
    {:noreply, state |> start_mcp_clients() |> run_session_start_hook()}
  end

  @impl true
  def terminate(reason, state) do
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

    :ok
  end

  @impl true
  def handle_call({:subscribe, subscriber_pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: [subscriber_pid | state.subscribers]}}
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
    case state.current_turn_task do
      nil ->
        {:reply, :ok, state}

      task ->
        Task.shutdown(task, :brutal_kill)
        emit(state, {:turn_cancelled})
        {:reply, :ok, %{state | current_turn_task: nil}}
    end
  end

  @impl true
  def handle_call(:get_policy, _from, state) do
    {:reply, state.policy, state}
  end

  @impl true
  def handle_call({:change_provider, provider, model, options, persist}, _from, state) do
    case run_state_change(persist) do
      :ok ->
        {:reply, :ok, %{state | provider: provider, model: model, provider_options: options}}

      {:ok, _result} = success ->
        {:reply, success, %{state | provider: provider, model: model, provider_options: options}}

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
    {:noreply, %{state | model: model}}
  end

  @impl true
  def handle_cast({:set_provider, provider, model, options}, state) do
    {:noreply, %{state | provider: provider, model: model, provider_options: options}}
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
  def handle_cast({:prompt, prompt_text}, state) do
    handle_cast({:prompt, prompt_text, []}, state)
  end

  @impl true
  def handle_cast({:prompt, _, _opts}, %{current_turn_task: task} = state) when task != nil do
    # Turn in flight — ignore until it completes or is cancelled
    {:noreply, state}
  end

  @impl true
  def handle_cast({:prompt, prompt_text, opts}, state) do
    turn_dispatcher_opts = Keyword.get(opts, :dispatcher_opts, [])

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        # self() here is the turn task PID; pass it as the abort signal so
        # bash tools can monitor for cancellation via Process.monitor/1
        dispatcher_opts =
          state.dispatcher_opts
          |> Keyword.merge(turn_dispatcher_opts)
          |> Keyword.put(:signal, self())

        execute_turn(%{state | dispatcher_opts: dispatcher_opts}, prompt_text)
      end)

    {:noreply, %{state | current_turn_task: task}}
  end

  @impl true
  def handle_info({ref, new_messages}, state) when is_reference(ref) do
    case state.current_turn_task do
      %Task{ref: ^ref} ->
        Process.demonitor(ref, [:flush])
        new_state = %{state | messages: new_messages, current_turn_task: nil}
        emit(new_state, {:agent_end, new_messages})
        {:noreply, new_state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case state.current_turn_task do
      %Task{ref: ^ref} ->
        if reason not in [:normal, :shutdown, :killed] do
          emit(state, {:turn_error, reason})
        end

        {:noreply, %{state | current_turn_task: nil}}

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

  def handle_info(_msg, state), do: {:noreply, state}

  # Internal — runs inside the turn Task

  defp execute_turn(state, prompt_text) do
    emit(state, {:agent_start, state.cwd})

    # Reset stop_hook_active at the start of each turn
    state = %{state | stop_hook_active: false}

    user_id = "msg_user_#{System.unique_integer([:positive])}"
    user_msg = Message.user(user_id, prompt_text)

    # UserPromptSubmit hook: may block or inject context into the prompt
    case run_user_prompt_submit_hook(state, user_msg) do
      {:block, reason} ->
        emit(state, {:turn_blocked, reason})
        state.messages

      {:ok, user_msg, state} ->
        state = %{state | messages: state.messages ++ [user_msg]}
        emit(state, {:message_start, user_msg})
        emit(state, {:message_end, user_msg})

        state = run_turn_loop(state)
        state = maybe_compact(state)

        # Return the messages list; the agent emits {:agent_end} in handle_info
        # after updating its own state to avoid a race between the event and the
        # state update.
        state.messages
    end
  end

  defp run_turn_loop(state) do
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

    params = %{
      model: state.model,
      session_id: state.session_id,
      log_session_id: state.log_session_id,
      context: context,
      options: state.provider_options
    }

    case run_stream(state, params) do
      {:error, state} ->
        state

      {state, assistant_msg} ->
        tool_calls = extract_tool_calls(assistant_msg)

        if tool_calls != [] do
          {state, tool_result_messages} = execute_tools(state, tool_calls)
          emit(state, {:turn_end, assistant_msg, tool_result_messages})
          run_turn_loop(state)
        else
          emit(state, {:turn_end, assistant_msg, []})
          run_stop_hook(state, assistant_msg)
        end
    end
  end

  defp run_stream(state, params) do
    provider = state.provider
    stream = provider.stream(params)

    assistant_id = "msg_assistant_#{System.unique_integer([:positive])}"

    final_state =
      Enum.reduce(stream, state, fn event, acc_state ->
        case event do
          {:start, ai_msg} ->
            agent_msg = ai_to_agent_message(ai_msg, assistant_id)
            emit(acc_state, {:message_start, agent_msg})
            %{acc_state | current_turn_assistant_message: agent_msg}

          {:text_delta, _idx, _text, ai_msg} ->
            agent_msg = ai_to_agent_message(ai_msg, assistant_id)
            emit(acc_state, {:message_update, agent_msg, event})
            %{acc_state | current_turn_assistant_message: agent_msg}

          {:thinking_delta, _idx, _thinking, ai_msg} ->
            agent_msg = ai_to_agent_message(ai_msg, assistant_id)
            emit(acc_state, {:message_update, agent_msg, event})
            %{acc_state | current_turn_assistant_message: agent_msg}

          {:toolcall_start, _idx, ai_msg} ->
            agent_msg = ai_to_agent_message(ai_msg, assistant_id)
            emit(acc_state, {:message_update, agent_msg, event})
            %{acc_state | current_turn_assistant_message: agent_msg}

          {:toolcall_delta, _idx, _delta, ai_msg} ->
            agent_msg = ai_to_agent_message(ai_msg, assistant_id)
            emit(acc_state, {:message_update, agent_msg, event})
            %{acc_state | current_turn_assistant_message: agent_msg}

          {:toolcall_end, _idx, _tool_call, ai_msg} ->
            agent_msg = ai_to_agent_message(ai_msg, assistant_id)
            emit(acc_state, {:message_update, agent_msg, event})
            %{acc_state | current_turn_assistant_message: agent_msg}

          {:done, _stop_reason, ai_msg} ->
            agent_msg = ai_to_agent_message(ai_msg, assistant_id)
            emit(acc_state, {:message_end, agent_msg})

            %{
              acc_state
              | messages: acc_state.messages ++ [agent_msg],
                current_turn_assistant_message: agent_msg
            }

          _ ->
            acc_state
        end
      end)

    assistant_msg = final_state.current_turn_assistant_message

    if assistant_msg do
      {%{final_state | current_turn_assistant_message: nil}, assistant_msg}
    else
      emit(state, {:turn_error, "AI provider returned no response."})
      {:error, state}
    end
  rescue
    e in [RuntimeError, Jason.DecodeError] ->
      emit(state, {:turn_error, Exception.message(e)})
      {:error, state}
  end

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

  defp execute_tools(state, tool_calls) do
    Enum.each(tool_calls, fn tc ->
      emit(state, {:tool_execution_start, tc.id, tc.name, tc.arguments})
    end)

    opts =
      state.dispatcher_opts
      |> Keyword.put(:cwd, state.cwd)
      |> Keyword.put(:permission_policy, resolve_policy(state.policy))
      |> Keyword.put(:session_id, state.session_id)
      |> Keyword.put(:log_session_id, state.log_session_id)
      |> Keyword.put(:transcript_path, transcript_path(state))
      |> Keyword.put(:hook_specs, state.hook_specs)
      |> Keyword.put(:tool_state, state.tool_state)

    results = Sigma.Coding.Dispatcher.dispatch_batch(tool_calls, state.tools, opts)

    tool_result_messages =
      Enum.map(results, fn {tool_call, result} ->
        msg_id = "msg_tool_res_#{System.unique_integer([:positive])}"

        {content, is_error} =
          case result do
            {:ok, %{content: content} = result} -> {content, Map.get(result, :is_error, false)}
            {:error, reason} -> {[%{type: :text, text: "Error: #{inspect(reason)}"}], true}
            other -> {[%{type: :text, text: inspect(other)}], false}
          end

        tool_res_msg =
          Message.tool_result(msg_id, %{
            tool_call_id: tool_call.id,
            tool_name: tool_call.name,
            content: content,
            is_error: is_error,
            timestamp: DateTime.to_unix(DateTime.utc_now(), :millisecond)
          })

        emit(state, {:tool_execution_end, tool_call.id, tool_call.name, content, is_error})
        emit(state, {:message_start, tool_res_msg})
        emit(state, {:message_end, tool_res_msg})

        tool_res_msg
      end)

    {%{state | messages: state.messages ++ tool_result_messages}, tool_result_messages}
  end

  defp ai_to_agent_message(ai_msg, id) do
    Message.assistant(id, %{
      content: ai_msg.content,
      model: ai_msg.model,
      provider: ai_msg.provider,
      usage: ai_msg.usage,
      stop_reason: ai_msg.stop_reason,
      timestamp: ai_msg.timestamp,
      response_id: Map.get(ai_msg, :response_id)
    })
  end

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
      run_compact(state)
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

  defp run_compact(state) do
    {to_summarize, to_keep} = find_compact_boundary(state.messages, 20)

    case to_summarize do
      [] ->
        state

      _ ->
        case generate_summary(state, to_summarize) do
          {:ok, summary_text} ->
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
            new_state

          {:error, _} ->
            state
        end
    end
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
      context: %{
        messages: [%{role: :user, content: [%{type: :text, text: prompt}]}],
        system_prompt: nil,
        tools: []
      },
      options: state.provider_options
    }

    try do
      text =
        state.provider.stream(params)
        |> Enum.reduce("", fn
          {:done, _stop, ai_msg}, _ ->
            case ai_msg.content do
              blocks when is_list(blocks) ->
                Enum.map_join(blocks, "", fn
                  %{type: :text, text: t} -> t
                  _ -> ""
                end)

              s when is_binary(s) ->
                s

              _ ->
                ""
            end

          _, acc ->
            acc
        end)

      {:ok, text}
    rescue
      _ -> {:error, "summary generation failed"}
    end
  end

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

    stream_params = %{
      model: model,
      system: Map.get(params, "systemPrompt") || Map.get(params, "system_prompt"),
      messages: [%{role: :user, content: prompt}],
      tools: [],
      max_tokens: max_tokens,
      options: state.provider_options
    }

    try do
      events = state.provider.stream(stream_params)

      case Enum.find(events, &match?({:done, _, _}, &1)) do
        {:done, stop_reason, ai_msg} ->
          text = message_text(ai_msg)

          {:ok,
           %{
             "role" => "assistant",
             "content" => %{"type" => "text", "text" => text},
             "model" => to_string(model_id),
             "stopReason" => sampling_stop_reason(stop_reason)
           }}

        nil ->
          {:error, "MCP sampling produced no completion"}
      end
    rescue
      error -> {:error, Exception.message(error)}
    catch
      :exit, reason -> {:error, inspect(reason)}
    end
  end

  defp run_mcp_sampling(_state, _params), do: {:error, "Invalid sampling params"}

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

  defp run_stop_hook(state, assistant_msg) do
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
          state

        {:block, reason} when not state.stop_hook_active ->
          # Inject synthetic user turn and continue
          synth_id = "hook_stop_#{System.unique_integer([:positive])}"
          synth_msg = Message.user(synth_id, reason)
          state = %{state | messages: state.messages ++ [synth_msg], stop_hook_active: true}
          emit(state, {:message_start, synth_msg})
          emit(state, {:message_end, synth_msg})
          run_turn_loop(state)

        _ ->
          state
      end
    else
      state
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

  defp emit(state, event) do
    Enum.each(state.subscribers, fn sub -> send(sub, event) end)
    if state.on_event, do: state.on_event.(event)
  end

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
