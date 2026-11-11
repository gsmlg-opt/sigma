defmodule Sigma.Ai.Providers.Anthropic do
  @behaviour Sigma.Ai.Provider

  alias Backplane.AiProtocol.Codec
  alias Sigma.Ai.Providers.{ProtocolRequest, ToolTransport}

  alias Sigma.Ai.{
    ProviderAuth,
    ProviderCapabilities,
    ProviderError,
    ProviderRequest,
    Stream,
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
      supported_options: [:thinking_budget, :max_tokens]
    }
  end

  @impl true
  def stream(params) do
    model = params.model
    context = params.context
    projection = native_projection!(model, context)
    options = params.options
    Sigma.Ai.CreationRequest.reject_responses_recovery!(options)
    session_id = Map.get(params, :session_id)
    log_session_id = Map.get(params, :log_session_id, session_id)

    api_key = options[:api_key] || System.get_env("ANTHROPIC_AUTH_TOKEN")

    base_url =
      options[:base_url] || System.get_env("ANTHROPIC_BASE_URL") || "https://api.anthropic.com"

    system = build_system(context[:system] || context[:system_prompt])

    body =
      %{
        model: model.id,
        messages: transform_messages(context.messages, projection),
        max_tokens: output_token_limit(model, options),
        stream: true
      }
      |> maybe_put(:system, system)

    body =
      if context[:tools],
        do: Map.put(body, :tools, transform_tools(context.tools, projection)),
        else: body

    {body, extra_betas} =
      case options[:thinking_budget] do
        budget when is_integer(budget) and budget > 0 ->
          body =
            body
            |> Map.put(:thinking, %{type: "enabled", budget_tokens: budget})

          {body, ["interleaved-thinking-2025-05-14"]}

        _ ->
          {body, []}
      end

    beta_value = (["prompt-caching-2024-07-31"] ++ extra_betas) |> Enum.join(",")

    headers =
      [
        ProviderAuth.headers(api_key, options, "x-api-key"),
        {"anthropic-version", "2023-06-01"},
        {"content-type", "application/json"},
        {"anthropic-beta", beta_value}
      ]
      |> List.flatten()

    codec = if projection, do: Codec.stream_new(:anthropic, projection.codec_options)
    inner = build_inner_stream(model, body, headers, base_url, options, codec)

    Elixir.Stream.transform(
      inner,
      fn ->
        :telemetry.execute(
          [:sigma, :llm, :request, :start],
          %{system_time: System.system_time()},
          %{
            session_id: session_id,
            log_session_id: log_session_id,
            model: model.id,
            provider: "anthropic"
          }
        )

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

  # Native (Codex) profiles: custom/freeform tools, namespaced names and output
  # schemas use Backplane's explicit request-scoped Anthropic projection. The codec
  # owns wire names and custom `input` wrapping; the host keeps its own message
  # projection (thinking signatures, cache_control, grouped tool results) and only
  # substitutes the codec's tool declarations and tool_use identities/inputs.
  # Ordinary JSON-function requests keep the hand-written path unchanged.
  defp native_projection!(model, context) do
    if ProtocolRequest.native_tools?(context) do
      ToolTransport.reject_hosted!(context, "Anthropic")

      with {:ok, request} <-
             ProtocolRequest.build(model, context,
               output_schema_extension: "codex::output_schema",
               reasoning: :text
             ),
           {:ok, %{body: body, codec_options: codec_options}} <-
             Codec.Anthropic.prepare_request(request, stream: true) do
        %{
          tools: body["tools"] || [],
          calls: projected_calls!(body["messages"] || []),
          codec_options: codec_options
        }
      else
        {:error, error} -> raise invalid_native_request(error.message)
      end
    else
      ToolTransport.require_json_functions!(context, "Anthropic")
      nil
    end
  end

  defp projected_calls!(messages) do
    for %{"content" => blocks} when is_list(blocks) <- messages,
        %{"type" => "tool_use", "id" => id} = block <- blocks,
        reduce: %{} do
      calls ->
        case Map.fetch(calls, id) do
          :error -> Map.put(calls, id, block)
          {:ok, ^block} -> calls
          {:ok, _other} -> raise invalid_native_request("duplicate tool call id #{inspect(id)}")
        end
    end
  end

  defp invalid_native_request(message) do
    %ProviderError{
      kind: :invalid_request,
      message: "Invalid Anthropic native tool request: #{message}",
      retryable: false
    }
  end

  defp build_inner_stream(model, body, headers, base_url, options, codec) do
    Elixir.Stream.resource(
      fn ->
        resp =
          try do
            req_opts =
              [
                json: body,
                headers: headers,
                receive_timeout: options[:receive_timeout] || 120_000,
                retry: Sigma.Ai.CreationRequest.retry_policy(options),
                max_retries: Keyword.get(options, :max_retries, 3)
              ]
              |> maybe_put_opt(options, :retry_delay)

            Sigma.Ai.HTTP.post_stream!(base_url <> "/v1/messages", req_opts)
          rescue
            e in [Sigma.Ai.HTTP.TransportError] ->
              reraise Sigma.Ai.CreationRequest.submission_error(e), __STACKTRACE__
          end

        {_initial_assistant_message(model), {"", codec}, :streaming, resp}
      end,
      fn
        {message, _buffer, :done, resp} ->
          {:halt, {message, "", :done, resp}}

        {message, buffer, :streaming, resp} ->
          cancellation_ref = options[:cancellation_ref]

          receive do
            {:cancel, ^cancellation_ref} when not is_nil(cancellation_ref) ->
              Sigma.Ai.HTTP.cancel(resp)
              error = ProviderError.from_reason(:cancelled)
              {[{:provider_error, error}], {message, buffer, :done, resp}}

            req_message ->
              {processed_events, new_message, new_buffer, status} =
                handle_async_message(resp, req_message, message, buffer)

              {processed_events, {new_message, new_buffer, status, resp}}
          after
            options[:receive_timeout] || 120_000 ->
              Sigma.Ai.HTTP.cancel(resp)
              raise Sigma.Ai.CreationRequest.interrupted(:timeout, message[:response_id])
          end
      end,
      fn
        {_message, _buffer, :streaming, resp} -> Sigma.Ai.HTTP.cancel(resp)
        _ -> :ok
      end
    )
  end

  defp maybe_put_opt(opts, options, key) do
    case Keyword.fetch(options, key) do
      {:ok, val} -> Keyword.put(opts, key, val)
      :error -> opts
    end
  end

  defp handle_async_message(resp, req_message, message, buffer) do
    case Sigma.Ai.HTTP.parse_message(resp, req_message) do
      {:ok, chunks} ->
        if resp.status >= 300 do
          handle_error_chunks(resp, chunks, message, buffer)
        else
          handle_stream_chunks(chunks, message, buffer)
        end

      {:error, %{reason: reason}} ->
        raise Sigma.Ai.CreationRequest.interrupted(reason, message[:response_id])

      :unknown ->
        {[], message, buffer, :streaming}
    end
  end

  defp handle_stream_chunks(chunks, message, buffer) do
    Enum.reduce(chunks, {[], message, buffer, :streaming}, fn
      {:data, chunk}, {acc_events, acc_message, {acc_buffer, codec}, _status} ->
        {events, sse_buffer} = Stream.decode(acc_buffer, chunk)
        {processed_events, new_message, codec} = process_stream_events(events, acc_message, codec)
        new_buffer = {sse_buffer, codec}

        status =
          if Enum.any?(processed_events, &match?({:done, _, _}, &1)),
            do: :done,
            else: :streaming

        {acc_events ++ processed_events, new_message, new_buffer, status}

      :done, {acc_events, acc_message, acc_buffer, :done} ->
        {acc_events, acc_message, acc_buffer, :done}

      :done, {acc_events, acc_message, acc_buffer, _status} ->
        error = ProviderError.malformed(:truncated_stream)
        {acc_events ++ [{:provider_error, error}], acc_message, acc_buffer, :done}

      _chunk, acc ->
        acc
    end)
  end

  defp handle_error_chunks(resp, chunks, message, buffer) do
    Enum.reduce(chunks, {[], message, buffer, :streaming}, fn
      {:data, chunk}, {acc_events, acc_message, {acc_buffer, codec}, _status} ->
        {acc_events, acc_message, {acc_buffer <> chunk, codec}, :streaming}

      :done, {_acc_events, _acc_message, {acc_buffer, _codec}, _status} ->
        raise http_provider_error(resp.status, acc_buffer, resp.headers)

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
      usage: Sigma.Ai.ProviderUsage.from_wire(nil, :anthropic),
      stop_reason: nil,
      response_id: nil,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp transform_messages(messages, projection) do
    {transformed_messages, pending_tool_results} =
      Enum.reduce(messages, {[], []}, fn
        %{role: :tool_result} = message, {acc, pending_tool_results} ->
          {acc, [transform_tool_result(message) | pending_tool_results]}

        message, {acc, pending_tool_results} ->
          acc = flush_tool_results(acc, pending_tool_results)
          {[transform_message(message, projection) | acc], []}
      end)

    transformed_messages
    |> flush_tool_results(pending_tool_results)
    |> Enum.reverse()
  end

  defp transform_message(%{role: :user, content: content}, _projection) do
    %{role: "user", content: transform_user_content(content)}
  end

  defp transform_message(%{role: :assistant, content: content}, projection) do
    %{role: "assistant", content: transform_content(content, projection)}
  end

  defp transform_user_content(content) when is_binary(content), do: content

  defp transform_user_content(content) when is_list(content) do
    Enum.map(content, fn
      %{type: :text, text: text} ->
        %{type: "text", text: text}

      %{type: :image, data: data, mime_type: mime} ->
        %{type: "image", source: %{type: "base64", media_type: mime, data: data}}

      block ->
        block
    end)
  end

  defp transform_user_content(content), do: content

  defp flush_tool_results(acc, []), do: acc

  defp flush_tool_results(acc, pending_tool_results) do
    [
      %{
        role: "user",
        content: Enum.reverse(pending_tool_results)
      }
      | acc
    ]
  end

  defp transform_tool_result(%{
         role: :tool_result,
         tool_call_id: id,
         content: content,
         is_error: is_error
       }) do
    %{
      type: "tool_result",
      tool_use_id: id,
      content: transform_tool_result_content(content),
      is_error: is_error
    }
  end

  defp transform_tool_result_content(content) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{type: :text, text: text} -> text
      _ -> ""
    end)
  end

  defp transform_tool_result_content(content), do: content

  defp transform_content(content, projection) do
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

      %{type: :tool_call} = tc when is_nil(projection) ->
        %{type: "tool_use", id: tc.id, name: tc.name, input: tc.arguments}

      %{type: :tool_call} = tc ->
        case Map.fetch(projection.calls, tc.id) do
          {:ok, %{"name" => name, "input" => input}} ->
            %{type: "tool_use", id: tc.id, name: name, input: input}

          :error ->
            raise invalid_native_request("tool call #{inspect(tc.id)} has no projection")
        end
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

  @impl true
  def output_token_limit(model, options) do
    limit =
      positive_integer(options[:max_tokens]) ||
        positive_integer(options[:maxTokens]) || model_max_tokens(model) || 4096

    case options[:thinking_budget] do
      budget when is_integer(budget) and budget > 0 -> max(limit, budget + 1000)
      _ -> limit
    end
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

  defp transform_tools(_tools, %{tools: []}), do: []

  defp transform_tools(_tools, %{tools: tools}) do
    List.update_at(tools, -1, &Map.put(&1, "cache_control", %{"type" => "ephemeral"}))
  end

  defp transform_tools([], nil), do: []

  defp transform_tools(tools, nil) do
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

  @doc false
  def process_events(events, message) do
    Enum.map_reduce(events, message, fn event, acc ->
      case event do
        %{"type" => "error", "error" => error} ->
          raise provider_error_message(error)

        %{"error" => error} ->
          raise provider_error_message(error)

        %{"type" => "message_start", "message" => msg} ->
          start_usage = msg["usage"]
          base_usage = if start_usage, do: transform_usage(start_usage), else: acc.usage
          new_acc = %{acc | response_id: msg["id"], usage: base_usage}
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
                case ToolCallJson.decode_arguments(block.partial_json) do
                  {:ok, args} when is_map(args) ->
                    tool_call = %{
                      type: :tool_call,
                      id: block.id,
                      name: block.name,
                      arguments: args
                    }

                    new_content = List.replace_at(acc.content, idx, tool_call)
                    new_acc = %{acc | content: new_content}
                    {{:toolcall_end, idx, tool_call, new_acc}, new_acc}

                  _invalid ->
                    error = ProviderError.malformed(:invalid_tool_call_arguments)
                    {{:provider_error, error}, acc}
                end

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

          new_acc = %{acc | stop_reason: stop_reason, usage: merge_delta_usage(acc.usage, usage)}
          {nil, new_acc}

        %{"type" => "message_stop"} ->
          {{:done, acc.stop_reason, acc}, acc}

        _ ->
          {nil, acc}
      end
    end)
    |> then(fn {events, acc} -> {Enum.reject(events, &is_nil/1), acc} end)
  end

  defp process_stream_events(events, message, nil) do
    {events, message} = process_events(events, message)
    {events, message, nil}
  end

  defp process_stream_events(events, message, codec) do
    {events, {message, codec}} =
      Enum.flat_map_reduce(events, {message, codec}, fn event, {acc, codec} ->
        {events, acc, codec} = process_native_event(event, acc, codec)
        {events, {acc, codec}}
      end)

    {events, message, codec}
  end

  # The public codec validates tool identity, alias reversal, custom `input`
  # unwrapping, ordering and input bounds. Text, thinking, usage and terminal
  # events stay host-owned so the native path emits the ordinary event contract.
  defp process_native_event(%{"type" => "message_stop"} = event, acc, codec) do
    {[], acc, codec} = process_tool_frame(event, acc, codec)
    {events, acc} = process_events([event], acc)
    {events, acc, codec}
  end

  defp process_native_event(event, acc, codec) do
    if native_tool_frame?(event, acc) do
      process_tool_frame(event, acc, codec)
    else
      {events, acc} = process_events([event], acc)
      {events, acc, codec}
    end
  end

  defp native_tool_frame?(
         %{"type" => "content_block_start", "content_block" => %{"type" => "tool_use"}},
         _acc
       ),
       do: true

  defp native_tool_frame?(%{"type" => type, "index" => idx}, acc)
       when type in ["content_block_delta", "content_block_stop"] and is_integer(idx),
       do: match?(%{type: :tool_call}, Enum.at(acc.content, idx))

  defp native_tool_frame?(_event, _acc), do: false

  defp process_tool_frame(frame, acc, codec) do
    bytes = "data: " <> Jason.encode!(frame) <> "\n\n"

    case Codec.stream_feed(:anthropic, codec, bytes) do
      {:ok, codec, observations} ->
        {events, acc} = Enum.flat_map_reduce(observations, acc, &apply_tool_observation/2)
        {events, acc, codec}

      {:error, error, _codec} ->
        raise ProviderError.malformed(error.message)
    end
  end

  defp apply_tool_observation(%{type: :tool_call_start} = event, acc) do
    kind = if event.extensions["anthropic::input_kind"] == "custom", do: :custom, else: :function

    block = %{
      type: :tool_call,
      id: event.call_id,
      name: event.name,
      input_kind: kind,
      partial_json: ""
    }

    acc = %{acc | content: List.insert_at(acc.content, event.index, block)}
    {[{:toolcall_start, event.index, acc}], acc}
  end

  defp apply_tool_observation(%{type: :tool_call_delta} = event, acc) do
    content =
      update_content(acc.content, event.index, fn block ->
        Map.update!(block, :partial_json, &(&1 <> event.arguments_delta))
      end)

    acc = %{acc | content: content}
    {[{:toolcall_delta, event.index, event.arguments_delta, acc}], acc}
  end

  defp apply_tool_observation(%{type: :tool_call_done} = event, acc) do
    {kind, arguments} =
      case event.content do
        %{tool_call: %{raw_arguments: {:custom, text}}} -> {:custom, text}
        arguments when is_map(arguments) -> {:function, arguments}
      end

    tool = %{
      type: :tool_call,
      id: event.call_id,
      name: event.name,
      arguments: arguments,
      input_kind: kind
    }

    acc = %{acc | content: List.replace_at(acc.content, event.index, tool)}
    {[{:toolcall_end, event.index, tool, acc}], acc}
  end

  defp apply_tool_observation(_event, acc), do: {[], acc}

  defp update_content(content, idx, fun) do
    List.replace_at(content, idx, fun.(Enum.at(content, idx)))
  end

  defp transform_usage(usage), do: Sigma.Ai.ProviderUsage.from_wire(usage, :anthropic)

  # Anthropic deltas are cumulative; absent/null values do not erase known facts.
  defp merge_delta_usage(baseline, nil), do: baseline

  defp merge_delta_usage(baseline, delta_usage) do
    wire = %{
      "input_tokens" => baseline.input,
      "output_tokens" => baseline.output,
      "cache_read_input_tokens" => baseline.cache_read,
      "cache_creation_input_tokens" => baseline.cache_write
    }

    wire
    |> Map.merge(delta_usage, fn _key, previous, current ->
      if is_nil(current), do: previous, else: current
    end)
    |> transform_usage()
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
