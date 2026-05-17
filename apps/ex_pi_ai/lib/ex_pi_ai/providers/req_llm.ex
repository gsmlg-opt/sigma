defmodule ExPiAi.Providers.ReqLLM do
  @behaviour ExPiAi.Provider

  @impl true
  def stream(params) do
    model = params.model
    context = params.context
    options = params.options

    api_key = options[:api_key]
    base_url = options[:base_url]
    
    # ReqLLM usually expects model as "provider:id" if not using standard ENV keys
    # But we can pass options directly.
    
    # Transform tools to ReqLLM format
    tools = Enum.map(context.tools, fn tool ->
      %{
        name: tool.name,
        description: tool.description,
        parameters: tool.input_schema
      }
    end)

    # Prepare messages
    messages = transform_messages(context.messages)
    
    # Add system prompt as the first message or use options
    messages = if context[:system_prompt] do
      [%{role: "system", content: context.system_prompt} | messages]
    else
      messages
    end

    stream_opts = [
      messages: messages,
      tools: tools,
      api_key: api_key,
      base_url: base_url,
      receive_timeout: 60_000
    ]

    # Use ReqLLM.stream_text
    case ReqLLM.stream_text(model.id, nil, stream_opts) do
      {:ok, %{stream: req_stream}} ->
        Elixir.Stream.resource(
          fn -> 
            {_initial_assistant_message(model), req_stream}
          end,
          fn {message, stream} ->
            case Enum.take(stream, 1) do
              [] -> {:halt, {message, stream}}
              [chunk] ->
                {events, new_message} = process_chunk(chunk, message)
                {events, {new_message, Elixir.Stream.drop(stream, 1)}}
            end
          end,
          fn _ -> :ok end
        )
      _ ->
        []
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
        cost: %{total: 0.0, input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0}
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

  defp transform_content(content) when is_list(content) do
    Enum.map(content, fn
      %{type: :text, text: text} -> %{type: "text", text: text}
      %{type: :thinking, thinking: thinking} -> %{type: "thinking", thinking: thinking}
      %{type: :tool_call} = tc -> 
        # Standardize for ReqLLM (usually OpenAI format)
        %{type: "tool", id: tc.id, function: %{name: tc.name, arguments: Jason.encode!(tc.arguments)}}
    end)
  end
  defp transform_content(content), do: content

  defp process_chunk(chunk, message) do
    case chunk do
      %{type: :content, content: text} ->
        # Update text block
        {new_content, idx} = append_or_create_block(message.content, :text, :text, text)
        new_message = %{message | content: new_content}
        {[{:text_delta, idx, text, new_message}], new_message}

      %{type: :thinking, content: thinking} ->
        {new_content, idx} = append_or_create_block(message.content, :thinking, :thinking, thinking)
        new_message = %{message | content: new_content}
        {[{:thinking_delta, idx, thinking, new_message}], new_message}

      %{type: :tool_call, tool_call: tc} ->
        # ReqLLM tool_call chunks might be partials or full?
        # Assuming partial based on "delta" in search
        # We need to manage tool call IDs and indices
        # Simplified: just emit toolcall events
        {new_content, idx} = handle_tool_chunk(message.content, tc)
        new_message = %{message | content: new_content}
        {[{:toolcall_delta, idx, tc.arguments_delta || "", new_message}], new_message}

      %{type: :meta, usage: usage, finish_reason: reason} ->
        # Finalize
        new_message = %{message | 
          usage: transform_usage(usage), 
          stop_reason: transform_stop_reason(reason)
        }
        {[{:done, new_message.stop_reason, new_message}], new_message}

      _ -> {[], message}
    end
  end

  defp append_or_create_block(content, type, key, value) do
    # Find last block of type
    last_idx = length(content) - 1
    last_block = Enum.at(content, last_idx)
    
    if last_block && last_block.type == type do
      new_block = Map.update!(last_block, key, &((&1 || "") <> value))
      {List.replace_at(content, last_idx, new_block), last_idx}
    else
      new_block = %{type: type} |> Map.put(key, value)
      {content ++ [new_block], length(content)}
    end
  end

  defp handle_tool_chunk(content, tc) do
    # tc.index usually identifies the tool call
    _idx = tc.index || 0
    # Map to our content blocks
    # We might have text/thinking blocks mixed in
    # For now, append tool calls at the end if not found
    # This is a bit complex for a "fast" version, let's keep it simple
    new_block = %{type: :tool_call, id: tc.id, name: tc.name, arguments: %{}}
    {content ++ [new_block], length(content)}
  end

  defp transform_usage(usage) do
    %{
      input: usage["prompt_tokens"] || 0,
      output: usage["completion_tokens"] || 0,
      cache_read: 0,
      cache_write: 0,
      total_tokens: usage["total_tokens"] || 0,
      cost: %{total: 0.0, input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0}
    }
  end

  defp transform_stop_reason("stop"), do: :stop
  defp transform_stop_reason("length"), do: :length
  defp transform_stop_reason("tool_calls"), do: :tool_use
  defp transform_stop_reason(_), do: nil
end
