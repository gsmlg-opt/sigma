defmodule Sigma.Ai.Providers.OpenAIResponses do
  @behaviour Sigma.Ai.Provider

  alias Backplane.AiProtocol.{Codec, Request, Serialization, SSE}

  alias Sigma.Ai.{
    ProviderAuth,
    ProviderCapabilities,
    ProviderError,
    ProviderRequest,
    ToolCallJson
  }

  alias Sigma.Ai.Providers.OpenAIResponses.Hosted

  alias Sigma.Ai.{ResponsesRecovery, ResponsesCancellation}

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
      supported_options: [
        :max_tokens,
        :reasoning_effort,
        :background,
        :responses_recovery,
        :responses_cancel
      ]
    }
  end

  @impl true
  def stream(params) do
    model = params.model
    context = params.context
    options = params.options
    _ = ResponsesRecovery.new(options)
    ResponsesCancellation.validate!(options)
    session_id = Map.get(params, :session_id)
    log_session_id = Map.get(params, :log_session_id, session_id)

    api_key =
      options[:api_key] || System.get_env("OPENAI_API_KEY") ||
        System.get_env("OPENROUTER_API_KEY")

    base_url =
      options[:base_url] || System.get_env("OPENAI_BASE_URL") || "https://api.openai.com/v1"

    hosted = Hosted.prepare!(model, context, options, base_url)
    native_transport? = native_tool_transport?(context) or hosted.enabled

    image_outputs =
      case protocol_request(model, Map.put(context, :tools, hosted.local_tools)) do
        {:ok, request} ->
          protocol_image_outputs!(request)

        {:error, error} ->
          raise ProviderError,
            kind: :invalid_request,
            message: "Invalid AI protocol request: #{error.message}",
            retryable: false
      end

    body = %{
      model: model.id,
      input:
        context.messages
        |> transform_messages(hosted, image_outputs)
        |> prepend_system_message(context[:system] || context[:system_prompt]),
      stream: true,
      store: false
    }

    body =
      case output_token_limit(model, options) do
        nil -> body
        limit -> Map.put(body, :max_output_tokens, limit)
      end

    body =
      if Keyword.has_key?(options, :background),
        do: Map.put(body, :background, options[:background]),
        else: body

    # Add tools if present
    body =
      if context[:tools],
        do: Map.put(body, :tools, transform_tools(hosted.local_tools) ++ hosted.hosted_tools),
        else: body

    headers =
      [
        ProviderAuth.headers(api_key, options, "bearer"),
        {"Content-Type", "application/json"}
      ]
      |> List.flatten()

    inner =
      build_inner_stream(
        model,
        body,
        headers,
        base_url,
        options,
        session_id,
        log_session_id,
        hosted,
        native_transport?
      )

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

  # Backplane supplies the catalog revision from its actual Runtime request.
  # Ordinary direct-provider function calls retain their existing compatibility
  # parser; native declarations and replay always use the public protocol codec.
  defp native_tool_transport?(context) do
    calls =
      for %{role: :assistant, content: blocks} <- context.messages,
          is_list(blocks),
          %{type: :tool_call} = call <- blocks,
          do: call

    Map.has_key?(context, :catalog_revision) or
      Enum.any?((context[:tools] || []) ++ calls, fn tool ->
        tool[:type] in [:custom, "custom"] or tool[:input_kind] == :custom or
          not is_nil(tool[:output_schema]) or
          (is_binary(tool[:name]) and String.contains?(tool.name, "::"))
      end)
  end

  defp build_inner_stream(
         model,
         body,
         headers,
         base_url,
         options,
         session_id,
         log_session_id,
         hosted,
         native_transport?
       ) do
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

        cancellation = ResponsesCancellation.register(options, base_url, headers)

        resp =
          try do
            {:ok, encoded_body} = Serialization.to_json(body)

            req_opts =
              [
                body: encoded_body,
                headers: headers,
                receive_timeout: options[:receive_timeout] || 120_000,
                retry: Sigma.Ai.CreationRequest.retry_policy(options),
                redirect: false,
                max_retries: Keyword.get(options, :max_retries, 3),
                into: :self
              ]
              |> maybe_put_opt(options, :retry_delay)
              |> maybe_put_opt(options, :retry_log_level)

            Req.post!(base_url <> "/responses", req_opts)
          rescue
            e in [Req.TransportError, Finch.TransportError, Req.HTTPError] ->
              reraise Sigma.Ai.CreationRequest.submission_error(e), __STACKTRACE__
          end

        {_initial_assistant_message(model),
         %{
           framer:
             SSE.new(
               Keyword.merge(
                 [max_frame_bytes: 16 * 1024 * 1024, max_buffer_bytes: 32 * 1024 * 1024],
                 Hosted.sse_options(hosted)
               )
             ),
           tool_codec:
             {if(native_transport?, do: Codec.stream_new(:openai_responses), else: :ordinary),
              Hosted.new(hosted)},
           observer: Backplane.AiProtocol.OpenAIResponsesObserver.new(),
           error_body: "",
           cancellation: cancellation,
           recovery: ResponsesRecovery.new(options)
         }, :streaming, resp}
      end,
      fn
        {message, state, :done, resp} ->
          {:halt, {message, state, :done, resp}}

        {message, state, :interrupted, resp} ->
          reconnect(message, state, resp, base_url, headers, options)

        {message, state, :streaming, resp} ->
          cancellation_ref = options[:cancellation_ref]

          receive do
            {:cancel, ^cancellation_ref} when not is_nil(cancellation_ref) ->
              ResponsesCancellation.request(state.cancellation)
              Req.cancel_async_response(resp)
              error = ResponsesCancellation.local_error(state.cancellation, state.recovery)
              {[{:provider_error, error}], {message, state, :done, resp}}

            req_message ->
              {processed_events, new_message, new_state, status} =
                handle_async_message(resp, req_message, message, state)

              {processed_events, {new_message, new_state, status, resp}}
          after
            options[:receive_timeout] || 120_000 ->
              Req.cancel_async_response(resp)

              if state.recovery do
                {[], {message, state, :interrupted, resp}}
              else
                raise Sigma.Ai.CreationRequest.interrupted(:timeout, message[:response_id])
              end
          end
      end,
      fn
        {_message, state, _status, resp} ->
          ResponsesCancellation.release(state.cancellation)
          Req.cancel_async_response(resp)
      end
    )
  end

  defp maybe_put_opt(opts, options, key) do
    case Keyword.fetch(options, key) do
      {:ok, val} -> Keyword.put(opts, key, val)
      :error -> opts
    end
  end

  defp handle_async_message(resp, req_message, message, state) do
    case Req.parse_message(resp, req_message) do
      {:ok, chunks} ->
        if resp.status >= 300 do
          handle_error_chunks(resp, chunks, message, state)
        else
          handle_stream_chunks(chunks, message, state)
        end

      {:error, %{reason: reason}} ->
        if state.recovery && resp.status < 300 do
          {[], message, state, :interrupted}
        else
          raise Sigma.Ai.CreationRequest.interrupted(reason, message[:response_id])
        end

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
            {processed_events, new_message, next_state} =
              process_frames(frames, acc_message, acc_state)

            status = if terminal_events?(processed_events), do: :done, else: :streaming

            observer =
              if status == :done,
                do: Backplane.AiProtocol.OpenAIResponsesObserver.finish(observer, :eof),
                else: observer

            {acc_events ++ processed_events, new_message,
             %{next_state | framer: framer, observer: observer}, status}

          {:error, _error, framer} ->
            error = stream_error(:invalid_sse, acc_message)

            {acc_events ++ [{:provider_error, error}], acc_message,
             %{acc_state | framer: framer, observer: observer}, :done}
        end

      :done, {acc_events, acc_message, acc_state, :done} ->
        {acc_events, acc_message, acc_state, :done}

      :done,
      {acc_events, acc_message, %{recovery: recovery, framer: %{buffer: buffer}} = acc_state,
       _status}
      when not is_nil(recovery) and buffer != "" ->
        # An unterminated frame is not an applied event. Replay it from the last
        # complete checkpoint rather than parsing a possibly cut JSON payload.
        {acc_events, acc_message, acc_state, :interrupted}

      :done, {acc_events, acc_message, acc_state, _status} ->
        observer = Backplane.AiProtocol.OpenAIResponsesObserver.finish(acc_state.observer, :eof)

        case SSE.finish(acc_state.framer) do
          {:ok, framer, frames} ->
            {processed_events, new_message, next_state} =
              process_frames(frames, acc_message, acc_state)

            state = %{next_state | framer: framer, observer: observer}

            cond do
              terminal_events?(processed_events) ->
                {acc_events ++ processed_events, new_message, state, :done}

              not is_nil(state.recovery) ->
                {acc_events ++ processed_events, new_message, state, :interrupted}

              true ->
                error = stream_error(:truncated_stream, new_message)

                {acc_events ++ processed_events ++ [{:provider_error, error}], new_message, state,
                 :done}
            end

          {:error, _error, framer} ->
            if acc_state.recovery do
              {acc_events, acc_message, %{acc_state | framer: framer, observer: observer},
               :interrupted}
            else
              error = stream_error(:invalid_sse, acc_message)

              {acc_events ++ [{:provider_error, error}], acc_message,
               %{acc_state | framer: framer, observer: observer}, :done}
            end
        end

      _chunk, acc ->
        acc
    end)
  end

  defp process_frames(frames, message, state) do
    Enum.reduce_while(decode_frames(frames), {[], message, state}, fn event,
                                                                      {all, message, state} ->
      case ResponsesRecovery.accept(state.recovery, event) do
        {:skip, _} ->
          {:cont, {all, message, state}}

        {:error, error} ->
          {:halt, {all ++ [{:provider_error, error}], message, state}}

        {:apply, checkpoint} ->
          ResponsesCancellation.observe(state.cancellation, event)
          {events, message, codec} = process_events([event], message, state.tool_codec)
          state = %{state | tool_codec: codec}

          state =
            if Enum.any?(events, &match?({:provider_error, _}, &1)),
              do: state,
              else: %{state | recovery: checkpoint}

          result = {all ++ events, message, state}
          if terminal_events?(events), do: {:halt, result}, else: {:cont, result}
      end
    end)
  end

  defp reconnect(message, state, resp, base_url, headers, options) do
    Req.cancel_async_response(resp)

    case ResponsesRecovery.next_attempt(state.recovery) do
      {:error, error} ->
        {[{:provider_error, error}], {message, state, :done, resp}}

      {:ok, recovery} ->
        ref = options[:cancellation_ref]

        receive do
          {:cancel, ^ref} when not is_nil(ref) ->
            ResponsesCancellation.request(state.cancellation)

            {[
               {:provider_error,
                ResponsesCancellation.local_error(state.cancellation, state.recovery)}
             ], {message, state, :done, resp}}
        after
          ResponsesRecovery.delay(recovery) ->
            state = %{state | recovery: recovery}

            if System.monotonic_time(:millisecond) >= recovery.deadline do
              error = ResponsesRecovery.error(recovery, :recovery_expired)
              {[{:provider_error, error}], {message, state, :done, resp}}
            else
              url =
                String.trim_trailing(base_url, "/") <>
                  "/responses/" <> URI.encode(recovery.id, &URI.char_unreserved?/1)

              timeout =
                min(
                  options[:receive_timeout] || 120_000,
                  max(1, recovery.deadline - System.monotonic_time(:millisecond))
                )

              case Req.get(url,
                     headers: headers,
                     params: [stream: true, starting_after: recovery.cursor],
                     retry: false,
                     redirect: false,
                     receive_timeout: timeout,
                     into: :self
                   ) do
                {:ok, resumed} ->
                  # Only transport framing is reset. Reducer, Codec, Hosted and output
                  # state are retained; replayed event numbers are filtered before them.
                  state = %{
                    state
                    | framer: %{state.framer | buffer: "", closed?: false},
                      error_body: ""
                  }

                  {[], {message, state, :streaming, resumed}}

                {:error, _error} ->
                  {[], {message, state, :interrupted, resp}}
              end
            end
        end
    end
  end

  defp terminal_events?(events),
    do: Enum.any?(events, &(match?({:done, _, _}, &1) or match?({:provider_error, _}, &1)))

  defp handle_error_chunks(resp, chunks, message, state) do
    Enum.reduce(chunks, {[], message, state, :streaming}, fn
      {:data, chunk}, {acc_events, acc_message, acc_state, _status} ->
        {acc_events, acc_message, %{acc_state | error_body: acc_state.error_body <> chunk},
         :streaming}

      :done, {_acc_events, _acc_message, acc_state, _status} ->
        error = http_provider_error(resp.status, acc_state.error_body, resp.headers)

        error =
          if acc_state.recovery do
            %{
              error
              | raw: %{
                  provider_error: error.raw,
                  response_id: acc_state.recovery.id,
                  starting_after: acc_state.recovery.cursor
                }
            }
          else
            error
          end

        raise error

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
      usage: Sigma.Ai.ProviderUsage.from_wire(nil, :openai_responses),
      stop_reason: nil,
      response_id: nil,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp transform_messages(messages, hosted, image_outputs) do
    kinds =
      for %{role: :assistant, content: blocks} <- messages,
          is_list(blocks),
          %{type: :tool_call, id: id} = call <- blocks,
          into: %{},
          do: {id, Map.get(call, :input_kind, :function)}

    Enum.flat_map(messages, fn
      %{role: role, content: content} when role in [:user, :system] ->
        [%{role: to_string(role), content: transform_responses_content(content, "input_text")}]

      %{role: :assistant, content: content} = message ->
        Hosted.replay_items!(message, hosted) || transform_assistant_responses_items(content)

      %{role: :tool_result, tool_call_id: id, content: content} ->
        type =
          case Map.fetch(kinds, id) do
            {:ok, :custom} ->
              "custom_tool_call_output"

            {:ok, :function} ->
              "function_call_output"

            _ ->
              raise ProviderError,
                kind: :invalid_request,
                message: "Responses tool result requires a preceding typed tool call",
                retryable: false
          end

        output =
          case Map.fetch(image_outputs, id) do
            {:ok, output} -> output
            :error -> transform_tool_result_content(content)
          end

        [%{type: type, call_id: id, output: output}]
    end)
  end

  defp transform_responses_content(content, _text_type) when is_binary(content),
    do: [%{type: "input_text", text: content}]

  defp transform_responses_content(content, text_type) when is_list(content) do
    Enum.map(content, fn
      %{type: :text, text: text} ->
        %{type: text_type, text: text}

      %{type: :image, data: data, mime_type: mime} = image ->
        uri = if String.starts_with?(data, "data:"), do: data, else: "data:#{mime};base64,#{data}"
        maybe_put(%{type: "input_image", image_url: uri}, :detail, image[:detail])

      block ->
        block
    end)
  end

  defp transform_responses_content(content, _text_type), do: content

  defp transform_assistant_responses_items(content) when is_list(content) do
    Enum.flat_map(content, fn
      %{type: :text, text: text} ->
        [%{type: "message", role: "assistant", content: [%{type: "output_text", text: text}]}]

      %{type: :tool_call, id: id, name: name, arguments: arguments} = call ->
        item = native_identity(name) |> Map.put(:call_id, id)

        item =
          if call[:input_kind] == :custom,
            do: Map.merge(item, %{type: "custom_tool_call", input: arguments}),
            else: Map.merge(item, %{type: "function_call", arguments: function_json!(arguments)})

        [item]

      _ ->
        []
    end)
  end

  defp transform_assistant_responses_items(content),
    do: [%{type: "message", role: "assistant", content: [%{type: "output_text", text: content}]}]

  defp transform_tool_result_content(content) when is_list(content) do
    Enum.map_join(content, "\n", fn %{type: :text, text: text} -> text end)
  end

  defp transform_tool_result_content(content), do: content

  # Use the public Responses image codec with each actual tool result and its
  # preceding typed call. The rest of the host projection retains user-image
  # input and durable hosted replay, which have separate protocol contracts.
  defp protocol_image_outputs!(request) do
    {_calls, outputs} =
      Enum.reduce(request.input, {%{}, %{}}, fn
        %{role: :assistant, content: blocks} = message, {calls, outputs} ->
          calls =
            Enum.reduce(blocks, calls, fn
              %{type: :tool_call, tool_call: %{id: id}} = block, calls ->
                Map.put(calls, id, %{message | content: [block]})

              _block, calls ->
                calls
            end)

          {calls, outputs}

        %{role: :tool, tool_call_id: id, content: blocks} = message, {calls, outputs} ->
          if Enum.any?(blocks, &(&1.type == :image)) do
            case Map.fetch(calls, id) do
              {:ok, call} ->
                encoded = encode_image_output!(%{request | input: [call, message], tools: []})
                {calls, Map.put(outputs, id, encoded)}

              :error ->
                raise ProviderError,
                  kind: :invalid_request,
                  message: "Responses tool result requires a preceding typed tool call",
                  retryable: false
            end
          else
            {calls, outputs}
          end

        _message, accumulator ->
          accumulator
      end)

    outputs
  end

  defp encode_image_output!(request) do
    case Codec.encode_request(:openai_responses, request) do
      {:ok, %{"input" => [_call, %{"output" => output}]}} ->
        output

      {:error, error} ->
        raise ProviderError,
          kind: :invalid_request,
          message: "Invalid AI protocol image result: #{error.message}",
          retryable: false
    end
  end

  defp transform_tools(tools) do
    declarations =
      Enum.map(tools, fn tool ->
        identity = native_identity(tool.name)
        custom? = tool[:type] in ["custom", :custom] or tool[:input_kind] == :custom

        declaration = %{
          type: if(custom?, do: "custom", else: "function"),
          name: identity.name,
          description: tool[:description] || ""
        }

        declaration =
          if custom?,
            do: maybe_put(declaration, :format, tool[:format]),
            else:
              Map.merge(declaration, %{
                parameters: tool[:parameters] || tool[:input_schema],
                strict: false
              })

        {identity[:namespace], maybe_put(declaration, :output_schema, tool[:output_schema])}
      end)

    declarations
    |> Enum.reduce({[], MapSet.new()}, fn
      {nil, tool}, {acc, seen} ->
        {acc ++ [tool], seen}

      {namespace, _}, {acc, seen} ->
        if MapSet.member?(seen, namespace) do
          {acc, seen}
        else
          nested = for {^namespace, tool} <- declarations, do: tool

          {acc ++
             [
               %{
                 type: "namespace",
                 name: namespace,
                 description: "Tools in the #{namespace} namespace.",
                 tools: nested
               }
             ], MapSet.put(seen, namespace)}
        end
    end)
    |> elem(0)
  end

  defp native_identity(name) do
    case String.split(name, "::") do
      [name] -> %{name: name}
      [namespace, name] -> %{namespace: namespace, name: name}
    end
  end

  defp function_json!(arguments) when is_map(arguments), do: Jason.encode!(arguments)
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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

  defp protocol_block(%{type: :image, data: data, mime_type: mime} = image),
    do: %{
      type: :image,
      data: maybe_put(%{"data" => data, "mime_type" => mime}, "detail", image[:detail])
    }

  defp protocol_block(%{type: :thinking, thinking: thinking}),
    do: %{type: :reasoning, data: %{text: thinking}}

  defp protocol_block(%{type: :tool_call, id: id, name: name, arguments: arguments} = call) do
    raw_arguments =
      case Map.get(call, :input_kind, :function) do
        :custom -> {:custom, arguments}
        :function -> {:structured, arguments}
        _ -> :invalid
      end

    %{
      type: :tool_call,
      tool_call: %{id: id, name: name, raw_arguments: raw_arguments}
    }
  end

  defp protocol_block(_block), do: %{type: :invalid}

  defp protocol_tool(tool) do
    %{
      name: tool.name,
      description: tool[:description],
      input_kind:
        if(tool[:type] in ["custom", :custom] or tool[:input_kind] == :custom,
          do: :custom,
          else: :function
        ),
      input_schema: tool[:parameters] || tool[:input_schema],
      format: tool[:format],
      extensions:
        if(tool[:output_schema],
          do: %{"openai_responses::output_schema" => tool.output_schema},
          else: %{}
        )
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

  @impl true
  def output_token_limit(model, options) do
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

  defp response_error(error) do
    %ProviderError{kind: :server_error, message: provider_error_message(error), retryable: false}
  end

  defp normalize_terminal_event!(%{"type" => type, "response" => response} = event)
       when type in ["response.completed", "response.incomplete", "response.done"] do
    case {type, response["status"]} do
      {_, "failed"} ->
        Map.put(event, "type", "response.failed")

      {_, "cancelled"} ->
        Map.put(event, "type", "response.cancelled")

      {_, status} when status not in [nil, "completed", "incomplete"] ->
        raise ProviderError.malformed(:invalid_terminal_response_status)

      {"response.done", nil} ->
        raise ProviderError.malformed(:invalid_terminal_response_status)

      {"response.incomplete", _} ->
        Map.put(event, "response", Map.put(response, "status", "incomplete"))

      {"response.done", "incomplete"} ->
        Map.put(event, "type", "response.incomplete")

      {"response.done", "completed"} ->
        Map.put(event, "type", "response.completed")

      _ ->
        event
    end
  end

  defp normalize_terminal_event!(event), do: event

  defp process_events(events, message, {codec, hosted}) do
    Enum.reduce_while(events, {[], message, {codec, hosted}}, fn event,
                                                                 {all, acc, {codec, hosted}} ->
      event = normalize_terminal_event!(event)
      {emitted, next, codec} = process_event(event, acc, codec)

      {observed, next, hosted} = Hosted.observe(hosted, event, next)

      emitted =
        Enum.map(emitted, fn
          {:done, reason, _message} -> {:done, reason, next}
          other -> other
        end)

      result = {all ++ observed ++ emitted, next, {codec, hosted}}

      if Enum.any?(emitted, &(match?({:done, _, _}, &1) or match?({:provider_error, _}, &1))),
        do: {:halt, result},
        else: {:cont, result}
    end)
  rescue
    error in ProviderError -> {[{:provider_error, error}], message, {codec, hosted}}
  end

  # Common failure handling must precede both ordinary and native codec paths.
  defp process_event(:done, acc, codec),
    do: {[{:provider_error, stream_error(:truncated_stream, acc)}], acc, codec}

  defp process_event({:provider_error, error}, acc, codec),
    do: {[{:provider_error, %{error | raw: %{response_id: acc.response_id}}}], acc, codec}

  defp process_event(%{"type" => "response.cancelled"}, acc, codec),
    do: {[{:provider_error, ProviderError.from_reason(:cancelled)}], acc, codec}

  defp process_event(%{"type" => "response.failed", "response" => response}, acc, codec),
    do: {[{:provider_error, response_error(response["error"] || response)}], acc, codec}

  defp process_event(%{"type" => "error"} = error, acc, codec),
    do: {[{:provider_error, response_error(error)}], acc, codec}

  defp process_event(event, acc, :ordinary) do
    {events, acc} = process_ordinary_events([event], acc)
    {events, acc, :ordinary}
  end

  defp process_event(%{"type" => type, "response" => response}, acc, codec)
       when type in ["response.created", "response.queued", "response.in_progress"],
       do: {[], %{acc | response_id: acc.response_id || response["id"]}, codec}

  defp process_event(%{"type" => "response.output_text.done", "text" => text}, acc, codec)
       when is_binary(text) and text != "" do
    {events, acc} =
      if is_nil(text_content_index(acc.content)),
        do: process_text_delta(acc, text),
        else: {[], acc}

    {events, acc, codec}
  end

  defp process_event(
         %{"type" => "response.output_item.done", "item" => %{"type" => "message"} = item},
         acc,
         codec
       ) do
    {events, acc} = maybe_process_message_item_done(acc, item)
    {events, acc, codec}
  end

  defp process_event(%{"type" => "response.output_text.delta", "delta" => text}, acc, codec) do
    {events, acc} = process_text_delta(acc, text)
    {events, acc, codec}
  end

  defp process_event(%{"type" => type, "delta" => text}, acc, codec)
       when type in ["response.reasoning_text.delta", "response.reasoning_summary_text.delta"] do
    {events, acc} = process_thinking_delta(acc, text)
    {events, acc, codec}
  end

  defp process_event(%{"type" => type} = event, acc, codec)
       when type in [
              "response.function_call_arguments.delta",
              "response.function_call_arguments.done",
              "response.custom_tool_call_input.delta",
              "response.custom_tool_call_input.done"
            ],
       do: process_tool_frame(event, acc, codec)

  defp process_event(%{"type" => type, "item" => %{"type" => kind}} = event, acc, codec)
       when type in ["response.output_item.added", "response.output_item.done"] and
              kind in ["function_call", "custom_tool_call"],
       do: process_tool_frame(event, acc, codec)

  defp process_event(%{"type" => type, "response" => response}, acc, codec)
       when type in ["response.completed", "response.incomplete", "response.done"] do
    incomplete? = type == "response.incomplete" or response["status"] == "incomplete"
    output = response["output"]

    if response["status"] not in [nil, "completed", "incomplete"] do
      raise ProviderError.malformed(:invalid_terminal_response_status)
    end

    if (not is_nil(output) and not is_list(output)) or
         (is_list(output) and not Enum.all?(output, &is_map/1)) do
      raise ProviderError.malformed(:invalid_response_output)
    end

    items = Enum.filter(output || [], &(&1["type"] in ["function_call", "custom_tool_call"]))

    if incomplete? and
         (Enum.any?(acc.content, &(&1[:type] == :tool_call and Map.has_key?(&1, :partial_json))) or
            Enum.any?(items, &(&1["status"] != "completed"))) do
      raise ProviderError.malformed(:incomplete_tool_calls)
    end

    response = if incomplete?, do: Map.put(response, "status", "incomplete"), else: response
    complete_response(acc, response, codec)
  end

  defp process_event(_event, acc, codec), do: {[], acc, codec}

  # Let the public protocol codec validate tool identity, input kind, completion
  # status, ordering, accumulated bytes and duplicates. Text/reasoning stay host-owned.
  defp process_tool_frame(frame, acc, codec) do
    bytes = "data: " <> Jason.encode!(frame) <> "\n\n"

    case Codec.stream_feed(:openai_responses, codec, bytes) do
      {:ok, codec, observations} ->
        {events, acc} = Enum.map_reduce(observations, acc, &apply_tool_observation(&1, &2, frame))
        {List.flatten(events), acc, codec}

      {:error, error, _codec} ->
        raise ProviderError.malformed(error.message)
    end
  end

  defp apply_tool_observation(%{type: :tool_call_start} = event, acc, frame) do
    index = length(acc.content)

    kind =
      if event.extensions["openai_responses::input_kind"] == "custom",
        do: :custom,
        else: :function

    item = frame["item"]
    input = if kind == :custom, do: item["input"] || "", else: item["arguments"] || ""

    block = %{
      type: :tool_call,
      item_id: event.native_id,
      id: event.call_id,
      name: event.name,
      input_kind: kind,
      partial_json: input
    }

    acc = %{acc | content: acc.content ++ [block]}
    {[{:toolcall_start, index, acc}], acc}
  end

  defp apply_tool_observation(%{type: :tool_call_delta} = event, acc, _frame) do
    index = response_tool_index(acc.content, event.native_id, event.call_id)

    content =
      update_content(acc.content, index, fn block ->
        Map.update!(block, :partial_json, &(&1 <> event.arguments_delta))
      end)

    acc = %{acc | content: content}
    {[{:toolcall_delta, index, event.arguments_delta, acc}], acc}
  end

  defp apply_tool_observation(
         %{type: :tool_call_done, content: %{tool_call: call}} = event,
         acc,
         _frame
       ) do
    index = response_tool_index(acc.content, event.native_id, event.call_id)
    {kind, input} = call.raw_arguments
    arguments = if kind == :custom, do: input, else: Jason.decode!(input)

    tool = %{
      type: :tool_call,
      id: call.id,
      name: call.name,
      arguments: arguments,
      input_kind: if(kind == :custom, do: :custom, else: :function),
      item_id: call.native_id
    }

    acc = %{acc | content: List.replace_at(acc.content, index, tool)}
    {[{:toolcall_end, index, tool, acc}], acc}
  end

  defp finalize_response_tools(acc, codec, output) do
    items =
      if is_list(output) do
        Enum.filter(output, &(&1["type"] in ["function_call", "custom_tool_call"]))
      else
        for %{type: :tool_call, partial_json: input} = call <- acc.content,
            do: response_tool_item(call, input)
      end

    {events, acc, codec} =
      Enum.reduce(items, {[], acc, codec}, fn item, {events, acc, codec} ->
        {started, acc, codec} =
          if is_nil(response_tool_index(acc.content, item["id"], item["call_id"])) do
            key = if item["type"] == "custom_tool_call", do: "input", else: "arguments"

            process_tool_frame(
              %{"type" => "response.output_item.added", "item" => Map.put(item, key, "")},
              acc,
              codec
            )
          else
            {[], acc, codec}
          end

        {completed, acc, codec} =
          process_tool_frame(%{"type" => "response.output_item.done", "item" => item}, acc, codec)

        {events ++ started ++ completed, acc, codec}
      end)

    calls = Enum.filter(acc.content, &(&1[:type] == :tool_call))

    if Enum.any?(calls, &Map.has_key?(&1, :partial_json)) or
         (is_list(output) and
            (length(items) != length(calls) or
               MapSet.new(items, & &1["call_id"]) != MapSet.new(calls, & &1.id))) do
      raise ProviderError.malformed(:incomplete_tool_calls)
    end

    {events, acc, codec}
  end

  defp response_tool_item(call, input) do
    identity =
      native_identity(call.name) |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

    {type, key} =
      if call.input_kind == :custom,
        do: {"custom_tool_call", "input"},
        else: {"function_call", "arguments"}

    Map.merge(identity, %{
      "type" => type,
      "id" => call.item_id,
      "call_id" => call.id,
      key => input
    })
  end

  defp response_tool_index(content, item_id, call_id) do
    Enum.find_index(content, fn block ->
      block[:type] == :tool_call and
        ((is_binary(item_id) and block[:item_id] == item_id) or
           (is_binary(call_id) and block[:id] == call_id))
    end)
  end

  defp complete_response(acc, response, :ordinary) do
    {events, acc} = ordinary_complete_response(acc, response)
    {events, acc, :ordinary}
  end

  defp complete_response(acc, response, codec) do
    {text_events, acc} = maybe_extract_response_output_text(acc, response)
    {tool_events, acc, codec} = finalize_response_tools(acc, codec, response["output"])

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
      {text_events ++ tool_events, acc, codec}
    else
      {text_events ++ tool_events ++ [{:done, acc.stop_reason, acc}], acc, codec}
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

  defp stream_error(reason, message) do
    %{
      ProviderError.malformed(reason)
      | message:
          "Provider stream ended without a valid terminal response (#{reason}). " <>
            "Automatic recovery is unavailable; a new request may duplicate work.",
        raw: %{reason: reason, response_id: message.response_id}
    }
  end

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

  defp process_ordinary_events(events, message) do
    Enum.map_reduce(events, message, fn event, acc ->
      case event do
        %{"type" => type, "response" => response}
        when type in ["response.created", "response.queued", "response.in_progress"] ->
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
          ordinary_start_response_tool(acc, item)

        %{
          "type" => "response.function_call_arguments.delta",
          "delta" => delta
        } = event
        when is_binary(delta) ->
          ordinary_process_tool_delta(acc, event["item_id"], event["call_id"], delta)

        %{
          "type" => "response.function_call_arguments.done",
          "arguments" => arguments
        } = event ->
          ordinary_update_tool_arguments(acc, event, arguments)

        %{"type" => "response.output_item.done", "item" => %{"type" => "function_call"} = item} ->
          ordinary_finalize_tool(acc, item)

        %{"type" => "response.output_item.done", "item" => %{"type" => "message"} = item} ->
          maybe_process_message_item_done(acc, item)

        %{"type" => type, "response" => response}
        when type in ["response.completed", "response.incomplete", "response.done"] ->
          if is_nil(acc.stop_reason) do
            ordinary_complete_response(acc, response)
          else
            {[], acc}
          end

        _ ->
          {[], acc}
      end
    end)
    |> then(fn {events, acc} -> {List.flatten(events), acc} end)
  end

  defp ordinary_complete_response(acc, response) do
    {text_events, acc} = maybe_extract_response_output_text(acc, response)
    {tool_events, acc} = ordinary_finalize_tools(acc, response)

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

  defp ordinary_start_response_tool(acc, item) do
    item_id = ordinary_present_string(item["id"])
    call_id = ordinary_present_string(item["call_id"])
    name = ordinary_present_string(item["name"])
    initial_args = if is_binary(item["arguments"]), do: item["arguments"], else: ""

    case ordinary_tool_index(acc.content, item_id, call_id) do
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
            |> Map.put(:item_id, ordinary_present_string(block[:item_id]) || item_id)
            |> Map.put(:id, ordinary_present_string(block[:id]) || call_id)
            |> Map.put(:name, ordinary_present_string(block[:name]) || name)
          end)

        {[], %{acc | content: content}}
    end
  end

  defp ordinary_process_tool_delta(acc, item_id, call_id, delta) do
    item_id = ordinary_present_string(item_id)
    call_id = ordinary_present_string(call_id)
    index = ordinary_tool_index(acc.content, item_id, call_id) || length(acc.content)

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

  defp ordinary_update_tool_arguments(acc, event, arguments) do
    item_id = ordinary_present_string(event["item_id"])
    call_id = ordinary_present_string(event["call_id"])
    name = ordinary_present_string(event["name"])
    index = ordinary_tool_index(acc.content, item_id, call_id) || length(acc.content)

    content =
      if index == length(acc.content),
        do:
          acc.content ++
            [%{type: :tool_call, item_id: item_id, id: call_id, name: name, partial_json: ""}],
        else: acc.content

    block = Enum.at(content, index)

    updated =
      block
      |> Map.put(:item_id, ordinary_present_string(block[:item_id]) || item_id)
      |> Map.put(:id, ordinary_present_string(block[:id]) || call_id)
      |> Map.put(:name, ordinary_present_string(block[:name]) || name)
      |> ordinary_maybe_put_arguments(arguments)

    content = List.replace_at(content, index, updated)

    {[], %{acc | content: content}}
  end

  defp ordinary_maybe_put_arguments(block, arguments) when is_map(arguments),
    do: Map.put(block, :arguments, arguments)

  defp ordinary_maybe_put_arguments(block, arguments) when is_binary(arguments) do
    case ordinary_present_string(arguments) do
      nil -> block
      present -> Map.put(block, :arguments, present)
    end
  end

  defp ordinary_maybe_put_arguments(block, _arguments), do: block

  defp ordinary_finalize_tool(acc, item) do
    item_id = ordinary_present_string(item["id"])
    call_id = ordinary_present_string(item["call_id"])
    index = ordinary_tool_index(acc.content, item_id, call_id) || length(acc.content)
    block = Enum.at(acc.content, index) || %{}

    if block[:type] == :tool_call and not Map.has_key?(block, :partial_json) and
         is_map(block[:arguments]) do
      {[], acc}
    else
      arguments =
        ordinary_present_arguments(item["arguments"]) ||
          ordinary_present_arguments(block[:arguments]) ||
          ordinary_present_arguments(block[:partial_json]) ||
          "{}"

      name = ordinary_present_string(item["name"]) || ordinary_present_string(block[:name])

      call_id =
        call_id || ordinary_present_string(block[:id]) || item_id ||
          ordinary_present_string(block[:item_id])

      with {:ok, arguments} <- ordinary_decode_arguments(arguments),
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

  defp ordinary_finalize_tools(acc, response) do
    output_items =
      case response do
        %{"output" => items} when is_list(items) ->
          Enum.filter(items, &match?(%{"type" => "function_call"}, &1))

        _ ->
          []
      end

    {output_events, acc} =
      Enum.reduce(output_items, {[], acc}, fn item, {events, current_acc} ->
        item_id = ordinary_present_string(item["id"])
        call_id = ordinary_present_string(item["call_id"])

        case ordinary_tool_index(current_acc.content, item_id, call_id) do
          nil ->
            {new_events, new_acc} = ordinary_finalize_tool(current_acc, item)
            {events ++ new_events, new_acc}

          index ->
            block = Enum.at(current_acc.content, index)

            if Map.has_key?(block, :partial_json) do
              {new_events, new_acc} = ordinary_finalize_tool(current_acc, item)
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
          ordinary_finalize_tool(current_acc, %{
            "id" => block[:item_id],
            "call_id" => block[:id],
            "name" => block[:name],
            "arguments" =>
              ordinary_present_arguments(block[:arguments]) ||
                ordinary_present_arguments(block[:partial_json])
          })

        {events ++ new_events, new_acc}
      else
        {events, current_acc}
      end
    end)
  end

  defp ordinary_tool_index(content, item_id, call_id) do
    present_item_id = ordinary_present_string(item_id)
    present_call_id = ordinary_present_string(call_id)

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

  defp ordinary_present_arguments(value) when is_map(value), do: value
  defp ordinary_present_arguments(value) when is_binary(value), do: ordinary_present_string(value)
  defp ordinary_present_arguments(_value), do: nil

  defp ordinary_present_string(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp ordinary_present_string(_value), do: nil

  defp ordinary_decode_arguments(arguments), do: ToolCallJson.decode_arguments(arguments)

  defp response_usage(usage),
    do: Sigma.Ai.ProviderUsage.from_wire(usage, :openai_responses)

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

    Sigma.Ai.CreationRequest.http_error(status, error, retry_after(headers))
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
