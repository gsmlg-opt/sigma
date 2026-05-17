defmodule ExPiAi.Providers.Anthropic do
  @behaviour ExPiAi.Provider

  alias ExPiAi.Stream

  @impl true
  def stream(params) do
    model = params.model
    context = params.context
    options = params.options

    api_key = options[:api_key] || System.get_env("ANTHROPIC_AUTH_TOKEN")
    base_url = options[:base_url] || System.get_env("ANTHROPIC_BASE_URL") || "https://api.anthropic.com"

    body = %{
      model: model.id,
      messages: transform_messages(context.messages),
      system: context[:system_prompt],
      max_tokens: options[:max_tokens] || 4096,
      stream: true
    }

    # Add tools if present
    body = if context[:tools], do: Map.put(body, :tools, transform_tools(context.tools)), else: body

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]

    Elixir.Stream.resource(
      fn ->
        Req.post!(base_url <> "/v1/messages",
          json: body,
          headers: headers,
          receive_timeout: 60_000,
          into: fn {:data, data}, {req, resp} ->
            send(self(), {:chunk, data})
            {:cont, {req, resp}}
          end
        )
        {_initial_assistant_message(model), ""}
      end,
      fn {message, buffer} ->
        receive do
          {:chunk, chunk} ->
            {events, new_buffer} = Stream.decode(buffer, chunk)
            {processed_events, new_message} = process_events(events, message)
            {processed_events, {new_message, new_buffer}}
        after
          60_000 -> {:halt, {message, buffer}}
        end
      end,
      fn _ -> :ok end
    )
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

      %{role: :tool_result, tool_call_id: id, content: content, is_error: is_error} ->
        %{
          role: "user",
          content: [
            %{
              type: "tool_result",
              tool_use_id: id,
              content: transform_tool_result_content(content),
              is_error: is_error
            }
          ]
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
      %{type: :text, text: text} -> %{type: "text", text: text}
      %{type: :thinking, thinking: thinking} -> %{type: "thinking", thinking: thinking}
      %{type: :tool_call} = tc -> %{type: "tool_use", id: tc.id, name: tc.name, input: tc.arguments}
    end)
  end

  defp transform_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        name: tool.name,
        description: tool.description,
        input_schema: tool.parameters
      }
    end)
  end

  defp process_events(events, message) do
    Enum.map_reduce(events, message, fn event, acc ->
      case event do
        %{"type" => "message_start", "message" => msg} ->
          new_acc = %{acc | response_id: msg["id"]}
          {{:start, new_acc}, new_acc}

        %{"type" => "content_block_start", "index" => idx, "content_block" => block} ->
          result = case block["type"] do
            "text" -> {:text, %{type: :text, text: ""}, :text_start}
            "thinking" -> {:thinking, %{type: :thinking, thinking: ""}, :thinking_start}
            "tool_use" -> {:tool_call, %{type: :tool_call, id: block["id"], name: block["name"], partial_json: ""}, :toolcall_start}
            _ -> nil
          end

          if result do
            {_type, initial_block, event_type} = result
            new_content = List.insert_at(acc.content, idx, initial_block)
            new_acc = %{acc | content: new_content}
            {{event_type, idx, new_acc}, new_acc}
          else
            {nil, acc}
          end

        %{"type" => "content_block_delta", "index" => idx, "delta" => delta} ->
          case delta["type"] do
            "text_delta" ->
              text = delta["text"]
              # Update content at idx
              new_content = update_content(acc.content, idx, fn block ->
                %{block | text: (block[:text] || "") <> text}
              end)
              new_acc = %{acc | content: new_content}
              {{:text_delta, idx, text, new_acc}, new_acc}

            "thinking_delta" ->
              thinking = delta["thinking"]
              new_content = update_content(acc.content, idx, fn block ->
                %{block | thinking: (block[:thinking] || "") <> thinking}
              end)
              new_acc = %{acc | content: new_content}
              {{:thinking_delta, idx, thinking, new_acc}, new_acc}

            "input_json_delta" ->
              partial_json = delta["partial_json"]
              # For tool call, we accumulate JSON
              new_content = update_content(acc.content, idx, fn block ->
                %{block | partial_json: (block[:partial_json] || "") <> partial_json}
              end)
              new_acc = %{acc | content: new_content}
              {{:toolcall_delta, idx, partial_json, new_acc}, new_acc}
            
            _ -> {nil, acc}
          end

        %{"type" => "content_block_stop", "index" => idx} ->
          # Finalize block
          block = Enum.at(acc.content, idx)
          if block do
            case block.type do
              :text -> {{:text_end, idx, block.text, acc}, acc}
              :thinking -> {{:thinking_end, idx, block.thinking, acc}, acc}
              :tool_call ->
                # Parse JSON
                args = case Jason.decode(block.partial_json) do
                  {:ok, decoded} -> decoded
                  _ -> %{}
                end
                tool_call = %{type: :tool_call, id: block.id, name: block.name, arguments: args}
                new_content = List.replace_at(acc.content, idx, tool_call)
                new_acc = %{acc | content: new_content}
                {{:toolcall_end, idx, tool_call, new_acc}, new_acc}
              _ -> {nil, acc}
            end
          else
            {nil, acc}
          end

        %{"type" => "message_delta", "delta" => delta, "usage" => usage} ->
          stop_reason = case delta["stop_reason"] do
            "end_turn" -> :stop
            "max_tokens" -> :length
            "tool_use" -> :tool_use
            _ -> nil
          end
          new_acc = %{acc | stop_reason: stop_reason, usage: transform_usage(usage)}
          # We don't emit a separate event for message_delta usually, 
          # but we wait for message_stop or done?
          # Actually TS emits usage in message_delta.
          {nil, new_acc}

        %{"type" => "message_stop"} ->
          {{:done, acc.stop_reason, acc}, acc}

        _ -> {nil, acc}
      end
    end)
    |> then(fn {events, acc} -> {Enum.reject(events, &is_nil/1), acc} end)
  end

  defp update_content(content, idx, fun) do
    List.replace_at(content, idx, fun.(Enum.at(content, idx)))
  end

  defp transform_usage(usage) do
    %{
      input: usage["input_tokens"] || 0,
      output: usage["output_tokens"] || 0,
      cache_read: usage["cache_read_input_tokens"] || 0,
      cache_write: usage["cache_creation_input_tokens"] || 0,
      total_tokens: (usage["input_tokens"] || 0) + (usage["output_tokens"] || 0),
      cost: %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0, total: 0.0}
    }
  end
end
