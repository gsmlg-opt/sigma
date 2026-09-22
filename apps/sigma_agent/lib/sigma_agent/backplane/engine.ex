defmodule Sigma.Agent.Backplane.Engine do
  @moduledoc false

  alias Backplane.AgentRuntime.{Conversation, Error, InputSchema, ToolRegistry}
  alias Sigma.Agent.Message
  alias Sigma.Coding.Tool

  @poll_interval 10

  def run(state, turn_id) do
    with {:ok, registry} <- registry(state, turn_id),
         {:ok, conversation} <- start_conversation(state, turn_id, registry) do
      try do
        case Conversation.prompt(conversation, List.last(state.messages).content) do
          {:ok, admission} ->
            initial = List.last(state.messages)

            loop(
              state,
              conversation,
              turn_id,
              %{admission.message_id => initial},
              MapSet.new(),
              nil
            )

          {:error, error} ->
            Sigma.Agent.__backplane_emit__(state, {:turn_error, normalize_error(error)})
            {state, :failed}
        end
      after
        if Process.alive?(conversation), do: GenServer.stop(conversation, :normal)
      end
    else
      {:error, error} ->
        Sigma.Agent.__backplane_emit__(state, {:turn_error, normalize_error(error)})
        {state, :failed}
    end
  end

  defp start_conversation(state, turn_id, registry) do
    initial_prompt = :atomics.new(1, signed: false)
    stop_hook_active = :atomics.new(1, signed: false)
    initial_message = List.last(state.messages)

    host = %{
      model: state.model,
      provider: state.provider,
      provider_options: state.provider_options,
      session_id: state.session_id,
      log_session_id: state.log_session_id,
      initial_prompt: initial_prompt,
      stop_hook_active: stop_hook_active,
      initial_message: initial_message,
      build_context: &Sigma.Agent.__backplane_build_context__(state, &1),
      context_error: &Sigma.Agent.__backplane_context_error__(state, &1),
      stop_hook: &Sigma.Agent.__backplane_stop_hook__(state, turn_id, &1, &2)
    }

    Conversation.start_link(
      run_id: turn_id,
      store: Sigma.Agent.Backplane.Store,
      context: state.backplane_store,
      provider: Sigma.Agent.Backplane.Provider,
      provider_context: %{host: host, owner: self()},
      hooks: Sigma.Agent.Backplane.Hooks,
      registry: registry,
      subscriber: self(),
      messages: Enum.drop(state.messages, -1),
      authority: %{
        caller: state.session_id || "sigma",
        run_id: turn_id,
        grants: Enum.map(state.tools, &Tool.name/1),
        tool_revision: 1
      },
      work: 100,
      run_timeout: 300_000,
      effect_timeout: 300_000
    )
  end

  defp registry(state, turn_id) do
    owner = self()

    Enum.reduce_while(state.tools, {:ok, %ToolRegistry{}}, fn tool, {:ok, registry} ->
      schema = Tool.schema(tool)

      # TODO(upstream): gsmlg-opt/backplane#36
      case InputSchema.validate(schema, %{}) do
        {:error, %Error{class: :unsupported_capability} = error} ->
          {:halt, {:error, error}}

        _valid_schema_or_value_error ->
          metadata =
            Tool.metadata(tool, %{arguments: %{}, id: "schema", name: Tool.name(tool)}, [])

          descriptor = %{
            tool_name: Tool.name(tool),
            tool_revision: 1,
            backend: Sigma.Agent.Backplane.ToolBackend,
            backend_context: %{
              execute: fn operation ->
                ref = make_ref()
                send(owner, {:backplane_tool_context, self(), ref})

                current =
                  receive do
                    {:backplane_tool_context, ^ref, current} -> current
                  end

                result =
                  Sigma.Agent.__backplane_dispatch_tool__(current, turn_id, operation, owner)

                send(owner, {:backplane_tool_boundary, self(), ref})

                receive do
                  {:backplane_tool_continue, ^ref} -> result
                end
              end
            },
            schema: schema,
            safety: %{
              read_only: metadata.effect == :read,
              retry_safe: metadata.effect == :read,
              parallel_safe: metadata.concurrency == :shared,
              requires_approval: false
            }
          }

          case ToolRegistry.register(registry, descriptor) do
            {:ok, registry} -> {:cont, {:ok, registry}}
            {:error, error} -> {:halt, {:error, error}}
          end
      end
    end)
  end

  defp loop(state, conversation, turn_id, users, forwarded, assistant) do
    Sigma.Agent.__backplane_acknowledge__(state)

    receive do
      {:agent_runtime, ^turn_id, event} ->
        {state, users, assistant, terminal} = reduce_event(state, event, users, assistant)

        case terminal do
          nil -> loop(state, conversation, turn_id, users, forwarded, assistant)
          outcome -> finish(state, conversation, outcome)
        end

      {:backplane_request_started, request, context} ->
        state = Sigma.Agent.__backplane_request_started__(state, request, context)
        loop(state, conversation, turn_id, users, forwarded, assistant)

      {:backplane_tool_context, worker, ref} ->
        send(worker, {:backplane_tool_context, ref, state})
        loop(state, conversation, turn_id, users, forwarded, assistant)

      {:backplane_tool_boundary, worker, ref} ->
        {state, users, forwarded} =
          forward_steering(state, conversation, turn_id, users, forwarded)

        send(worker, {:backplane_tool_continue, ref})
        loop(state, conversation, turn_id, users, forwarded, assistant)

      {:backplane_provider_boundary, worker, ref, request} ->
        {state, users, forwarded} =
          forward_steering(state, conversation, turn_id, users, forwarded)

        state = Sigma.Agent.__backplane_request_finished__(state, request)
        send(worker, {:backplane_provider_continue, ref})
        loop(state, conversation, turn_id, users, forwarded, assistant)

      {:backplane_request_progress, request} ->
        loop(
          %{state | backplane_request: request},
          conversation,
          turn_id,
          users,
          forwarded,
          assistant
        )

      {:backplane_request_finished, request} ->
        state = Sigma.Agent.__backplane_request_finished__(state, request)
        loop(state, conversation, turn_id, users, forwarded, assistant)

      {:backplane_synthetic_user, message} ->
        Sigma.Agent.__backplane_emit__(state, {:message_start, message})
        Sigma.Agent.__backplane_emit__(state, {:message_end, message})

        loop(
          %{state | messages: state.messages ++ [message]},
          conversation,
          turn_id,
          users,
          forwarded,
          assistant
        )

      {:backplane_tool_update, tool_call, update} ->
        Sigma.Agent.__backplane_emit__(
          state,
          {:tool_execution_update, tool_call.id, tool_call.name, tool_call.arguments, update}
        )

        loop(state, conversation, turn_id, users, forwarded, assistant)

      {:cancel, _ref} ->
        _ = Conversation.cancel(conversation)
        loop(state, conversation, turn_id, users, forwarded, assistant)

      {:abort, _ref} ->
        loop(state, conversation, turn_id, users, forwarded, assistant)
    after
      @poll_interval ->
        {state, users, forwarded} =
          forward_steering(state, conversation, turn_id, users, forwarded)

        loop(state, conversation, turn_id, users, forwarded, assistant)
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

      _none_or_forwarded ->
        {state, users, forwarded}
    end
  end

  defp forward_steering_item(state, conversation, turn_id, item, users, forwarded) do
    message = Message.user(item.message_id, item.content)

    case Sigma.Agent.__backplane_prompt_hook__(state, message) do
      {:block, reason} ->
        Sigma.Agent.__backplane_emit__(state, {:prompt_rejected, item.message_id, reason})

        :ok =
          GenServer.call(state.control_pid, {:ack_steering, turn_id, item.message_id}, :infinity)

        {state, users, MapSet.put(forwarded, item.message_id)}

      {:ok, message, state} ->
        case Conversation.steer(conversation, message.content) do
          {:ok, %{message_id: runtime_id}} ->
            {state, Map.put(users, runtime_id, message), MapSet.put(forwarded, item.message_id)}

          {:error, _error} ->
            {state, users, forwarded}
        end
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

    state = %{state | messages: state.messages ++ [message], backplane_tool_results: []}
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

  defp reduce_event(state, %{type: :tool_completed, message: message}, users, assistant) do
    tool = tool_message(message, state.turn_state.turn_id)
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

    state = %{state | messages: state.messages ++ [tool], backplane_tool_results: results}
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

    :ok =
      GenServer.call(
        state.control_pid,
        {:ack_steering, state.turn_state.turn_id, canonical.id},
        :infinity
      )

    Sigma.Agent.__backplane_emit__(
      state,
      {:prompt_consumed, :steering,
       %{message_id: canonical.id, turn_id: state.turn_state.turn_id}}
    )

    {%{state | messages: state.messages ++ [canonical]}, users, assistant, nil}
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
    _ = conversation

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
    result = Map.get(message, :result, %{})

    Message.tool_result("msg_tool_res_#{turn_id}_#{message.tool_call_id}", %{
      tool_call_id: message.tool_call_id,
      tool_name: message.name,
      content: result_content(result),
      is_error: Map.get(result, :is_error, false),
      timestamp: System.system_time(:millisecond)
    })
  end

  defp to_user_message(message), do: Message.user(message.id, message.content)

  defp result_content(%{content: content}) when is_list(content), do: content

  defp result_content(%{content: content}) when is_binary(content),
    do: [%{type: :text, text: content}]

  defp result_content(%{error: error}), do: [%{type: :text, text: "Error: #{inspect(error)}"}]
  defp result_content(_), do: [%{type: :text, text: "Error: malformed tool result"}]

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
  defp normalize_error(error), do: Sigma.Ai.ProviderError.from_exception(error)
end
