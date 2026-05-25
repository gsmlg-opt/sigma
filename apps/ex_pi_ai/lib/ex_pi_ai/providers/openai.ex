defmodule PiAi.Providers.OpenAI do
  @behaviour PiAi.Provider

  alias PiAi.Stream

  @impl true
  def stream(params) do
    model = params.model
    context = params.context
    options = params.options

    api_key =
      options[:api_key] || System.get_env("OPENAI_API_KEY") ||
        System.get_env("OPENROUTER_API_KEY")

    base_url =
      options[:base_url] || System.get_env("OPENAI_BASE_URL") || "https://api.openai.com/v1"

    body = %{
      model: model.id,
      messages:
        context.messages
        |> transform_messages()
        |> prepend_system_message(context[:system] || context[:system_prompt]),
      max_tokens: options[:max_tokens] || 4096,
      stream: true,
      stream_options: %{include_usage: true}
    }

    # Add tools if present
    body =
      if context[:tools], do: Map.put(body, :tools, transform_tools(context.tools)), else: body

    headers = [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]

    Elixir.Stream.resource(
      fn ->
        resp =
          try do
            Req.post!(base_url <> "/chat/completions",
              json: body,
              headers: headers,
              receive_timeout: options[:receive_timeout] || 120_000,
              into: :self
            )
          rescue
            e in [Req.TransportError, Finch.TransportError] ->
              reraise transport_error_message(e), __STACKTRACE__
          end

        {_initial_assistant_message(model), "", :streaming, resp}
      end,
      fn
        {message, _buffer, :done, resp} ->
          {:halt, {message, "", :done, resp}}

        {message, buffer, :streaming, resp} ->
          receive do
            req_message ->
              {processed_events, new_message, new_buffer, status} =
                handle_async_message(resp, req_message, message, buffer)

              {processed_events, {new_message, new_buffer, status, resp}}
          after
            options[:receive_timeout] || 120_000 ->
              Req.cancel_async_response(resp)
              raise transport_error_message(%{reason: :timeout})
          end
      end,
      fn
        {_message, _buffer, :streaming, resp} -> Req.cancel_async_response(resp)
        _ -> :ok
      end
    )
  end

  # A network timeout or connection failure to the AI provider is an
  # expected failure — convert it into a RuntimeError with a readable
  # message so the agent surfaces it as a clean {:turn_error, ...} flash
  # instead of crashing the turn task.
  defp transport_error_message(%{reason: :timeout}) do
    "The AI provider did not respond in time (request timed out). " <>
      "Check your network connection and API key, then try again."
  end

  defp transport_error_message(%{reason: reason}) do
    "Network error contacting the AI provider: #{inspect(reason)}. " <>
      "Check your connection and try again."
  end

  defp handle_async_message(resp, req_message, message, buffer) do
    case Req.parse_message(resp, req_message) do
      {:ok, chunks} ->
        Enum.reduce(chunks, {[], message, buffer, :streaming}, fn
          {:data, chunk}, {acc_events, acc_message, acc_buffer, _status} ->
            {events, new_buffer} = Stream.decode(acc_buffer, chunk)
            {processed_events, new_message} = process_events(events, acc_message)

            status =
              if Enum.any?(processed_events, &match?({:done, _, _}, &1)),
                do: :done,
                else: :streaming

            {acc_events ++ processed_events, new_message, new_buffer, status}

          :done, {acc_events, acc_message, acc_buffer, _status} ->
            {acc_events, acc_message, acc_buffer, :done}

          _chunk, acc ->
            acc
        end)

      {:error, %{reason: reason}} ->
        raise transport_error_message(%{reason: reason})

      :unknown ->
        {[], message, buffer, :streaming}
    end
  end

  defp _initial_assistant_message(model) do
    %{
      role: :assistant,
      content: [],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: %{
        input: 0,
        output: 0,
        cache_read: 0,
        cache_write: 0,
        total_tokens: 0,
        cost: %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0, total: 0.0}
      },
      stop_reason: nil,
      response_id: nil,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp transform_messages(messages) do
    Enum.map(messages, fn
      %{role: :user, content: content} ->
        %{role: "user", content: content}

      %{role: :assistant, content: content} ->
        %{role: "assistant", content: transform_content(content)}

      %{role: :tool_result, tool_call_id: id, content: content} ->
        %{
          role: "tool",
          tool_call_id: id,
          content: transform_tool_result_content(content)
        }
    end)
  end

  defp transform_tool_result_content(content) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{type: :text, text: text} -> text
      _ -> ""
    end)
  end

  defp transform_tool_result_content(content), do: content

  defp transform_content(content) do
    Enum.map(content, fn
      %{type: :text, text: text} ->
        %{type: "text", text: text}

      %{type: :thinking, thinking: thinking} ->
        %{type: "thinking", thinking: thinking}

      %{type: :tool_call} = tc ->
        %{
          type: "tool",
          id: tc.id,
          function: %{name: tc.name, arguments: Jason.encode!(tc.arguments)}
        }
    end)
  end

  defp transform_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        type: "function",
        function: %{
          name: tool.name,
          description: tool.description,
          parameters: tool.parameters
        }
      }
    end)
  end

  defp prepend_system_message(messages, system) do
    case system_text(system) do
      nil -> messages
      text -> [%{role: "system", content: text} | messages]
    end
  end

  defp system_text(nil), do: nil
  defp system_text(""), do: nil
  defp system_text(text) when is_binary(text), do: text

  defp system_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.map(&system_block_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp system_block_text(text) when is_binary(text), do: text

  defp system_block_text(block) when is_map(block) do
    Map.get(block, :text) || Map.get(block, "text") || ""
  end

  defp system_block_text(_block), do: ""

  defp process_events(events, message) do
    Enum.map_reduce(events, message, fn event, acc ->
      case event do
        %{"error" => error} ->
          raise provider_error_message(error)

        :done ->
          {{:done, acc.stop_reason || :stop, acc}, acc}

        %{"choices" => choices} when choices != [] ->
          choice = Enum.at(choices, 0)
          index = choice["index"]
          delta = choice["delta"]
          finish_reason = choice["finish_reason"]

          acc =
            if finish_reason,
              do: %{acc | stop_reason: transform_stop_reason(finish_reason)},
              else: acc

          cond do
            Map.has_key?(delta, "content") ->
              text = delta["content"]
              # Check if we need to start a text block
              {acc, event_to_emit} =
                if Enum.at(acc.content, index) == nil do
                  new_content = List.insert_at(acc.content, index, %{type: :text, text: ""})
                  new_acc = %{acc | content: new_content}
                  {new_acc, {:text_start, index, new_acc}}
                else
                  {acc, nil}
                end

              new_content =
                update_content(acc.content, index, fn block ->
                  %{block | text: (block[:text] || "") <> text}
                end)

              new_acc = %{acc | content: new_content}
              delta_event = {:text_delta, index, text, new_acc}

              events = if event_to_emit, do: [event_to_emit, delta_event], else: [delta_event]
              {events, new_acc}

            Map.has_key?(delta, "tool_calls") ->
              # Handle tool calls... simplified
              {[], acc}

            true ->
              {[], acc}
          end

        %{"usage" => usage} ->
          new_acc = %{acc | usage: transform_usage(usage)}
          {[], new_acc}

        _ ->
          {[], acc}
      end
    end)
    |> then(fn {events, acc} -> {List.flatten(events), acc} end)
  end

  defp update_content(content, idx, fun) do
    List.replace_at(content, idx, fun.(Enum.at(content, idx)))
  end

  defp transform_stop_reason("stop"), do: :stop
  defp transform_stop_reason("length"), do: :length
  defp transform_stop_reason("tool_calls"), do: :tool_use
  defp transform_stop_reason(_), do: nil

  defp transform_usage(usage) do
    %{
      input: usage["prompt_tokens"] || 0,
      output: usage["completion_tokens"] || 0,
      cache_read: 0,
      cache_write: 0,
      total_tokens: usage["total_tokens"] || 0,
      cost: %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0, total: 0.0}
    }
  end

  defp provider_error_message(error) when is_map(error) do
    message = error["message"] || inspect(error)

    case error["code"] || error["type"] do
      nil -> "AI provider error: #{message}"
      code -> "AI provider error #{code}: #{message}"
    end
  end

  defp provider_error_message(error), do: "AI provider error: #{inspect(error)}"
end
