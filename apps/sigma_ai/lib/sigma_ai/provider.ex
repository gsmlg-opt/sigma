defmodule Sigma.Ai.Provider do
  @moduledoc "Provider behaviour plus the provider-neutral compatibility seam."

  alias Sigma.Ai.{
    ProviderCapabilities,
    ProviderError,
    ProviderEvent,
    ProviderRequest,
    ProviderStopReason,
    ProviderUsage
  }

  @callback stream(params :: map()) :: Enumerable.t()
  @callback stream_normalized(request :: ProviderRequest.t()) :: Enumerable.t()
  @callback capabilities(model :: map()) :: ProviderCapabilities.t()

  @optional_callbacks stream_normalized: 1, capabilities: 1

  def stream(provider, %ProviderRequest{} = request) when is_atom(provider) do
    normalized =
      provider
      |> provider_stream(request)
      |> Stream.flat_map(&normalize_legacy_event/1)

    bridge(normalized, Keyword.get(request.options, :cancellation_ref))
  end

  def capabilities(provider, model) do
    if function_exported?(provider, :capabilities, 1) do
      provider.capabilities(model)
    else
      default_capabilities(model)
    end
  end

  def normalize_legacy_event(%ProviderEvent{} = event), do: [event]

  def normalize_legacy_event({:start, message}) do
    [
      %ProviderEvent{
        type: :response_started,
        message: message,
        usage: ProviderUsage.from_map(message[:usage])
      }
    ]
  end

  def normalize_legacy_event({:text_delta, index, delta, message}) do
    [%ProviderEvent{type: :content_text_delta, index: index, delta: delta, message: message}]
  end

  def normalize_legacy_event({:thinking_delta, index, delta, message}) do
    [%ProviderEvent{type: :content_thinking_delta, index: index, delta: delta, message: message}]
  end

  def normalize_legacy_event({:toolcall_start, index, message}) do
    [%ProviderEvent{type: :tool_call_started, index: index, message: message}]
  end

  def normalize_legacy_event({:toolcall_delta, index, delta, message}) do
    [
      %ProviderEvent{
        type: :tool_call_arguments_delta,
        index: index,
        delta: delta,
        message: message
      }
    ]
  end

  def normalize_legacy_event({:toolcall_end, index, tool_call, message}) do
    if valid_tool_call?(tool_call) do
      [
        %ProviderEvent{
          type: :tool_call_completed,
          index: index,
          tool_call: Map.take(tool_call, [:id, :name, :arguments]),
          message: message
        }
      ]
    else
      [
        %ProviderEvent{
          type: :response_failed,
          error: ProviderError.malformed(:invalid_tool_call_arguments),
          message: message
        }
      ]
    end
  end

  def normalize_legacy_event({:done, reason, message}) do
    usage_event =
      case ProviderUsage.from_map(message[:usage]) do
        nil -> []
        usage -> [%ProviderEvent{type: :usage_updated, usage: usage, message: message}]
      end

    usage_event ++
      [
        %ProviderEvent{
          type: :response_completed,
          stop_reason: ProviderStopReason.normalize(reason),
          message: message
        }
      ]
  end

  def normalize_legacy_event({:provider_error, %ProviderError{} = error}) do
    [%ProviderEvent{type: :response_failed, error: error}]
  end

  def normalize_legacy_event({type, _index, _value, _message})
      when type in [:text_end, :thinking_end],
      do: []

  def normalize_legacy_event({type, _index, _message})
      when type in [:text_start, :thinking_start],
      do: []

  def normalize_legacy_event(other) do
    [
      %ProviderEvent{
        type: :response_failed,
        error: ProviderError.malformed({:unknown_provider_event, other})
      }
    ]
  end

  defp provider_stream(provider, request) do
    if function_exported?(provider, :stream_normalized, 1) do
      provider.stream_normalized(request)
    else
      provider.stream(ProviderRequest.to_legacy(request))
    end
  end

  defp bridge(stream, cancellation_ref) do
    Stream.resource(
      fn ->
        consumer = self()
        stream_ref = make_ref()

        {:ok, producer} =
          Task.Supervisor.start_child(
            Sigma.Ai.ProviderTaskSupervisor,
            fn -> produce(stream, consumer, stream_ref) end
          )

        monitor_ref = Process.monitor(producer)

        %{
          producer: producer,
          monitor_ref: monitor_ref,
          stream_ref: stream_ref,
          cancellation_ref: cancellation_ref,
          terminal?: false
        }
      end,
      &bridge_next/1,
      &stop_bridge/1
    )
  end

  defp produce(stream, consumer, stream_ref) do
    watch_consumer(consumer, self())

    try do
      await_demand!(stream_ref, consumer)

      Enum.each(stream, fn event ->
        send(consumer, {:provider_event, stream_ref, event})
        await_demand!(stream_ref, consumer)
      end)

      send(consumer, {:provider_done, stream_ref})
    rescue
      exception ->
        send(
          consumer,
          {:provider_failed, stream_ref, ProviderError.from_exception(exception)}
        )
    catch
      kind, reason ->
        send(
          consumer,
          {:provider_failed, stream_ref, ProviderError.from_exception({kind, reason})}
        )
    end
  end

  defp watch_consumer(consumer, producer) do
    spawn(fn ->
      consumer_ref = Process.monitor(consumer)
      producer_ref = Process.monitor(producer)

      receive do
        {:DOWN, ^consumer_ref, :process, ^consumer, _reason} ->
          if Process.alive?(producer), do: Process.exit(producer, :kill)

        {:DOWN, ^producer_ref, :process, ^producer, _reason} ->
          :ok
      end
    end)
  end

  defp await_demand!(stream_ref, consumer) do
    receive do
      {:provider_demand, ^stream_ref} -> :ok
      {:cancel, _cancellation_ref} -> throw(:provider_cancelled)
      {:DOWN, _ref, :process, ^consumer, _reason} -> throw(:consumer_stopped)
    end
  end

  defp bridge_next(%{terminal?: true} = state), do: {:halt, state}

  defp bridge_next(state) do
    send(state.producer, {:provider_demand, state.stream_ref})

    receive do
      {:provider_event, stream_ref, event} when stream_ref == state.stream_ref ->
        if terminal_event?(event) do
          if Process.alive?(state.producer), do: Process.exit(state.producer, :kill)
          {[event], %{state | terminal?: true}}
        else
          {[event], state}
        end

      {:provider_done, stream_ref} when stream_ref == state.stream_ref ->
        error = %ProviderEvent{
          type: :response_failed,
          error: ProviderError.malformed(:stream_ended_without_terminal)
        }

        {[error], %{state | terminal?: true}}

      {:provider_failed, stream_ref, error} when stream_ref == state.stream_ref ->
        {[%ProviderEvent{type: :response_failed, error: error}], %{state | terminal?: true}}

      {:cancel, cancellation_ref}
      when not is_nil(cancellation_ref) and cancellation_ref == state.cancellation_ref ->
        send(state.producer, {:cancel, cancellation_ref})
        {[], state}

      {:DOWN, monitor_ref, :process, producer, :normal}
      when monitor_ref == state.monitor_ref and producer == state.producer ->
        error = %ProviderEvent{
          type: :response_failed,
          error: ProviderError.malformed(:stream_ended_without_terminal)
        }

        {[error], %{state | terminal?: true}}

      {:DOWN, monitor_ref, :process, producer, reason}
      when monitor_ref == state.monitor_ref and producer == state.producer ->
        {[
           %ProviderEvent{
             type: :response_failed,
             error: ProviderError.from_exception(reason)
           }
         ], %{state | terminal?: true}}
    end
  end

  defp terminal_event?(%ProviderEvent{type: type})
       when type in [:response_completed, :response_failed],
       do: true

  defp terminal_event?(_event), do: false

  defp stop_bridge(state) do
    Process.demonitor(state.monitor_ref, [:flush])
    if Process.alive?(state.producer), do: Process.exit(state.producer, :kill)
    :ok
  end

  defp valid_tool_call?(%{id: id, name: name, arguments: arguments}) do
    is_binary(id) and id != "" and is_binary(name) and name != "" and is_map(arguments)
  end

  defp valid_tool_call?(_tool_call), do: false

  defp default_capabilities(model) do
    provider = Map.get(model, :provider, Map.get(model, "provider", ""))
    anthropic? = provider == "anthropic" or String.contains?(to_string(provider), "anthropic")

    %ProviderCapabilities{
      tools: true,
      thinking: anthropic?,
      image_input: true,
      context_window: integer_value(model, [:context_window, "contextWindow"]),
      max_output_tokens: integer_value(model, [:max_tokens, "maxTokens"]),
      supported_options: if(anthropic?, do: [:thinking_budget, :max_tokens], else: [:max_tokens])
    }
  end

  defp integer_value(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_integer(value) and value > 0 -> value
        _value -> nil
      end
    end)
  end
end
