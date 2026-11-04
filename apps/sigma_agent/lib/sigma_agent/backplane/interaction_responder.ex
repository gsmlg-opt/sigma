defmodule Sigma.Agent.Backplane.InteractionResponder do
  @moduledoc """
  Owns permission and user-input waits for one explicit native Conversation.

  Start with trusted `:run_id`, `:incarnation`, `:owner_pid`, `:subscriber` and
  at least one of `:permission_request_fn` (arity 1), `:user_input_request_fn`
  or `:runtime_permission_request_fn` (both arity 2). Use this process as the
  Conversation's subscriber, then
  `attach/2` before prompting. Runtime events are forwarded to the subscriber.
  The resolver and public `Conversation.resolve/3` run in an owned worker, keeping
  the responder and host event loop responsive during human approval.

  Only current, checkpointed requests with a configured handler are handled.
  `:sigma_tool_permission` remains separate from Runtime's built-in `:permission`.
  Callbacks stay in host memory
  and never enter Runtime's persisted request. User-input handlers receive the
  request and a zero-arity checkpoint guard, and return the exact Codex answer
  map. Invalid replies, cancellation and handler loss cancel the current run
  through the public API; error tuples are never resolved as successful answers.
  Cancellation, terminal events, Conversation/owner death and responder shutdown
  stop the worker; Sigma's existing waiter monitor removes any pending question.
  Normal responder shutdown and owner loss also request public cancellation of
  the attached current unfinished run. Acknowledgement fences further callbacks;
  resource cleanup and its durable terminal checkpoint complete asynchronously.
  Abrupt responder kills require the embedding host's supervision policy.
  The trusted Runtime permission handler receives `(request, current?)` and must
  return `:approved`, `:denied` or `{:error, reason}`. Runtime builds its own
  approval identity and final-input digest after approval. Resolver identity
  fields supplied by a client are never accepted as authentication. The embedding
  host must authenticate its responder before installing this callback; a public
  checkpoint guard only verifies freshness. Unconfigured built-in permissions are
  forwarded without invoking Sigma's policy resolver. No production tools are
  enabled by this adapter.
  """

  use GenServer

  require Logger

  alias Backplane.AgentRuntime.Conversation

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Binds once to an idle Conversation with the configured run identity."
  def attach(pid, conversation), do: GenServer.call(pid, {:attach, conversation})

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner_pid)
    permission = Keyword.get(opts, :permission_request_fn)
    user_input = Keyword.get(opts, :user_input_request_fn)
    runtime_permission = Keyword.get(opts, :runtime_permission_request_fn)

    if is_pid(owner) and
         (is_function(permission, 1) or is_function(user_input, 2) or
            is_function(runtime_permission, 2)) do
      {:ok,
       %{
         run_id: Keyword.fetch!(opts, :run_id),
         incarnation: Keyword.fetch!(opts, :incarnation),
         owner_monitor: Process.monitor(owner),
         subscriber: Keyword.fetch!(opts, :subscriber),
         permission_resolver: permission,
         user_input_resolver: user_input,
         runtime_permission_resolver: runtime_permission,
         conversation: nil,
         conversation_monitor: nil,
         pending: nil,
         terminal: false
       }}
    else
      {:stop, :invalid_permission_responder_options}
    end
  end

  @impl true
  def handle_call({:attach, conversation}, _from, %{conversation: nil} = state)
      when is_pid(conversation) do
    case Conversation.status(conversation) do
      %{phase: :idle, run: %{run_id: id, incarnation: incarnation}}
      when id === state.run_id and incarnation === state.incarnation ->
        {:reply, :ok,
         %{
           state
           | conversation: conversation,
             conversation_monitor: Process.monitor(conversation)
         }}

      _ ->
        {:reply, {:error, :invalid_conversation}, state}
    end
  catch
    :exit, _ -> {:reply, {:error, :invalid_conversation}, state}
  end

  def handle_call({:attach, _conversation}, _from, state),
    do: {:reply, {:error, :already_attached}, state}

  @impl true
  def handle_info(
        {:agent_runtime, id, %{run_id: id, incarnation: incarnation} = event} = message,
        %{run_id: id, incarnation: incarnation, conversation: conversation} = state
      )
      when is_pid(conversation) do
    if current_event?(conversation, event) do
      state = handle_event(event, state)
      send(state.subscriber, message)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_monitor: ref} = state),
    do: {:stop, :normal, stop_worker(state)}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{conversation_monitor: ref} = state),
    do: {:stop, :normal, stop_worker(state)}

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{pending: %{monitor: ref} = pending} = state
      ) do
    state = %{state | pending: nil}

    # Even a normal self-exit can leave the human interaction unresolved.
    if current_request?(state.conversation, pending.event) do
      case pending.event.request.kind do
        :sigma_tool_permission ->
          {:noreply,
           start_worker(state, pending.event, fn _ -> {:deny, :permission_resolver_failed} end)}

        kind when kind in [:request_user_input, :permission] ->
          cancel_request(state.conversation, pending.event)
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_worker(state)
    cancel_current(state)
    :ok
  end

  defp handle_event(%{type: type}, state)
       when type in [:run_completed, :run_failed, :run_cancelled, :storage_failed],
       do: %{stop_worker(state) | terminal: true}

  defp handle_event(
         %{type: :interaction_requested, request: %{kind: :permission}} = event,
         %{pending: nil, terminal: false, runtime_permission_resolver: resolver} = state
       )
       when is_function(resolver, 2),
       do: start_worker(state, event, resolver)

  defp handle_event(
         %{type: :interaction_resolved, interaction_id: id},
         %{pending: %{event: %{interaction_id: id}}} = state
       ),
       do: stop_worker(state)

  defp handle_event(
         %{type: :interaction_requested, request: %{kind: :sigma_tool_permission}} = event,
         %{pending: nil, terminal: false, permission_resolver: resolver} = state
       )
       when is_function(resolver, 1),
       do: start_worker(state, event, resolver)

  defp handle_event(
         %{type: :interaction_requested, request: %{kind: :request_user_input}} = event,
         %{pending: nil, terminal: false, user_input_resolver: resolver} = state
       )
       when is_function(resolver, 2),
       do: start_worker(state, event, resolver)

  defp handle_event(_event, state), do: state

  defp current_event?(
         conversation,
         %{
           type: :interaction_requested,
           interaction_id: id,
           request:
             %{
               kind: :sigma_tool_permission,
               tool_call: %{id: call_id, name: name, arguments: input}
             } = request
         } = event
       )
       when is_binary(id) and is_binary(call_id) and call_id != "" and is_binary(name) and
              name != "" and (is_map(input) or is_binary(input)),
       do: match?({:ok, _}, Jason.encode(request)) and current_request?(conversation, event)

  defp current_event?(
         conversation,
         %{
           type: :interaction_requested,
           interaction_id: id,
           request: %{kind: :request_user_input} = request
         } = event
       )
       when is_binary(id) and id != "" do
    match?({:ok, _}, Jason.encode(request)) and current_request?(conversation, event)
  end

  # Runtime's independent approval is never passed to Sigma's policy resolver.
  defp current_event?(
         conversation,
         %{
           type: :interaction_requested,
           interaction_id: id,
           request: %{kind: :permission, operation: operation}
         } = event
       )
       when is_binary(id) and is_map(operation),
       do: current_request?(conversation, event)

  defp current_event?(conversation, %{type: :interaction_resolved, interaction_id: id} = event)
       when is_binary(id) do
    case runtime_status(conversation, event) do
      %{conversation: %{pending_interaction: nil}} -> true
      %{conversation: %{pending_interaction: %{id: pending}}} -> pending != id
      _ -> false
    end
  end

  defp current_event?(_conversation, %{type: type})
       when type in [:interaction_requested, :interaction_resolved],
       do: false

  defp current_event?(conversation, %{type: type} = event)
       when type in [:run_completed, :run_failed, :run_cancelled, :storage_failed] do
    case {type, runtime_status(conversation, event)} do
      {:run_completed, %{phase: :terminal, run: %{state: :completed}}} ->
        true

      {:run_failed, %{phase: :terminal, run: %{state: :failed}}} ->
        true

      {:run_cancelled, %{phase: :terminal, run: %{state: state}}}
      when state in [:cancelled, :timed_out, :unknown_outcome] ->
        true

      {:storage_failed, %{phase: :storage_failed}} ->
        true

      _ ->
        false
    end
  end

  defp current_event?(_conversation, _event), do: true

  defp start_worker(state, event, resolver) do
    {pid, monitor} =
      :erlang.spawn_opt(
        fn -> resolve_current(state.conversation, event, resolver) end,
        [:link, :monitor]
      )

    %{state | pending: %{pid: pid, monitor: monitor, event: event}}
  end

  defp resolve_current(conversation, event, resolver) do
    current? = fn -> current_request?(conversation, event) end

    if current?.() do
      case event.request.kind do
        :sigma_tool_permission ->
          answer = permission_answer(resolver, event.request.tool_call)
          if current?.(), do: Conversation.resolve(conversation, event.interaction_id, answer)

        :permission ->
          case runtime_permission_answer(resolver, event.request, current?) do
            {:ok, answer} ->
              if current?.(), do: Conversation.resolve(conversation, event.interaction_id, answer)

            :error ->
              cancel_request(conversation, event)
          end

        :request_user_input ->
          case user_input_answer(resolver, event.request, current?) do
            {:ok, answer} ->
              if current?.(), do: Conversation.resolve(conversation, event.interaction_id, answer)

            :error ->
              cancel_request(conversation, event)
          end
      end
    end
  catch
    :exit, _ -> :ok
  end

  defp current_request?(conversation, event) do
    # Event payload alone is not authorization to open a Sigma question.
    case runtime_status(conversation, event) do
      %{
        phase: :waiting_interaction,
        conversation: %{pending_interaction: pending}
      } ->
        pending === %{id: event.interaction_id, request: event.request}

      _ ->
        false
    end
  end

  defp runtime_status(conversation, event) do
    case Conversation.status(conversation) do
      %{run: %{run_id: id, incarnation: incarnation}} = status
      when id === event.run_id and incarnation === event.incarnation ->
        status

      _ ->
        nil
    end
  catch
    :exit, _ -> nil
  end

  defp permission_answer(resolver, call) do
    case resolver.(call) do
      :allow -> :allow
      {:allow, patch} when is_map(patch) -> {:allow, patch}
      {:deny, _reason} = denied -> denied
      _ -> {:deny, :invalid_permission_result}
    end
  rescue
    _ -> {:deny, :permission_resolver_failed}
  catch
    _, _ -> {:deny, :permission_resolver_failed}
  end

  defp user_input_answer(resolver, request, current?) do
    case resolver.(request, current?) do
      {:ok, %{answers: answers} = answer} when is_map(answers) and map_size(answer) == 1 ->
        if valid_answers?(request, answers), do: {:ok, answer}, else: :error

      _ ->
        :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp runtime_permission_answer(resolver, request, current?) do
    case resolver.(request, current?) do
      decision when decision in [:approved, :denied] -> {:ok, decision}
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp valid_questions?(%{questions: questions}) when is_list(questions) and questions != [] do
    ids =
      Enum.map(questions, fn
        %{"id" => id} when is_binary(id) -> if String.trim(id) != "", do: id
        _ -> nil
      end)

    not Enum.member?(ids, nil) and length(Enum.uniq(ids)) == length(ids)
  end

  defp valid_questions?(_), do: false

  defp valid_answers?(request, answers) do
    valid_questions?(request) and valid_answer_entries?(request.questions, answers)
  end

  defp valid_answer_entries?(questions, answers) do
    ids = Enum.map(questions, & &1["id"])

    Enum.sort(Map.keys(answers)) == Enum.sort(ids) and
      Enum.all?(answers, fn {_id, answer} ->
        case answer do
          %{answers: [text]} when is_binary(text) and map_size(answer) == 1 ->
            String.trim(text) != ""

          %{"answers" => [text]} when is_binary(text) and map_size(answer) == 1 ->
            String.trim(text) != ""

          _ ->
            false
        end
      end)
  end

  defp cancel_request(conversation, event) do
    if current_request?(conversation, event) do
      cancel_current(Map.put(event, :conversation, conversation))
    end
  end

  defp cancel_current(%{conversation: conversation} = state) when is_pid(conversation) do
    case runtime_status(conversation, state) do
      %{phase: phase}
      when phase in [:terminal, :storage_failed, :recovery_required, :cancelling] ->
        :ok

      %{phase: _phase} ->
        case Conversation.cancel(conversation) do
          :ok -> :ok
          _ -> Logger.warning("InteractionResponder shutdown cancellation was rejected")
        end

      nil ->
        if Process.alive?(conversation),
          do:
            Logger.warning(
              "InteractionResponder could not verify its Conversation during shutdown"
            )
    end
  catch
    :exit, _ ->
      Logger.warning("InteractionResponder shutdown cancellation acknowledgement was unavailable")
  end

  defp cancel_current(_state), do: :ok

  defp stop_worker(%{pending: nil} = state), do: state

  defp stop_worker(%{pending: pending} = state) do
    Process.demonitor(pending.monitor, [:flush])
    Process.exit(pending.pid, :kill)
    %{state | pending: nil}
  end
end
