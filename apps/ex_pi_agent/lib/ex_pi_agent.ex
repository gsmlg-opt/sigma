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
    current_turn_assistant_message: nil
  ]

  # Client API

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def subscribe(pid) do
    GenServer.call(pid, {:subscribe, self()})
  end

  def prompt(pid, prompt_text) do
    GenServer.cast(pid, {:prompt, prompt_text})
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
    {:ok, task_sup} = Task.Supervisor.start_link()

    {:ok, policy} = PiCoding.PermissionPolicy.start_link(default: :allow, rules: %{})

    state = %__MODULE__{
      task_supervisor: task_sup,
      policy: policy,
      session_id: opts[:session_id],
      model: opts[:model],
      system_prompt: opts[:system_prompt],
      session_context: opts[:session_context] || SessionContext.new(),
      tools: opts[:tools] || [],
      provider: opts[:provider] || Anthropic,
      messages: opts[:messages] || [],
      cwd: opts[:cwd] || File.cwd!(),
      on_event: opts[:on_event],
      dispatcher_opts: opts[:dispatcher_opts] || [],
      provider_options: opts[:options] || []
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
  def handle_cast({:set_model, model}, state) do
    {:noreply, %{state | model: model}}
  end

  @impl true
  def handle_cast({:prompt, _}, %{current_turn_task: task} = state) when task != nil do
    # Turn in flight — ignore until it completes or is cancelled
    {:noreply, state}
  end

  @impl true
  def handle_cast({:prompt, prompt_text}, state) do
    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        # self() here is the turn task PID; pass it as the abort signal so
        # bash tools can monitor for cancellation via Process.monitor/1
        dispatcher_opts = Keyword.put(state.dispatcher_opts, :signal, self())
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
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Internal — runs inside the turn Task

  defp execute_turn(state, prompt_text) do
    emit(state, {:agent_start, state.cwd})

    user_id = "msg_user_#{System.unique_integer([:positive])}"
    user_msg = Message.user(user_id, prompt_text)

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

  defp run_turn_loop(state) do
    emit(state, {:turn_start})

    ai_tools =
      Enum.map(state.tools, fn tool_mod ->
        %{
          name: tool_mod.name(),
          description: tool_mod.description(),
          parameters: tool_mod.schema()
        }
      end)

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
          state
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
    {%{final_state | current_turn_assistant_message: nil}, assistant_msg}
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
      |> Keyword.put(:permission_policy, state.policy)
      |> Keyword.put(:session_id, state.session_id)

    results = PiCoding.Dispatcher.dispatch_batch(tool_calls, state.tools, opts)

    tool_result_messages =
      Enum.map(results, fn {tool_call, result} ->
        msg_id = "msg_tool_res_#{System.unique_integer([:positive])}"

        {content, is_error} =
          case result do
            {:ok, %{content: content}} -> {content, false}
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

  defp emit(state, event) do
    Enum.each(state.subscribers, fn sub -> send(sub, event) end)
    if state.on_event, do: state.on_event.(event)
  end
end
