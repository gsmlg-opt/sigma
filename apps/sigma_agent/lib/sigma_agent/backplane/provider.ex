defmodule Sigma.Agent.Backplane.Provider do
  @moduledoc false

  @behaviour Backplane.AgentRuntime.ConversationAdapter

  alias Sigma.Ai.{Provider, ProviderEvent, ProviderRequest, ProviderUsage}
  alias Sigma.Agent.Backplane.GoalUsage
  alias Sigma.Agent.Message
  alias Sigma.Agent.Hooks.ModelRequest

  @impl true
  def stream(request, %{host: host, owner: owner} = context) do
    case observe_worker(context[:provider_lifecycle_store], request) do
      :ok -> stream_observed(request, host, owner)
      {:error, error} -> [%{type: :response_failed, error: error}]
    end
  end

  defp observe_worker(nil, _request), do: :ok

  defp observe_worker(store, request) do
    Sigma.Agent.Backplane.Store.observe_provider(
      store,
      Sigma.Agent.Backplane.ProviderLifecycle.identity(request)
    )
  catch
    :exit, reason ->
      {:error,
       Backplane.AgentRuntime.Error.new(
         :unknown_outcome,
         "provider lifecycle observer is unavailable",
         cause: reason
       )}
  end

  defp stream_observed(request, host, owner) do
    canonical =
      Enum.filter(request.messages, fn message ->
        Map.has_key?(message, :collaboration) or Map.has_key?(message, :host_feedback)
      end)

    if canonical != [],
      do: send_owner(owner, {:backplane_collaboration_messages, canonical})

    window = if is_function(host[:context_window], 0), do: host.context_window.()

    if (is_function(host.build_context, 2) or is_function(host.build_context, 3)) and
         is_nil(window) do
      raise Sigma.Ai.ProviderError.from_exception(:context_window_unavailable)
    end

    context =
      cond do
        is_function(host.build_context, 3) ->
          host.build_context.(normalize_messages(request.messages), window, request.tools)

        is_function(host.build_context, 2) ->
          host.build_context.(normalize_messages(request.messages), window)

        true ->
          host.build_context.(normalize_messages(request.messages))
      end
      |> Map.put(:runtime_context_window, window)
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
    {event_map(%{event | usage: usage}, request.message_id), request}
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
    |> runtime_usage()
    |> runtime_stop_reason()
    |> Map.put(:message, with_id(message, message_id))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp event_map(event, _message_id) do
    event
    |> Map.from_struct()
    |> runtime_usage()
    |> runtime_stop_reason()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp runtime_usage(%{type: type} = event)
       when type in [:usage_updated, :response_completed] do
    Map.put(event, :usage, GoalUsage.normalize(event[:usage]))
  end

  defp runtime_usage(event), do: event

  # The public lifecycle consumes an atom. Keep Sigma's richer value within
  # its Provider boundary; the original message still retains the raw reason.
  defp runtime_stop_reason(%{stop_reason: %Sigma.Ai.ProviderStopReason{reason: reason}} = event),
    do: Map.put(event, :stop_reason, reason)

  defp runtime_stop_reason(event), do: event

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
    {content, metadata, is_error} = tool_result(message.name, result)

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

  defp normalize_message(
         %{role: :user, content: content, host_feedback: %{"id" => id} = metadata} = message
       ) do
    normalized =
      Message.user(
        "msg_host_feedback_" <> id,
        content,
        Map.get(message, :timestamp, System.system_time(:millisecond))
      )

    original = Map.get(message, :metadata, %{}) |> Map.delete("host_feedback")
    %{normalized | metadata: Map.put(original, :host_feedback, metadata)}
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

  defp tool_result("view_image", %{data: data, mime_type: mime} = result)
       when is_binary(data) and is_binary(mime) do
    image = %{
      type: :image,
      data: Base.encode64(data),
      mime_type: mime,
      detail: Map.get(result, :detail, "high")
    }

    # The data URL preserves the original bytes in the canonical result; raw
    # image bytes are not UTF-8 JSON and must not be written to the journal.
    canonical = Map.delete(result, :data)

    if canonical[:image_url] == "data:#{mime};base64,#{image.data}" do
      project_result(canonical, [image])
    else
      malformed_result()
    end
  end

  defp tool_result(_name, %{error: %Backplane.AgentRuntime.Error{} = error} = result) do
    result
    |> Map.put(:error, Backplane.AgentRuntime.Error.to_map(error))
    |> Map.put(:is_error, true)
    |> project_result(nil)
  end

  defp tool_result(_name, %{error: _error} = result) do
    project_result(Map.put(result, :is_error, true), nil)
  end

  # Memory's content is one field of a JSON response, not a display-block
  # envelope. Keep path, line position and truncation visible to the model.
  defp tool_result("memories::read", %{content: content} = result) when is_binary(content),
    do: project_result(result, nil)

  defp tool_result("history::read_item", %{content: text, images: images} = result)
       when is_binary(text) and is_list(images) do
    case Jason.encode(Map.delete(result, :images)) do
      {:ok, json} -> project_result(result, [%{type: :text, text: json} | images])
      {:error, _} -> malformed_result()
    end
  end

  defp tool_result(_name, %{content: content})
       when not is_list(content) and not is_binary(content),
       do: malformed_result()

  defp tool_result(_name, result) when is_map(result) do
    content =
      case result[:content] do
        content when is_list(content) -> content
        content when is_binary(content) -> [%{type: :text, text: content}]
        _ -> nil
      end

    project_result(result, content)
  end

  defp tool_result(_name, _result), do: malformed_result()

  # Keep the full JSON-safe result independently of its model/UI projection.
  # Validate every sibling field so handles cannot hide beside valid content.
  defp project_result(result, content) do
    with true <- is_boolean(Map.get(result, :is_error, false)),
         true <- is_nil(content) or Enum.all?(content, &valid_result_block?/1),
         {:ok, json} <- Jason.encode(result) do
      {content || [%{type: :text, text: json}], %{structured_result: Jason.decode!(json)},
       Map.get(result, :is_error, false)}
    else
      _ -> malformed_result()
    end
  end

  defp valid_result_block?(%{type: :text, text: text}), do: is_binary(text)

  defp valid_result_block?(%{type: :image, data: data, mime_type: mime}),
    do: is_binary(data) and is_binary(mime)

  defp valid_result_block?(_block), do: false

  defp malformed_result,
    do: {[%{type: :text, text: "Error: malformed tool result"}], %{}, true}
end
