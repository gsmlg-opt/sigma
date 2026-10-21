defmodule Sigma.Agent.Backplane.Provider do
  @moduledoc false

  @behaviour Backplane.AgentRuntime.ConversationAdapter

  alias Sigma.Ai.{Provider, ProviderEvent, ProviderRequest, ProviderUsage}
  alias Sigma.Agent.Message
  alias Sigma.Agent.Hooks.ModelRequest

  @impl true
  def stream(request, %{host: host, owner: owner}) do
    collaboration = Enum.filter(request.messages, &Map.has_key?(&1, :collaboration))

    if collaboration != [],
      do: send_owner(owner, {:backplane_collaboration_messages, collaboration})

    context =
      host.build_context.(normalize_messages(request.messages))
      |> Map.put(:tools, request.tools)
      |> Map.put(:catalog_revision, request.catalog_revision)

    case host.context_error.(context) do
      nil -> provider_stream(host, owner, request, context)
      error -> [%{type: :response_failed, error: error}]
    end
  end

  defp provider_stream(host, owner, runtime_request, context) do
    request =
      %{
        model: host.model,
        session_id: host.session_id,
        log_session_id: host.log_session_id,
        turn_id: Map.get(host, :turn_id, runtime_request.run_id),
        origin_session_id: host.session_id,
        purpose: :turn,
        context: context,
        options: host.provider_options,
        message_id: assistant_id(runtime_request)
      }
      |> ProviderRequest.new()
      |> ProviderRequest.begin(System.monotonic_time(:millisecond), DateTime.utc_now())

    acknowledge_request_start(owner, request, context)

    observer =
      ModelRequest.start(
        Map.get(host, :hook_specs, []),
        Map.get(host, :hook_context, %{}),
        request
      )

    stream_request(host, owner, request, observer)
  rescue
    exception ->
      [%{type: :response_failed, error: Sigma.Ai.ProviderError.from_exception(exception)}]
  catch
    kind, reason ->
      [%{type: :response_failed, error: Sigma.Ai.ProviderError.from_exception({kind, reason})}]
  end

  defp stream_request(host, owner, request, observer) do
    host.provider
    |> Provider.stream(request)
    |> Stream.transform(
      fn -> request end,
      fn event, request ->
        {mapped, request} = map_event(event, request)
        send_owner(owner, {:backplane_request_progress, request})
        ModelRequest.progress(observer, request)

        if event.type in [:response_completed, :response_failed] do
          ModelRequest.finish(observer, request, Map.get(event, :error))
          ref = make_ref()
          send_owner(owner, {:backplane_provider_boundary, self(), ref, finish_request(request)})

          receive do
            {:backplane_provider_continue, ^ref} -> :ok
          end
        end

        {List.wrap(mapped), request}
      end,
      fn request ->
        ModelRequest.finish(observer, request)
        send_owner(owner, {:backplane_request_finished, finish_request(request)})
      end
    )
  rescue
    exception ->
      error = Sigma.Ai.ProviderError.from_exception(exception)
      ModelRequest.finish(observer, %{request | status: :failed}, error)
      [%{type: :response_failed, error: error}]
  catch
    kind, reason ->
      error = Sigma.Ai.ProviderError.from_exception({kind, reason})
      ModelRequest.finish(observer, %{request | status: :failed}, error)
      [%{type: :response_failed, error: error}]
  end

  defp map_event(%ProviderEvent{type: :response_started, message: message}, request) do
    {%{type: :response_started, message: with_id(message, request.message_id)}, request}
  end

  defp map_event(%ProviderEvent{type: :content_text_delta} = event, request) do
    request = ProviderRequest.mark_output(request, System.monotonic_time(:millisecond), :text)
    {event_map(event, request.message_id), request}
  end

  defp map_event(%ProviderEvent{type: :content_thinking_delta} = event, request) do
    request = ProviderRequest.mark_output(request, System.monotonic_time(:millisecond), :thinking)
    {event_map(event, request.message_id), request}
  end

  defp map_event(%ProviderEvent{type: :tool_call_arguments_delta} = event, request) do
    request =
      ProviderRequest.mark_output(request, System.monotonic_time(:millisecond), :tool_arguments)

    {event_map(event, request.message_id), request}
  end

  defp map_event(%ProviderEvent{type: :usage_updated, usage: usage} = event, request) do
    {event_map(event, request.message_id), put_usage(request, usage)}
  end

  defp map_event(%ProviderEvent{type: :response_completed, message: message} = event, request) do
    usage = event.usage || ProviderUsage.from_map(message[:usage])
    request = request |> put_usage(usage) |> Map.put(:status, :completed)
    {event_map(event, request.message_id), request}
  end

  defp map_event(%ProviderEvent{type: :response_failed, error: error} = event, request) do
    status =
      if match?(%Sigma.Ai.ProviderError{kind: :cancelled}, error), do: :cancelled, else: :failed

    {event_map(event, request.message_id), %{request | status: status}}
  end

  defp map_event(%ProviderEvent{} = event, request),
    do: {event_map(event, request.message_id), request}

  defp event_map(%ProviderEvent{message: message} = event, message_id) when is_map(message) do
    event
    |> Map.from_struct()
    |> Map.put(:message, with_id(message, message_id))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp event_map(event, _message_id) do
    event
    |> Map.from_struct()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp with_id(message, nil), do: message
  defp with_id(message, id), do: Map.put(message, :id, id)

  defp finish_request(%ProviderRequest{status: :running} = request) do
    ProviderRequest.finish(
      request,
      :failed,
      System.monotonic_time(:millisecond),
      DateTime.utc_now()
    )
  end

  defp finish_request(%ProviderRequest{} = request) do
    ProviderRequest.finish(
      request,
      request.status,
      System.monotonic_time(:millisecond),
      DateTime.utc_now()
    )
  end

  defp put_usage(request, %ProviderUsage{} = usage), do: ProviderRequest.put_usage(request, usage)
  defp put_usage(request, _usage), do: request

  defp assistant_id(%{attempt_id: attempt_id}), do: "msg_assistant_" <> attempt_id

  @doc false
  def normalize_messages(messages), do: Enum.map(messages, &normalize_message/1)

  defp send_owner({owner, key}, event), do: send(owner, {:child_io, key, event})
  defp send_owner(owner, event), do: send(owner, event)

  defp acknowledge_request_start(owner, request, context) do
    owner_pid = if is_tuple(owner), do: elem(owner, 0), else: owner
    monitor = Process.monitor(owner_pid)
    ref = make_ref()
    send_owner(owner, {:backplane_request_started, self(), ref, request, context})

    try do
      receive do
        {:backplane_request_ready, ^ref, :ok} ->
          :ok

        {:backplane_request_ready, ^ref, {:error, reason}} ->
          raise Sigma.Ai.ProviderError.from_exception(reason)

        {:DOWN, ^monitor, :process, ^owner_pid, reason} ->
          raise Sigma.Ai.ProviderError.from_exception({:backplane_owner_down, reason})
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp normalize_message(%Message{} = message), do: message

  defp normalize_message(%{role: :tool} = message) do
    result = Map.get(message, :result, %{})
    {content, metadata, is_error} = tool_result(result)

    %Sigma.Agent.Message{
      id: "msg_tool_res_#{message.tool_call_id}",
      role: :tool_result,
      tool_call_id: message.tool_call_id,
      tool_name: message.name,
      content: content,
      metadata: metadata,
      is_error: is_error,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp normalize_message(%{role: :assistant} = message) do
    id = Map.get(message, :id, "msg_assistant_backplane")
    Sigma.Agent.Message.assistant(id, Map.delete(message, :id))
  end

  defp normalize_message(%{role: :user, id: id, content: content} = message) do
    normalized =
      Message.user(id, content, Map.get(message, :timestamp, System.system_time(:millisecond)))

    metadata = Map.get(message, :metadata, %{})

    metadata =
      if message[:collaboration],
        do: Map.put(metadata, :collaboration, message.collaboration),
        else: metadata

    %{normalized | metadata: metadata}
  end

  defp normalize_message(message), do: message

  defp tool_result(%{content: content} = result) when is_list(content),
    do: {content, %{}, Map.get(result, :is_error, false)}

  defp tool_result(%{content: content} = result) when is_binary(content),
    do: {[%{type: :text, text: content}], %{}, Map.get(result, :is_error, false)}

  defp tool_result(%{error: error}),
    do: {[%{type: :text, text: "Error: #{inspect(error)}"}], %{}, true}

  # Native collaboration contracts return structured maps rather than Sigma
  # content blocks. Keep the complete JSON for the model and canonical history.
  defp tool_result(result) when is_map(result) do
    case Jason.encode(result) do
      {:ok, json} ->
        {[%{type: :text, text: json}], %{structured_result: Jason.decode!(json)},
         Map.get(result, :is_error, false)}

      {:error, _} ->
        malformed_result()
    end
  end

  defp tool_result(_result), do: malformed_result()

  defp malformed_result,
    do: {[%{type: :text, text: "Error: malformed tool result"}], %{}, true}
end
