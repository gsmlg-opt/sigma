defmodule ExPiAgent do
  @moduledoc """
  A GenServer that manages a single agent session.
  """
  use GenServer

  alias ExPiAgent.Message
  alias ExPiAgent.MessageTransformer
  alias ExPiAi.Providers.Anthropic

  defstruct [
    :model,
    :system_prompt,
    :tools,
    :provider,
    :cwd,
    :on_event,
    :dispatcher_opts,
    :provider_options,
    messages: [],
    subscribers: [],
    current_turn_assistant_message: nil
  ]

  # Client API

  @doc """
  Starts a new agent session.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Subscribes a process to receive `ExPiAgent.Event` events.
  """
  def subscribe(pid) do
    GenServer.call(pid, {:subscribe, self()})
  end

  @doc """
  Starts a new turn with the given prompt.
  """
  def prompt(pid, prompt_text) do
    GenServer.cast(pid, {:prompt, prompt_text})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    state = %__MODULE__{
      model: opts[:model],
      system_prompt: opts[:system_prompt],
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
  def handle_cast({:prompt, prompt_text}, state) do
    state = execute_turn(state, prompt_text)
    {:noreply, state}
  end

  # Internal Functions

  defp execute_turn(state, prompt_text) do
    emit(state, {:agent_start})

    # 1. Create user message
    user_id = "msg_user_#{System.unique_integer([:positive])}"
    user_msg = Message.user(user_id, prompt_text)

    state = %{state | messages: state.messages ++ [user_msg]}
    emit(state, {:message_start, user_msg})
    emit(state, {:message_end, user_msg})

    # Enter turn loop
    state = run_turn_loop(state)

    emit(state, {:agent_end, state.messages})

    state
  end

  defp run_turn_loop(state) do
    emit(state, {:turn_start})

    # 1. Prepare context
    llm_messages =
      state.messages
      |> MessageTransformer.transform_context()
      |> MessageTransformer.convert_to_llm()

    # Convert tools to Ai format for the provider
    ai_tools =
      Enum.map(state.tools, fn tool_mod ->
        %{
          name: tool_mod.name(),
          description: tool_mod.description(),
          parameters: tool_mod.schema()
        }
      end)

    params = %{
      model: state.model,
      context: %{
        messages: llm_messages,
        system_prompt: state.system_prompt,
        tools: ai_tools
      },
      options: state.provider_options
    }

    # 2. Stream from provider
    {state, assistant_msg} = run_stream(state, params)

    # 3. Extract tool calls
    tool_calls = extract_tool_calls(assistant_msg)

    if tool_calls != [] do
      # 4. Execute tools
      {state, tool_result_messages} = execute_tools(state, tool_calls)

      emit(state, {:turn_end, assistant_msg, tool_result_messages})

      # 5. Automatically continue the loop
      run_turn_loop(state)
    else
      emit(state, {:turn_end, assistant_msg, []})
      state
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

            # We don't execute here anymore, we do it after the stream is done
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
  end

  defp extract_tool_calls(msg) do
    case msg.content do
      content when is_list(content) ->
        Enum.filter(content, fn block -> block.type == :tool_call end)

      _ ->
        []
    end
  end

  defp execute_tools(state, tool_calls) do
    # Emit start for each tool call
    Enum.each(tool_calls, fn tc ->
      emit(state, {:tool_execution_start, tc.id, tc.name, tc.arguments})
    end)

    # Call Dispatcher
    opts = Keyword.merge(state.dispatcher_opts, cwd: state.cwd)
    results = ExPiCoding.Dispatcher.dispatch_batch(tool_calls, state.tools, opts)

    # Create result messages and emit end for each
    tool_result_messages =
      Enum.map(results, fn {tool_call, result} ->
        msg_id = "msg_tool_res_#{System.unique_integer([:positive])}"

        {content, is_error} =
          case result do
            {:ok, %{content: content}} -> {content, false}
            {:error, reason} -> {[%{type: :text, text: "Error: #{inspect(reason)}"}], true}
            # handle other potential result formats from Dispatcher
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

    # Update state messages
    new_state = %{state | messages: state.messages ++ tool_result_messages}

    {new_state, tool_result_messages}
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

  defp emit(state, event) do
    Enum.each(state.subscribers, fn sub -> send(sub, event) end)
    if state.on_event, do: state.on_event.(event)
  end
end
