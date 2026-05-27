defmodule PiAgent do
  @moduledoc """
  A GenServer that manages a single agent session.
  """
  use GenServer

  alias PiAgent.Message
  alias PiAgent.ContextBuilder
  alias PiAgent.SessionContext
  alias PiAi.Providers.Anthropic

  defstruct [
    :session_id,
    :model,
    :system_prompt,
    :session_context,
    :tools,
    :provider,
    :cwd,
    :on_event,
    :dispatcher_opts,
    :provider_options,
    :task_supervisor,
    :current_turn_task,
    :policy,
    messages: [],
    subscribers: [],
    current_turn_assistant_message: nil,
    pending_user_questions: %{},
    hook_specs: [],
    stop_hook_active: false
  ]

  @default_user_question_timeout_ms 300_000

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

  def pending_user_questions(pid) do
    GenServer.call(pid, :pending_user_questions)
  end

  def answer_user_question(pid, question_id, reply) when is_binary(question_id) do
    GenServer.call(pid, {:answer_user_question, question_id, reply})
  end

  def cancel(pid) do
    GenServer.call(pid, :cancel)
  end

  @doc """
  Updates the model used by subsequent turns. Has no effect on the
  currently in-flight turn (the model is captured into the provider
  request at turn start).
  """
  def set_model(pid, model) when is_map(model) do
    GenServer.cast(pid, {:set_model, model})
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
          {:ok, pid} = PiCoding.PermissionPolicy.start_link(default: :allow, rules: %{})
          pid

        provided ->
          provided
      end

    cwd = opts[:cwd] || File.cwd!()
    hook_specs = PiCoding.Hooks.Discovery.load(cwd)

    state = %__MODULE__{
      task_supervisor: task_supervisor,
      policy: policy,
      session_id: opts[:session_id],
      model: opts[:model],
      system_prompt: opts[:system_prompt],
      session_context: opts[:session_context] || SessionContext.new(),
      tools: opts[:tools] || [],
      provider: opts[:provider] || Anthropic,
      messages: opts[:messages] || [],
      cwd: cwd,
      on_event: opts[:on_event],
      dispatcher_opts: opts[:dispatcher_opts] || [],
      provider_options: opts[:options] || [],
      hook_specs: hook_specs
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, subscriber_pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: [subscriber_pid | state.subscribers]}}
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
  def handle_cast({:set_model, model}, state) do
    {:noreply, %{state | model: model}}
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
            {:noreply, state}
        end
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Internal — runs inside the turn Task

  defp execute_turn(state, prompt_text) do
    emit(state, {:agent_start, state.cwd})

    # Reset stop_hook_active at the start of each turn
    state = %{state | stop_hook_active: false}

    # SessionStart hook: may prepend developer context
    state = run_session_start_hook(state)

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

    ai_tools = Enum.map(state.tools, &PiCoding.Tool.ai_definition/1)

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
        Enum.filter(content, fn block -> block.type == :tool_call end)

      _ ->
        []
    end
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
      |> Keyword.put(:transcript_path, transcript_path(state))
      |> Keyword.put(:hook_specs, state.hook_specs)

    results = PiCoding.Dispatcher.dispatch_batch(tool_calls, state.tools, opts)

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

  @compact_threshold 80_000

  defp maybe_compact(state) do
    input_tokens =
      state.messages
      |> Enum.reverse()
      |> Enum.find_value(0, fn msg ->
        if msg.role == :assistant and msg.usage != nil do
          get_in(msg.usage, [:input]) || 0
        end
      end)

    if input_tokens >= @compact_threshold do
      run_compact(state)
    else
      state
    end
  end

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

  defp transcript_path(state) do
    if state.session_id do
      agent_dir =
        Application.get_env(:ex_pi_session, :agent_dir) ||
          Path.join([System.user_home!(), ".pi", "agent"])

      cwd_safe =
        state.cwd
        |> String.replace_leading("/", "")
        |> String.replace(~r|[/:\\]|, "-")

      sessions_dir = Path.join([agent_dir, "sessions", "--#{cwd_safe}--"])
      Path.join(sessions_dir, "#{state.session_id}.jsonl")
    else
      ""
    end
  end

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

  defp run_session_start_hook(state) do
    if PiCoding.Hooks.any_for_event?(state.hook_specs, :session_start) do
      ctx = hook_ctx(state)
      event_data = %{source: :startup}

      {outcome, _warnings} =
        PiCoding.Hooks.dispatch(:session_start, state.hook_specs, ctx, event_data)

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

  defp run_user_prompt_submit_hook(state, user_msg) do
    if PiCoding.Hooks.any_for_event?(state.hook_specs, :user_prompt_submit) do
      ctx = Map.put(hook_ctx(state), :turn_id, user_msg.id)
      prompt_text = message_text(user_msg)
      event_data = %{prompt: prompt_text}

      {outcome, _warnings} =
        PiCoding.Hooks.dispatch(:user_prompt_submit, state.hook_specs, ctx, event_data)

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
    if PiCoding.Hooks.any_for_event?(state.hook_specs, :stop) do
      ctx = hook_ctx(state)
      last_text = message_text(assistant_msg)

      event_data = %{
        stop_hook_active: state.stop_hook_active,
        last_assistant_message: last_text
      }

      {outcome, _warnings} =
        PiCoding.Hooks.dispatch(:stop, state.hook_specs, ctx, event_data)

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
    extra_block = %{type: :text, text: "\n\n[Additional context from hook]\n#{extra}"}
    %{msg | content: content ++ [extra_block]}
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
