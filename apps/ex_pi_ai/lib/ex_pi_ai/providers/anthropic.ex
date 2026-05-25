defmodule PiAi.Providers.Anthropic do
  @behaviour PiAi.Provider

  alias PiAi.Stream

  @impl true
  def stream(params) do
    model = params.model
    context = params.context
    options = params.options
    session_id = Map.get(params, :session_id)

    api_key = options[:api_key] || System.get_env("ANTHROPIC_AUTH_TOKEN")

    system = build_system(context[:system] || context[:system_prompt])

    body = %{
      model: model.id,
      messages: transform_messages(context.messages),
      system: system,
      max_tokens: options[:max_tokens] || 4096,
      stream: true
    }

    body =
      if context[:tools], do: Map.put(body, :tools, transform_tools(context.tools)), else: body

    {body, extra_betas} =
      case options[:thinking_budget] do
        budget when is_integer(budget) and budget > 0 ->
          body =
            body
            |> Map.put(:thinking, %{type: "enabled", budget_tokens: budget})
            |> Map.update!(:max_tokens, &max(&1, budget + 1000))

          {body, ["interleaved-thinking-2025-05-14"]}

        _ ->
          {body, []}
      end

    beta_value = (["prompt-caching-2024-07-31"] ++ extra_betas) |> Enum.join(",")

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"},
      {"anthropic-beta", beta_value}
    ]

    inner = build_inner_stream(model, body, headers, options)

    Elixir.Stream.transform(
      inner,
      fn ->
        :telemetry.execute(
          [:ex_pi, :llm, :request, :start],
          %{system_time: System.system_time()},
          %{
            session_id: session_id,
            model: model.id,
            provider: "anthropic",
            request_body: body
          }
        )

        System.monotonic_time()
      end,
      fn event, start_time ->
        case event do
          {:done, _stop_reason, ai_msg} ->
            :telemetry.execute(
              [:ex_pi, :llm, :request, :stop],
              %{duration: System.monotonic_time() - start_time},
              %{
                session_id: session_id,
                model: model.id,
                usage: ai_msg.usage,
                response_content: ai_msg.content
              }
            )

            {[event], start_time}

          _ ->
            {[event], start_time}
        end
      end,
      fn _start_time -> :ok end
    )
  end

  defp build_inner_stream(model, body, headers, options) do
    base_url =
      options[:base_url] || System.get_env("ANTHROPIC_BASE_URL") || "https://api.anthropic.com"

    Elixir.Stream.resource(
      fn ->
        try do
          Req.post!(base_url <> "/v1/messages",
            json: body,
            headers: headers,
            receive_timeout: options[:receive_timeout] || 120_000,
            into: fn {:data, data}, {req, resp} ->
              send(self(), {:chunk, data})
              {:cont, {req, resp}}
            end
          )
        rescue
          e in Finch.TransportError ->
            reraise transport_error_message(e), __STACKTRACE__
        end

        {_initial_assistant_message(model), "", :streaming}
      end,
      fn
        {message, _buffer, :done} ->
          {:halt, message}

        {message, buffer, :streaming} ->
          receive do
            {:chunk, chunk} ->
              {events, new_buffer} = Stream.decode(buffer, chunk)
              {processed_events, new_message} = process_events(events, message)

              status =
                if Enum.any?(processed_events, &match?({:done, _, _}, &1)),
                  do: :done,
                  else: :streaming

              {processed_events, {new_message, new_buffer, status}}
          after
            120_000 -> {:halt, message}
          end
      end,
      fn _ -> :ok end
    )
  end

  # A network timeout or connection failure to the AI provider is an
  # expected failure — convert it into a RuntimeError with a readable
  # message so the agent surfaces it as a clean {:turn_error, ...} flash
  # instead of crashing the turn task.
  defp transport_error_message(%Finch.TransportError{reason: :timeout}) do
    "The AI provider did not respond in time (request timed out). " <>
      "Check your network connection and API key, then try again."
  end

  defp transport_error_message(%Finch.TransportError{reason: reason}) do
    "Network error contacting the AI provider: #{inspect(reason)}. " <>
      "Check your connection and try again."
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
      %{type: :text, text: text} ->
        %{type: "text", text: text}

      %{type: :thinking} = block ->
        sig = block[:thinking_signature]

        if is_binary(sig) and sig != "" do
          %{type: "thinking", thinking: block.thinking, signature: sig}
        else
          # No signature — fallback to text to avoid API rejection on replay
          %{type: "text", text: block.thinking}
        end

      %{type: :tool_call} = tc ->
        %{type: "tool_use", id: tc.id, name: tc.name, input: tc.arguments}
    end)
  end

  defp build_system(nil), do: nil
  defp build_system(""), do: nil

  defp build_system(blocks) when is_list(blocks) do
    blocks =
      blocks
      |> Enum.map(&transform_system_block/1)
      |> Enum.reject(&is_nil/1)

    if blocks == [], do: nil, else: blocks
  end

  defp build_system(text) do
    [%{type: "text", text: text, cache_control: %{type: "ephemeral", ttl: "1h"}}]
  end

  defp transform_system_block(text) when is_binary(text) do
    %{type: "text", text: text, cache_control: %{type: "ephemeral", ttl: "1h"}}
  end

  defp transform_system_block(block) when is_map(block) do
    type = Map.get(block, :type) || Map.get(block, "type")
    text = Map.get(block, :text) || Map.get(block, "text")

    if type in [:text, "text"] and is_binary(text) and text != "" do
      %{type: "text", text: text}
      |> maybe_put(
        :cache_control,
        transform_cache_control(Map.get(block, :cache_control) || Map.get(block, "cache_control"))
      )
    end
  end

  defp transform_system_block(_block), do: nil

  defp transform_cache_control(nil), do: nil

  defp transform_cache_control(cache_control) when is_map(cache_control) do
    type = Map.get(cache_control, :type) || Map.get(cache_control, "type")
    ttl = Map.get(cache_control, :ttl) || Map.get(cache_control, "ttl")

    if type do
      %{type: to_string(type)}
      |> maybe_put(:ttl, ttl)
    end
  end

  defp transform_cache_control(_cache_control), do: nil

  defp transform_tools([]), do: []

  defp transform_tools(tools) do
    last_idx = length(tools) - 1

    tools
    |> Enum.with_index()
    |> Enum.map(fn {tool, idx} ->
      base = %{name: tool.name, description: tool.description, input_schema: tool.parameters}
      if idx == last_idx, do: Map.put(base, :cache_control, %{type: "ephemeral"}), else: base
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp process_events(events, message) do
    Enum.map_reduce(events, message, fn event, acc ->
      case event do
        %{"type" => "message_start", "message" => msg} ->
          new_acc = %{acc | response_id: msg["id"]}
          {{:start, new_acc}, new_acc}

        %{"type" => "content_block_start", "index" => idx, "content_block" => block} ->
          result =
            case block["type"] do
              "text" ->
                {:text, %{type: :text, text: ""}, :text_start}

              "thinking" ->
                {:thinking, %{type: :thinking, thinking: ""}, :thinking_start}

              "tool_use" ->
                {:tool_call,
                 %{type: :tool_call, id: block["id"], name: block["name"], partial_json: ""},
                 :toolcall_start}

              _ ->
                nil
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
              new_content =
                update_content(acc.content, idx, fn block ->
                  %{block | text: (block[:text] || "") <> text}
                end)

              new_acc = %{acc | content: new_content}
              {{:text_delta, idx, text, new_acc}, new_acc}

            "thinking_delta" ->
              thinking = delta["thinking"]

              new_content =
                update_content(acc.content, idx, fn block ->
                  %{block | thinking: (block[:thinking] || "") <> thinking}
                end)

              new_acc = %{acc | content: new_content}
              {{:thinking_delta, idx, thinking, new_acc}, new_acc}

            "input_json_delta" ->
              partial_json = delta["partial_json"]
              # For tool call, we accumulate JSON
              new_content =
                update_content(acc.content, idx, fn block ->
                  %{block | partial_json: (block[:partial_json] || "") <> partial_json}
                end)

              new_acc = %{acc | content: new_content}
              {{:toolcall_delta, idx, partial_json, new_acc}, new_acc}

            "signature_delta" ->
              signature = delta["signature"]

              new_content =
                update_content(acc.content, idx, fn block ->
                  Map.put(
                    block,
                    :thinking_signature,
                    (block[:thinking_signature] || "") <> signature
                  )
                end)

              new_acc = %{acc | content: new_content}
              {nil, new_acc}

            _ ->
              {nil, acc}
          end

        %{"type" => "content_block_stop", "index" => idx} ->
          # Finalize block
          block = Enum.at(acc.content, idx)

          if block do
            case block.type do
              :text ->
                {{:text_end, idx, block.text, acc}, acc}

              :thinking ->
                final_block = %{
                  type: :thinking,
                  thinking: block.thinking,
                  thinking_signature: block[:thinking_signature]
                }

                new_content = List.replace_at(acc.content, idx, final_block)
                new_acc = %{acc | content: new_content}
                {{:thinking_end, idx, block.thinking, new_acc}, new_acc}

              :tool_call ->
                # Parse JSON
                args =
                  case Jason.decode(block.partial_json) do
                    {:ok, decoded} -> decoded
                    _ -> %{}
                  end

                tool_call = %{type: :tool_call, id: block.id, name: block.name, arguments: args}
                new_content = List.replace_at(acc.content, idx, tool_call)
                new_acc = %{acc | content: new_content}
                {{:toolcall_end, idx, tool_call, new_acc}, new_acc}

              _ ->
                {nil, acc}
            end
          else
            {nil, acc}
          end

        %{"type" => "message_delta", "delta" => delta, "usage" => usage} ->
          stop_reason =
            case delta["stop_reason"] do
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

        _ ->
          {nil, acc}
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
