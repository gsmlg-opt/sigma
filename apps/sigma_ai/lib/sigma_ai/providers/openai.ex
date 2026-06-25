defmodule Sigma.Ai.Providers.OpenAI do
  @behaviour Sigma.Ai.Provider

  alias Sigma.Ai.{ProviderAuth, Stream}

  @impl true
  def stream(params) do
    model = params.model
    context = params.context
    options = params.options
    session_id = Map.get(params, :session_id)

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
      stream: true,
      stream_options: %{include_usage: true}
    }

    body =
      case output_token_limit(model, options) do
        nil -> body
        limit -> Map.put(body, :max_tokens, limit)
      end

    # Add tools if present
    body =
      if context[:tools], do: Map.put(body, :tools, transform_tools(context.tools)), else: body

    headers =
      [
        ProviderAuth.headers(api_key, options, "bearer"),
        {"Content-Type", "application/json"}
      ]
      |> List.flatten()

    inner = build_inner_stream(model, body, headers, base_url, options, session_id)

    Elixir.Stream.transform(
      inner,
      fn ->
        System.monotonic_time()
      end,
      fn event, start_time ->
        case event do
          {:done, _stop_reason, ai_msg} ->
            :telemetry.execute(
              [:sigma, :llm, :request, :stop],
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

  defp build_inner_stream(model, body, headers, base_url, options, session_id) do
    Elixir.Stream.resource(
      fn ->
        :telemetry.execute(
          [:sigma, :llm, :request, :start],
          %{system_time: System.system_time()},
          %{
            session_id: session_id,
            model: model.id,
            provider: "openai",
            request_body: body
          }
        )

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
        if resp.status >= 400 do
          handle_error_chunks(resp, chunks, message, buffer)
        else
          handle_stream_chunks(chunks, message, buffer)
        end

      {:error, %{reason: reason}} ->
        raise transport_error_message(%{reason: reason})

      :unknown ->
        {[], message, buffer, :streaming}
    end
  end

  defp handle_stream_chunks(chunks, message, buffer) do
    Enum.reduce(chunks, {[], message, buffer, :streaming}, fn
      {:data, _chunk}, {acc_events, acc_message, acc_buffer, :done} ->
        {acc_events, acc_message, acc_buffer, :done}

      {:data, chunk}, {acc_events, acc_message, acc_buffer, _status} ->
        {events, new_buffer} = Stream.decode(acc_buffer, chunk)
        {processed_events, new_message} = process_events(events, acc_message)

        status =
          if Enum.any?(processed_events, &match?({:done, _, _}, &1)),
            do: :done,
            else: :streaming

        {acc_events ++ processed_events, new_message, new_buffer, status}

      :done, {acc_events, acc_message, acc_buffer, :done} ->
        {acc_events, acc_message, acc_buffer, :done}

      :done, {acc_events, acc_message, acc_buffer, _status} ->
        {processed_events, new_message} = process_events([:done], acc_message)
        {acc_events ++ processed_events, new_message, acc_buffer, :done}

      _chunk, acc ->
        acc
    end)
  end

  defp handle_error_chunks(resp, chunks, message, buffer) do
    Enum.reduce(chunks, {[], message, buffer, :streaming}, fn
      {:data, chunk}, {acc_events, acc_message, acc_buffer, _status} ->
        {acc_events, acc_message, acc_buffer <> chunk, :streaming}

      :done, {_acc_events, _acc_message, acc_buffer, _status} ->
        raise http_error_message(resp.status, acc_buffer)

      _chunk, acc ->
        acc
    end)
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
        transform_assistant_message(content)

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

  defp transform_assistant_message(content) when is_list(content) do
    tool_calls = content |> Enum.filter(&tool_call_block?/1) |> Enum.map(&transform_tool_call/1)

    if tool_calls == [] do
      %{role: "assistant", content: transform_content(content)}
    else
      %{
        role: "assistant",
        content: transform_assistant_content_without_tools(content),
        tool_calls: tool_calls
      }
    end
  end

  defp transform_assistant_message(content), do: %{role: "assistant", content: content}

  defp transform_assistant_content_without_tools(content) do
    case Enum.reject(content, &tool_call_block?/1) do
      [] -> nil
      blocks -> transform_content(blocks)
    end
  end

  defp transform_content(content) do
    Enum.map(content, fn
      %{type: :text, text: text} ->
        %{type: "text", text: text}

      %{type: :thinking, thinking: thinking} ->
        %{type: "thinking", thinking: thinking}

      %{type: :tool_call} = tc ->
        transform_tool_call(tc)
    end)
  end

  defp tool_call_block?(%{type: :tool_call, arguments: args}) when is_map(args), do: true
  defp tool_call_block?(_block), do: false

  defp transform_tool_call(tc) do
    %{
      id: tc.id,
      type: "function",
      function: %{name: tc.name, arguments: Jason.encode!(tc.arguments)}
    }
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

  defp output_token_limit(model, options) do
    positive_integer(options[:max_tokens]) ||
      positive_integer(options[:maxTokens]) ||
      model_max_tokens(model)
  end

  defp model_max_tokens(model) when is_map(model) do
    [
      :max_tokens,
      "max_tokens",
      :maxTokens,
      "maxTokens",
      :output_token_limit,
      "output_token_limit",
      :outputTokenLimit,
      "outputTokenLimit"
    ]
    |> Enum.find_value(fn key -> positive_integer(Map.get(model, key)) end)
  end

  defp model_max_tokens(_model), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> number
      _ -> nil
    end
  end

  defp positive_integer(_value), do: nil

  defp process_events(events, message) do
    Enum.map_reduce(events, message, fn event, acc ->
      case event do
        %{"error" => error} ->
          raise provider_error_message(error)

        :done ->
          {tool_call_events, acc} = finalize_pending_tool_call_events(acc)
          stop_reason = if tool_call_events == [], do: acc.stop_reason || :stop, else: :tool_use
          acc = %{acc | stop_reason: stop_reason}

          {tool_call_events ++ [{:done, stop_reason, acc}], acc}

        %{"choices" => choices} when choices != [] ->
          choice = Enum.at(choices, 0)
          index = choice["index"]
          delta = choice["delta"]
          finish_reason = choice["finish_reason"]

          acc =
            if finish_reason,
              do: %{acc | stop_reason: transform_stop_reason(finish_reason)},
              else: acc

          {events, acc} =
            cond do
              is_binary(delta["content"]) ->
                process_text_delta(acc, index, delta["content"])

              is_list(delta["tool_calls"]) ->
                process_tool_call_deltas(acc, delta["tool_calls"])

              true ->
                {[], acc}
            end

          case finish_reason do
            "tool_calls" -> append_final_tool_call_events(events, acc)
            _ -> {events, acc}
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

  defp process_text_delta(acc, index, text) do
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
  end

  defp process_tool_call_deltas(acc, tool_call_deltas) do
    Enum.map_reduce(tool_call_deltas, acc, &process_tool_call_delta/2)
    |> then(fn {events, acc} -> {List.flatten(events), acc} end)
  end

  defp process_tool_call_delta(delta, acc) do
    provider_index = delta["index"] || 0
    function = delta["function"] || %{}

    {index, acc, start_event} = ensure_tool_call_block(acc, provider_index, delta, function)

    new_content =
      update_content(acc.content, index, fn block ->
        block
        |> maybe_put_present(:id, delta["id"])
        |> maybe_put_present(:name, function["name"])
        |> Map.update(
          :partial_json,
          function["arguments"] || "",
          &(&1 <> (function["arguments"] || ""))
        )
      end)

    new_acc = %{acc | content: new_content}

    delta_event =
      case function["arguments"] do
        arguments when is_binary(arguments) -> {:toolcall_delta, index, arguments, new_acc}
        _ -> nil
      end

    {[start_event, delta_event] |> Enum.reject(&is_nil/1), new_acc}
  end

  defp ensure_tool_call_block(acc, provider_index, delta, function) do
    case tool_call_content_index(acc.content, provider_index) do
      nil ->
        index = length(acc.content)

        block = %{
          type: :tool_call,
          id: delta["id"],
          name: function["name"],
          partial_json: "",
          provider_index: provider_index
        }

        new_content = acc.content ++ [block]
        new_acc = %{acc | content: new_content}
        {index, new_acc, {:toolcall_start, index, new_acc}}

      index ->
        {index, acc, nil}
    end
  end

  defp tool_call_content_index(content, provider_index) do
    Enum.find_index(content, fn
      %{type: :tool_call, provider_index: ^provider_index} -> true
      _ -> false
    end)
  end

  defp append_final_tool_call_events(events, acc) do
    {end_events, acc} = finalize_pending_tool_call_events(acc)
    {events ++ end_events, acc}
  end

  defp finalize_pending_tool_call_events(acc) do
    acc.content
    |> Enum.with_index()
    |> Enum.map_reduce(acc, fn {block, index}, current_acc ->
      finalize_tool_call_block(current_acc, block, index)
    end)
    |> then(fn {events, acc} -> {Enum.reject(events, &is_nil/1), acc} end)
  end

  defp finalize_tool_call_block(
         acc,
         %{type: :tool_call, partial_json: partial_json} = block,
         index
       ) do
    args =
      case Jason.decode(partial_json || "") do
        {:ok, decoded} when is_map(decoded) -> decoded
        _ -> %{}
      end

    tool_call = %{
      type: :tool_call,
      id: block.id,
      name: block.name,
      arguments: args
    }

    new_content = List.replace_at(acc.content, index, tool_call)
    new_acc = %{acc | content: new_content}
    {{:toolcall_end, index, tool_call, new_acc}, new_acc}
  end

  defp finalize_tool_call_block(acc, _block, _index), do: {nil, acc}

  defp maybe_put_present(map, _key, nil), do: map
  defp maybe_put_present(map, _key, ""), do: map
  defp maybe_put_present(map, key, value), do: Map.put(map, key, value)

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

  defp http_error_message(status, body) do
    case Jason.decode(body) do
      {:ok, %{"error" => error}} ->
        provider_error_message(error)

      {:ok, error} ->
        provider_error_message(error)

      {:error, _} ->
        "AI provider HTTP #{status}: #{String.slice(String.trim(body), 0, 500)}"
    end
  end
end
