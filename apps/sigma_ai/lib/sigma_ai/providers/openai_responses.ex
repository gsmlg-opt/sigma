defmodule Sigma.Ai.Providers.OpenAIResponses do
  @behaviour Sigma.Ai.Provider

  alias Backplane.AiProtocol.{Request, Serialization, SSE}
  alias Sigma.Ai.{
    ProviderAuth,
    ProviderCapabilities,
    ProviderError,
    ProviderRequest,
    ToolCallJson
  }

  @impl true
  def stream_normalized(%ProviderRequest{} = request),
    do: stream(ProviderRequest.to_legacy(request))

  @impl true
  def capabilities(model) do
    %ProviderCapabilities{
      tools: true,
      thinking: true,
      image_input: true,
      context_window: model[:context_window] || model["contextWindow"],
      max_output_tokens: model[:max_tokens] || model["maxTokens"],
      supported_options: [:max_tokens, :reasoning_effort]
    }
  end

  @impl true
  def stream(params) do
    model = params.model
    context = params.context
    options = params.options
    session_id = Map.get(params, :session_id)
    log_session_id = Map.get(params, :log_session_id, session_id)

    api_key =
      options[:api_key] || System.get_env("OPENAI_API_KEY") ||
        System.get_env("OPENROUTER_API_KEY")

    base_url =
      options[:base_url] || System.get_env("OPENAI_BASE_URL") || "https://api.openai.com/v1"

    body = %{
      model: model.id,
      input:
        context.messages
        |> transform_messages()
        |> prepend_system_message(context[:system] || context[:system_prompt]),
      stream: true,
      store: false
    }

    body =
      case output_token_limit(model, options) do
        nil -> body
        limit -> Map.put(body, :max_output_tokens, limit)
      end

    # Add tools if present
    body =
      if context[:tools], do: Map.put(body, :tools, transform_tools(context.tools)), else: body

    case protocol_request(model, context) do
      {:ok, _request} ->
        :ok

      {:error, error} ->
        raise ProviderError,
          kind: :invalid_request,
          message: "Invalid AI protocol request: #{error.message}",
          retryable: false
    end

    headers =
      [
        ProviderAuth.headers(api_key, options, "bearer"),
        {"Content-Type", "application/json"}
      ]
      |> List.flatten()

    inner =
      build_inner_stream(model, body, headers, base_url, options, session_id, log_session_id)

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
                log_session_id: log_session_id,
                model: model.id,
                usage: ai_msg.usage,
                stop_reason: ai_msg.stop_reason
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

  defp build_inner_stream(model, body, headers, base_url, options, session_id, log_session_id) do
    Elixir.Stream.resource(
      fn ->
        :telemetry.execute(
          [:sigma, :llm, :request, :start],
          %{system_time: System.system_time()},
          %{
            session_id: session_id,
            log_session_id: log_session_id,
            model: model.id,
            provider: "openai-responses"
          }
        )

        resp =
          try do
            {:ok, encoded_body} = Serialization.to_json(body)

            Req.post!(base_url <> "/responses",
              body: encoded_body,
              headers: headers,
              receive_timeout: options[:receive_timeout] || 120_000,
              into: :self
            )
          rescue
            e in [Req.TransportError, Finch.TransportError] ->
              reraise transport_error_message(e), __STACKTRACE__
          end

        {_initial_assistant_message(model),
         %{
           framer: SSE.new(max_frame_bytes: 16 * 1024 * 1024, max_buffer_bytes: 32 * 1024 * 1024),
           observer: Backplane.AiProtocol.OpenAIResponsesObserver.new(),
           error_body: ""
         }, :streaming, resp}
      end,
      fn
        {message, _state, :done, resp} ->
          {:halt, {message, %{}, :done, resp}}

        {message, state, :streaming, resp} ->
          cancellation_ref = options[:cancellation_ref]

          receive do
            {:cancel, ^cancellation_ref} when not is_nil(cancellation_ref) ->
              Req.cancel_async_response(resp)
              error = ProviderError.from_reason(:cancelled)
              {[{:provider_error, error}], {message, state, :done, resp}}

            req_message ->
              {processed_events, new_message, new_state, status} =
                handle_async_message(resp, req_message, message, state)

              {processed_events, {new_message, new_state, status, resp}}
          after
            options[:receive_timeout] || 120_000 ->
              Req.cancel_async_response(resp)
              raise transport_error_message(%{reason: :timeout})
          end
      end,
      fn
        {_message, _state, :streaming, resp} -> Req.cancel_async_response(resp)
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

  defp handle_async_message(resp, req_message, message, state) do
    case Req.parse_message(resp, req_message) do
      {:ok, chunks} ->
        if resp.status >= 400 do
          handle_error_chunks(resp, chunks, message, state)
        else
          handle_stream_chunks(chunks, message, state)
        end

      {:error, %{reason: reason}} ->
        raise transport_error_message(%{reason: reason})

      :unknown ->
        {[], message, state, :streaming}
    end
  end

  defp handle_stream_chunks(chunks, message, state) do
    Enum.reduce(chunks, {[], message, state, :streaming}, fn
      {:data, _chunk}, {acc_events, acc_message, acc_state, :done} ->
        {acc_events, acc_message, acc_state, :done}

      {:data, chunk}, {acc_events, acc_message, acc_state, _status} ->
        observer = Backplane.AiProtocol.OpenAIResponsesObserver.feed(acc_state.observer, chunk)

        case SSE.feed(acc_state.framer, chunk) do
          {:ok, framer, frames} ->
            events = decode_frames(frames)
            {processed_events, new_message} = process_events(events, acc_message)

            status =
              if Enum.any?(processed_events, &match?({:done, _, _}, &1)) or
                   Enum.any?(processed_events, &match?({:provider_error, _}, &1)),
                do: :done,
                else: :streaming

            observer =
              if status == :done,
                do: Backplane.AiProtocol.OpenAIResponsesObserver.finish(observer, :eof),
                else: observer

            {acc_events ++ processed_events, new_message,
             %{framer: framer, observer: observer, error_body: acc_state.error_body}, status}

          {:error, _error, framer} ->
            error = ProviderError.malformed(:invalid_sse)

            {acc_events ++ [{:provider_error, error}], acc_message,
             %{framer: framer, observer: observer, error_body: acc_state.error_body}, :done}
        end

      :done, {acc_events, acc_message, acc_state, :done} ->
        {acc_events, acc_message, acc_state, :done}

      :done, {acc_events, acc_message, acc_state, _status} ->
        observer = Backplane.AiProtocol.OpenAIResponsesObserver.finish(acc_state.observer, :eof)

        case SSE.finish(acc_state.framer) do
          {:ok, framer, frames} ->
            events = decode_frames(frames)
            {processed_events, new_message} = process_events(events, acc_message)

            cond do
              Enum.any?(processed_events, &match?({:done, _, _}, &1)) or
                  Enum.any?(processed_events, &match?({:provider_error, _}, &1)) ->
                {acc_events ++ processed_events, new_message,
                 %{framer: framer, observer: observer, error_body: acc_state.error_body}, :done}

              can_recover_eof?(new_message) ->
                {recovery_events, recovered_message} = complete_response(new_message, %{})

                {acc_events ++ processed_events ++ recovery_events, recovered_message,
                 %{framer: framer, observer: observer, error_body: acc_state.error_body}, :done}

              true ->
                error = ProviderError.malformed(:truncated_stream)

                {acc_events ++ processed_events ++ [{:provider_error, error}], new_message,
                 %{framer: framer, observer: observer, error_body: acc_state.error_body}, :done}
            end

          {:error, _error, framer} ->
            if can_recover_eof?(acc_message) do
              {recovery_events, recovered_message} = complete_response(acc_message, %{})

              {acc_events ++ recovery_events, recovered_message,
               %{framer: framer, observer: observer, error_body: acc_state.error_body}, :done}
            else
              error = ProviderError.malformed(:truncated_stream)

              {acc_events ++ [{:provider_error, error}], acc_message,
               %{framer: framer, observer: acc_state.observer, error_body: acc_state.error_body},
               :done}
            end
        end

      _chunk, acc ->
        acc
    end)
  end

  defp handle_error_chunks(resp, chunks, message, state) do
    Enum.reduce(chunks, {[], message, state, :streaming}, fn
      {:data, chunk}, {acc_events, acc_message, acc_state, _status} ->
        {acc_events, acc_message, %{acc_state | error_body: acc_state.error_body <> chunk},
         :streaming}

      :done, {_acc_events, _acc_message, acc_state, _status} ->
        raise http_provider_error(resp.status, acc_state.error_body, resp.headers)

      _chunk, acc ->
        acc
    end)
  end

  defp decode_frames(frames) do
    Enum.flat_map(frames, fn
      %{data: "[DONE]"} ->
        [:done]

      %{data: data} ->
        case Serialization.from_json(data, max_encoded_bytes: 16 * 1024 * 1024) do
          {:ok, event} when is_map(event) -> [event]
          _ -> [{:provider_error, ProviderError.malformed(:invalid_event_json)}]
        end
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
    Enum.flat_map(messages, fn
      %{role: :user, content: content} ->
        [%{role: "user", content: transform_responses_content(content, "input_text")}]

      %{role: :assistant, content: content} ->
        transform_assistant_responses_items(content)

      %{role: :tool_result, tool_call_id: id, content: content} ->
        [
          %{
            type: "function_call_output",
            call_id: id,
            output: transform_tool_result_content(content)
          }
        ]
    end)
  end

  defp transform_responses_content(content, _text_type) when is_binary(content),
    do: [%{type: "input_text", text: content}]

  defp transform_responses_content(content, text_type) when is_list(content) do
    Enum.map(content, fn
      %{type: :text, text: text} ->
        %{type: text_type, text: text}

      %{type: :image, data: data, mime_type: mime} ->
        %{type: "input_image", image_url: "data:#{mime};base64,#{data}"}

      block ->
        block
    end)
  end

  defp transform_responses_content(content, _text_type), do: content

  defp transform_assistant_responses_items(content) when is_list(content) do
    Enum.flat_map(content, fn
      %{type: :text, text: text} ->
        [%{type: "message", role: "assistant", content: [%{type: "output_text", text: text}]}]

      %{type: :tool_call, id: id, name: name, arguments: arguments} ->
        [%{type: "function_call", call_id: id, name: name, arguments: Jason.encode!(arguments)}]

      _ ->
        []
    end)
  end

  defp transform_assistant_responses_items(content),
    do: [%{type: "message", role: "assistant", content: [%{type: "output_text", text: content}]}]

  defp transform_tool_result_content(content) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{type: :text, text: text} -> text
      _ -> ""
    end)
  end

  defp transform_tool_result_content(content), do: content

  defp transform_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        type: "function",
        name: tool.name,
        description: tool.description,
        parameters: tool.parameters,
        strict: false
      }
    end)
  end

  # Validate the provider-neutral request before the provider-specific wire projection is sent.
  # The protocol package deliberately does not own HTTP transport or provider credentials.
  defp protocol_request(model, context) do
    input =
      [protocol_system_message(context[:system] || context[:system_prompt]) | context.messages]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&protocol_message/1)

    attrs = %{
      model: model.id,
      input: input,
      tools: Enum.map(context[:tools] || [], &protocol_tool/1),
      settings: %{}
    }

    Request.new(attrs)
  end

  defp protocol_system_message(system) do
    case system_text(system) do
      nil -> nil
      text -> %{role: :system, content: [%{type: :text, text: text}]}
    end
  end

  defp protocol_message(%{role: :user, content: content}),
    do: %{role: :user, content: protocol_content(content)}

  defp protocol_message(%{role: :system, content: content}),
    do: %{role: :system, content: protocol_content(content)}

  defp protocol_message(%{role: :assistant, content: content}),
    do: %{role: :assistant, content: protocol_content(content)}

  defp protocol_message(%{role: :tool_result, tool_call_id: id, content: content}) do
    # A silent tool still has a result; the canonical protocol represents its
    # empty output with no content blocks, while the wire output remains "".
    blocks =
      content
      |> protocol_content()
      |> Enum.reject(&match?(%{type: :text, text: ""}, &1))

    %{role: :tool, tool_call_id: id, content: blocks}
  end

  defp protocol_message(_message), do: %{role: :invalid, content: []}

  defp protocol_content(content) when is_binary(content),
    do: [%{type: :text, text: content}]

  defp protocol_content(content) when is_list(content),
    do: Enum.map(content, &protocol_block/1)

  defp protocol_content(_content), do: [%{type: :invalid}]

  defp protocol_block(%{type: :text, text: text}),
    do: %{type: :text, text: text}

  defp protocol_block(%{type: :image, data: data, mime_type: mime}),
    do: %{type: :image, data: %{data: data, mime_type: mime}}

  defp protocol_block(%{type: :thinking, thinking: thinking}),
    do: %{type: :reasoning, data: %{text: thinking}}

  defp protocol_block(%{type: :tool_call, id: id, name: name, arguments: arguments}) do
    raw_arguments =
      if is_binary(arguments), do: {:json, arguments}, else: {:structured, arguments}

    %{
      type: :tool_call,
      tool_call: %{id: id, name: name, raw_arguments: raw_arguments}
    }
  end

  defp protocol_block(_block), do: %{type: :invalid}

  defp protocol_tool(tool) do
    %{
      name: tool.name,
      description: tool.description,
      input_schema: tool.parameters
    }
  end

  defp prepend_system_message(items, system) do
    case system_text(system) do
      nil -> items
      text -> [%{role: "system", content: [%{type: "input_text", text: text}]} | items]
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

  defp system_block_text(block) when is_map(block),
    do: Map.get(block, :text) || Map.get(block, "text") || ""

  defp system_block_text(_), do: ""

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
        %{"type" => type, "response" => response}
        when type in ["response.created", "response.in_progress"] ->
          {[], %{acc | response_id: acc.response_id || response["id"]}}

        %{"type" => "response.output_text.delta", "delta" => text} ->
          process_text_delta(acc, text)

        %{"type" => "response.output_text.done", "text" => text}
        when is_binary(text) and text != "" ->
          if is_nil(text_content_index(acc.content)),
            do: process_text_delta(acc, text),
            else: {[], acc}

        %{"type" => "response.reasoning_text.delta", "delta" => text} ->
          process_thinking_delta(acc, text)

        %{"type" => "response.reasoning_summary_text.delta", "delta" => text} ->
          process_thinking_delta(acc, text)

        %{"type" => "response.output_item.added", "item" => %{"type" => "function_call"} = item} ->
          start_response_tool(acc, item)

        %{
          "type" => "response.function_call_arguments.delta",
          "delta" => delta
        } = event
        when is_binary(delta) ->
          process_response_tool_delta(acc, event["item_id"], event["call_id"], delta)

        %{
          "type" => "response.function_call_arguments.done",
          "arguments" => arguments
        } = event ->
          update_response_tool_arguments(acc, event, arguments)

        %{"type" => "response.output_item.done", "item" => %{"type" => "function_call"} = item} ->
          finalize_response_tool(acc, item)

        %{"type" => "response.output_item.done", "item" => %{"type" => "message"} = item} ->
          maybe_process_message_item_done(acc, item)

        %{"type" => type, "response" => response}
        when type in ["response.completed", "response.incomplete", "response.done"] ->
          if is_nil(acc.stop_reason) do
            complete_response(acc, response)
          else
            {[], acc}
          end

        :done ->
          if is_nil(acc.stop_reason) and (acc.content != [] or not is_nil(acc.response_id)) do
            complete_response(acc, %{})
          else
            {[], acc}
          end

        %{"type" => "response.failed", "response" => response} ->
          raise provider_error_message(response["error"] || response)

        %{"type" => "error"} = error ->
          raise provider_error_message(error)

        _ ->
          {[], acc}
      end
    end)
    |> then(fn {events, acc} -> {List.flatten(events), acc} end)
  end

  defp complete_response(acc, response) do
    {text_events, acc} = maybe_extract_response_output_text(acc, response)
    {tool_events, acc} = finalize_response_tools(acc, response)

    usage =
      case response do
        %{"usage" => usage_map} when is_map(usage_map) -> response_usage(usage_map)
        _ -> acc.usage
      end

    acc = %{
      acc
      | response_id: acc.response_id || response["id"],
        usage: usage,
        stop_reason: response_stop_reason(response, acc)
    }

    if Enum.any?(tool_events, &match?({:provider_error, _}, &1)) do
      {text_events ++ tool_events, acc}
    else
      {text_events ++ tool_events ++ [{:done, acc.stop_reason, acc}], acc}
    end
  end

  defp maybe_process_message_item_done(acc, %{"content" => content}) when is_list(content) do
    if is_nil(text_content_index(acc.content)) do
      text =
        content
        |> Enum.map(fn
          %{"type" => type, "text" => part}
          when type in ["output_text", "text"] and is_binary(part) ->
            part

          _ ->
            ""
        end)
        |> Enum.join("")

      if text != "", do: process_text_delta(acc, text), else: {[], acc}
    else
      {[], acc}
    end
  end

  defp maybe_process_message_item_done(acc, _item), do: {[], acc}

  defp maybe_extract_response_output_text(acc, %{"output" => items}) when is_list(items) do
    if is_nil(text_content_index(acc.content)) do
      Enum.reduce(items, {[], acc}, fn
        %{"type" => "message"} = item, {events, current_acc} ->
          {new_events, new_acc} = maybe_process_message_item_done(current_acc, item)
          {events ++ new_events, new_acc}

        _, state ->
          state
      end)
    else
      {[], acc}
    end
  end

  defp maybe_extract_response_output_text(acc, _response), do: {[], acc}

  defp can_recover_eof?(%{content: content}) when is_list(content) and content != [] do
    Enum.all?(content, fn
      %{type: :tool_call} = block ->
        not Map.has_key?(block, :partial_json) or Map.has_key?(block, :arguments)

      %{type: :text, text: text} ->
        is_binary(text) and text != ""

      %{type: :thinking, thinking: thinking} ->
        is_binary(thinking) and thinking != ""

      _ ->
        true
    end)
  end

  defp can_recover_eof?(_message), do: false

  defp process_thinking_delta(acc, text) do
    index = Enum.find_index(acc.content, &(&1[:type] == :thinking)) || length(acc.content)

    content =
      if index == length(acc.content),
        do: acc.content ++ [%{type: :thinking, thinking: ""}],
        else: acc.content

    content =
      update_content(content, index, fn block ->
        Map.update(block, :thinking, text, &(&1 <> text))
      end)

    msg = %{acc | content: content}
    {[{:thinking_delta, index, text, msg}], msg}
  end

  defp start_response_tool(acc, item) do
    item_id = present_string(item["id"])
    call_id = present_string(item["call_id"])
    name = present_string(item["name"])
    initial_args = if is_binary(item["arguments"]), do: item["arguments"], else: ""

    case response_tool_index(acc.content, item_id, call_id) do
      nil ->
        index = length(acc.content)

        block = %{
          type: :tool_call,
          item_id: item_id,
          id: call_id,
          name: name,
          partial_json: initial_args
        }

        new_acc = %{acc | content: acc.content ++ [block]}
        {[{:toolcall_start, index, new_acc}], new_acc}

      index ->
        content =
          update_content(acc.content, index, fn block ->
            block
            |> Map.put(:item_id, present_string(block[:item_id]) || item_id)
            |> Map.put(:id, present_string(block[:id]) || call_id)
            |> Map.put(:name, present_string(block[:name]) || name)
          end)

        {[], %{acc | content: content}}
    end
  end

  defp process_response_tool_delta(acc, item_id, call_id, delta) do
    item_id = present_string(item_id)
    call_id = present_string(call_id)
    index = response_tool_index(acc.content, item_id, call_id) || length(acc.content)

    content =
      if index == length(acc.content),
        do:
          acc.content ++
            [%{type: :tool_call, item_id: item_id, id: call_id, name: nil, partial_json: ""}],
        else: acc.content

    content =
      update_content(content, index, fn block ->
        Map.update(block, :partial_json, delta, &(&1 <> delta))
      end)

    msg = %{acc | content: content}
    {[{:toolcall_delta, index, delta, msg}], msg}
  end

  defp update_response_tool_arguments(acc, event, arguments) do
    item_id = present_string(event["item_id"])
    call_id = present_string(event["call_id"])
    name = present_string(event["name"])
    index = response_tool_index(acc.content, item_id, call_id) || length(acc.content)

    content =
      if index == length(acc.content),
        do:
          acc.content ++
            [%{type: :tool_call, item_id: item_id, id: call_id, name: name, partial_json: ""}],
        else: acc.content

    block = Enum.at(content, index)

    updated =
      block
      |> Map.put(:item_id, present_string(block[:item_id]) || item_id)
      |> Map.put(:id, present_string(block[:id]) || call_id)
      |> Map.put(:name, present_string(block[:name]) || name)
      |> maybe_put_arguments(arguments)

    content = List.replace_at(content, index, updated)

    {[], %{acc | content: content}}
  end

  defp maybe_put_arguments(block, arguments) when is_map(arguments),
    do: Map.put(block, :arguments, arguments)

  defp maybe_put_arguments(block, arguments) when is_binary(arguments) do
    case present_string(arguments) do
      nil -> block
      present -> Map.put(block, :arguments, present)
    end
  end

  defp maybe_put_arguments(block, _arguments), do: block

  defp finalize_response_tool(acc, item) do
    item_id = present_string(item["id"])
    call_id = present_string(item["call_id"])
    index = response_tool_index(acc.content, item_id, call_id) || length(acc.content)
    block = Enum.at(acc.content, index) || %{}

    if block[:type] == :tool_call and not Map.has_key?(block, :partial_json) and
         is_map(block[:arguments]) do
      {[], acc}
    else
      arguments =
        present_arguments(item["arguments"]) ||
          present_arguments(block[:arguments]) ||
          present_arguments(block[:partial_json]) ||
          "{}"

      name = present_string(item["name"]) || present_string(block[:name])

      call_id =
        call_id || present_string(block[:id]) || item_id || present_string(block[:item_id])

      with {:ok, arguments} <- decode_arguments(arguments),
           true <- is_binary(call_id) and call_id != "",
           true <- is_binary(name) and name != "" do
        call = %{type: :tool_call, id: call_id, name: name, arguments: arguments}

        content =
          if index == length(acc.content),
            do: acc.content ++ [call],
            else: List.replace_at(acc.content, index, call)

        msg = %{acc | content: content}
        {[{:toolcall_end, index, call, msg}], msg}
      else
        _ -> {[{:provider_error, ProviderError.malformed(:invalid_tool_call_arguments)}], acc}
      end
    end
  end

  defp finalize_response_tools(acc, response) do
    output_items =
      case response do
        %{"output" => items} when is_list(items) ->
          Enum.filter(items, &match?(%{"type" => "function_call"}, &1))

        _ ->
          []
      end

    {output_events, acc} =
      Enum.reduce(output_items, {[], acc}, fn item, {events, current_acc} ->
        item_id = present_string(item["id"])
        call_id = present_string(item["call_id"])

        case response_tool_index(current_acc.content, item_id, call_id) do
          nil ->
            {new_events, new_acc} = finalize_response_tool(current_acc, item)
            {events ++ new_events, new_acc}

          index ->
            block = Enum.at(current_acc.content, index)

            if Map.has_key?(block, :partial_json) do
              {new_events, new_acc} = finalize_response_tool(current_acc, item)
              {events ++ new_events, new_acc}
            else
              {events, current_acc}
            end
        end
      end)

    acc.content
    |> Enum.reduce({output_events, acc}, fn block, {events, current_acc} ->
      if block[:type] == :tool_call and Map.has_key?(block, :partial_json) do
        {new_events, new_acc} =
          finalize_response_tool(current_acc, %{
            "id" => block[:item_id],
            "call_id" => block[:id],
            "name" => block[:name],
            "arguments" =>
              present_arguments(block[:arguments]) || present_arguments(block[:partial_json])
          })

        {events ++ new_events, new_acc}
      else
        {events, current_acc}
      end
    end)
  end

  defp response_tool_index(content, item_id, call_id) do
    present_item_id = present_string(item_id)
    present_call_id = present_string(call_id)

    cond do
      present_item_id != nil or present_call_id != nil ->
        Enum.find_index(content, fn block ->
          block[:type] == :tool_call and
            ((present_item_id != nil and
                (block[:item_id] == present_item_id or block[:id] == present_item_id)) or
               (present_call_id != nil and block[:id] == present_call_id))
        end)

      true ->
        content
        |> Enum.with_index()
        |> Enum.reverse()
        |> Enum.find_value(fn {block, idx} ->
          if block[:type] == :tool_call and Map.has_key?(block, :partial_json), do: idx
        end)
    end
  end

  defp present_arguments(value) when is_map(value), do: value
  defp present_arguments(value) when is_binary(value), do: present_string(value)
  defp present_arguments(_value), do: nil

  defp present_string(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp present_string(_value), do: nil

  defp decode_arguments(arguments), do: ToolCallJson.decode_arguments(arguments)

  defp response_usage(nil), do: acc_usage_empty()

  defp response_usage(usage) do
    input = usage["input_tokens"] || 0
    output = usage["output_tokens"] || 0
    cached = get_in(usage, ["input_token_details", "cached_tokens"]) || 0

    %{
      input: input - cached,
      output: output,
      cache_read: cached,
      cache_write: 0,
      total_tokens: input + output,
      cost: %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0, total: 0.0}
    }
  end

  defp acc_usage_empty,
    do: %{
      input: 0,
      output: 0,
      cache_read: 0,
      cache_write: 0,
      total_tokens: 0,
      cost: %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0, total: 0.0}
    }

  defp response_stop_reason(%{"status" => "incomplete"}, _), do: :length
  defp response_stop_reason(%{"status" => "failed"}, _), do: :error

  defp response_stop_reason(_response, acc),
    do: if(Enum.any?(acc.content, &(&1[:type] == :tool_call)), do: :tool_use, else: :stop)

  defp update_content(content, idx, fun) do
    List.replace_at(content, idx, fun.(Enum.at(content, idx)))
  end

  defp process_text_delta(acc, text) do
    {acc, index, event_to_emit} =
      case text_content_index(acc.content) do
        nil ->
          index = length(acc.content)
          new_content = acc.content ++ [%{type: :text, text: ""}]
          new_acc = %{acc | content: new_content}
          {new_acc, index, {:text_start, index, new_acc}}

        index ->
          {acc, index, nil}
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

  defp text_content_index(content) do
    Enum.find_index(content, &match?(%{type: :text}, &1))
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

  defp http_provider_error(status, body, headers) do
    error =
      case Jason.decode(body) do
        {:ok, %{"error" => error}} -> error
        {:ok, error} -> error
        {:error, _reason} -> %{"message" => http_error_message(status, body)}
      end

    ProviderError.from_http(status, error, retry_after: retry_after(headers))
  end

  defp retry_after(headers) when is_map(headers),
    do: Map.get(headers, "retry-after") || Map.get(headers, "Retry-After")

  defp retry_after(headers) when is_list(headers) do
    Enum.find_value(headers, fn {name, value} ->
      if String.downcase(to_string(name)) == "retry-after", do: value
    end)
  end

  defp retry_after(_headers), do: nil
end
