defmodule Sigma.Ai.Providers.OpenAIResponses.Hosted do
  @moduledoc false

  alias Sigma.Ai.{ProviderError, ProviderEvent}

  @key "openai_responses_hosted"
  @max_bytes 1_048_576
  @max_items 128
  @search_events ~w(response.web_search_call.in_progress response.web_search_call.searching response.web_search_call.completed)

  def sse_options(%{enabled: true}) do
    # The native payload has its own 1 MiB aggregate limit. Allow the outer SSE
    # event fields and framing without inheriting the portable 256 KiB default.
    frame_bytes = @max_bytes + 1_024
    [max_frame_bytes: frame_bytes, max_buffer_bytes: frame_bytes * 2]
  end

  def sse_options(_prepared), do: []

  @doc false
  def project_metadata(message) do
    case Map.get(message, :metadata) do
      %{@key => envelope} ->
        origin = envelope["origin"]

        unless is_map(origin) and
                 Enum.sort(Map.keys(origin)) == ~w(endpoint_sha256 model protocol provider) and
                 origin["protocol"] == "openai-responses" and
                 optional_string?(origin["provider"]) and is_binary(origin["provider"]) and
                 optional_string?(origin["model"]) and is_binary(origin["model"]) and
                 is_binary(origin["endpoint_sha256"]) and
                 Regex.match?(~r/\A[0-9a-f]{64}\z/, origin["endpoint_sha256"]) and
                 json_value?(envelope),
               do: invalid!(:hosted_history_origin)

        canonical = if is_struct(message), do: Map.from_struct(message), else: message
        replay_items!(canonical, %{origin: origin})
        {:ok, envelope}

      _ ->
        :none
    end
  rescue
    _ -> {:error, :provider_hosted_payload_rejected}
  end

  @doc false
  def project_event(%{"type" => type} = frame) do
    unless json_value?(frame), do: malformed!(:hosted_event)
    index!(frame["output_index"])

    cond do
      type in ["response.output_item.added", "response.output_item.done"] ->
        %{"type" => "web_search_call"} = item = frame["item"]
        validate_search!(item, type == "response.output_item.done", :stream)

      type in @search_events ->
        unless optional_string?(frame["item_id"]), do: malformed!(:hosted_item_identity)

      true ->
        malformed!(:unsupported_hosted_event)
    end

    {:ok, frame}
  rescue
    _ -> {:error, :provider_hosted_payload_rejected}
  end

  def project_event(_), do: {:error, :provider_hosted_payload_rejected}

  defp json_value?(value)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
       do: true

  defp json_value?(value) when is_list(value), do: Enum.all?(value, &json_value?/1)
  defp json_value?(%_struct{}), do: false

  defp json_value?(value) when is_map(value),
    do: Enum.all?(value, fn {key, item} -> is_binary(key) and json_value?(item) end)

  defp json_value?(_), do: false

  # This is the native host transport boundary, not an extension of the public
  # portable codec. Function/custom frames continue through that codec unchanged.
  def prepare!(model, context, options, base_url) do
    origin = %{
      "protocol" => "openai-responses",
      "provider" => model[:provider] || model["provider"],
      "model" => model[:id] || model["id"],
      "endpoint_sha256" => endpoint_fingerprint!(base_url)
    }

    tools = context[:tools] || []
    unless is_list(tools) and Enum.all?(tools, &is_map/1), do: invalid!(:hosted_tools)
    {hosted, local} = Enum.split_with(tools, &(&1[:type] in ["web_search", :web_search]))
    if length(hosted) > 1, do: invalid!(:duplicate_hosted_tool)
    if Enum.any?(local, &(not is_binary(&1[:name]))), do: invalid!(:unsupported_hosted_tool)

    config = options[:hosted_web_search]
    allowed = configuration!(config)

    if hosted != [] and (is_nil(allowed) or json!(hd(hosted), :request) != allowed),
      do: invalid!(:hosted_declaration_not_enabled)

    prepared = %{origin: origin, local_tools: local, hosted_tools: hosted, enabled: hosted != []}
    Enum.each(context.messages, &replay_items!(&1, prepared))
    prepared
  end

  def new(prepared),
    do: %{prepared: prepared, items: %{}, statuses: %{}, annotations: %{}, bytes: 0}

  def replay_items!(message, prepared) do
    metadata = Map.get(message, :metadata, %{})

    case if(is_map(metadata), do: Map.fetch(metadata, @key), else: :error) do
      :error ->
        nil

      {:ok, envelope} ->
        unless message[:role] == :assistant and is_map(envelope) and
                 Enum.sort(Map.keys(envelope)) == ~w(items origin response_id version),
               do: invalid!(:hosted_history)

        unless envelope["version"] == 1 and envelope["origin"] == prepared.origin and
                 optional_string?(envelope["response_id"]),
               do: invalid!(:hosted_history_origin)

        entries = envelope["items"]
        unless is_list(entries) and length(entries) <= @max_items, do: invalid!(:hosted_history)
        bounded!(envelope, :request)

        indexes =
          Enum.map(entries, fn
            %{"output_index" => index, "item" => item} = entry
            when map_size(entry) == 2 and
                   is_integer(index) and index >= 0 and is_map(item) ->
              index

            _ ->
              invalid!(:hosted_history)
          end)

        unless indexes == Enum.sort(Enum.uniq(indexes)), do: invalid!(:hosted_history_order)
        items = Enum.map(entries, & &1["item"])
        validate_items!(items, :request)

        unless signature!(items, :request) == canonical_signature(message),
          do: invalid!(:hosted_history_content)

        items
    end
  end

  def observe(
        state,
        %{"type" => type, "item" => %{"type" => "web_search_call"} = item} = frame,
        message
      )
      when type in ["response.output_item.added", "response.output_item.done"] do
    state = charge!(state, frame)
    index = index!(frame["output_index"])
    done? = type == "response.output_item.done"
    validate_search!(item, done?, :stream)
    previous = state.items[index]
    if previous && previous.done? && not done?, do: malformed!(:hosted_lifecycle_conflict)
    if previous && previous.done? && previous.item != item, do: malformed!(:hosted_item_conflict)
    if previous && changed?(previous.item, item, "id"), do: malformed!(:hosted_item_identity)

    if previous && changed?(previous.item, item, "action"),
      do: malformed!(:hosted_action_conflict)

    if Enum.any?(state.items, fn {other, value} ->
         other != index and is_binary(item["id"]) and value.item["id"] == item["id"]
       end),
       do: malformed!(:duplicate_hosted_identity)

    next = %{state | items: Map.put(state.items, index, %{item: item, done?: done?})}
    {[observation(frame, message)], message, next}
  end

  def observe(state, %{"type" => type, "item" => %{"type" => "message"} = item} = frame, message)
      when type == "response.output_item.done" do
    if state.prepared.enabled do
      state = charge!(state, frame)
      validate_message!(item, :stream)
      index = index!(frame["output_index"])

      if state.items[index] && state.items[index].item != item,
        do: malformed!(:hosted_item_conflict)

      {[], message, %{state | items: Map.put(state.items, index, %{item: item, done?: true})}}
    else
      {[], message, state}
    end
  end

  def observe(state, %{"type" => "response.output_text.annotation.added"} = frame, message) do
    state = charge!(state, frame)
    index = index!(frame["output_index"])
    content_index = index!(frame["content_index"])
    annotation_index = index!(frame["annotation_index"])
    validate_annotation!(frame["annotation"], :stream)

    unless is_binary(frame["item_id"]) and frame["item_id"] != "",
      do: malformed!(:hosted_annotation_identity)

    key = {index, content_index, annotation_index}
    observed = %{annotation: frame["annotation"], item_id: frame["item_id"]}

    if Map.has_key?(state.annotations, key) and state.annotations[key] != observed,
      do: malformed!(:hosted_annotation_conflict)

    {[], message, %{state | annotations: Map.put(state.annotations, key, observed)}}
  end

  def observe(state, %{"type" => type} = frame, message) when is_binary(type) do
    cond do
      String.starts_with?(type, "response.web_search_call.") ->
        state = charge!(state, frame)
        unless type in @search_events, do: malformed!(:unsupported_hosted_event)
        index = index!(frame["output_index"])
        unless optional_string?(frame["item_id"]), do: malformed!(:hosted_item_identity)
        previous = state.statuses[index]

        if previous &&
             (search_stage(previous["type"]) > search_stage(type) or
                (previous["type"] == "response.web_search_call.completed" and previous != frame)),
           do: malformed!(:hosted_lifecycle_conflict)

        if previous && changed?(previous, frame, "item_id"), do: malformed!(:hosted_item_identity)
        next = %{state | statuses: Map.put(state.statuses, index, frame)}
        {[observation(frame, message)], message, next}

      type in ["response.completed", "response.incomplete"] ->
        finish!(state, frame["response"], message)

      true ->
        {[], message, state}
    end
  end

  def observe(state, _frame, message), do: {[], message, state}

  defp finish!(state, response, message) do
    output = response["output"]
    hosted? = is_list(output) and Enum.any?(output, &(&1["type"] == "web_search_call"))

    retained? =
      map_size(state.items) > 0 or map_size(state.annotations) > 0 or map_size(state.statuses) > 0

    if hosted? or retained? or state.prepared.enabled do
      state = charge!(state, response)
      unless is_list(output), do: malformed!(:missing_hosted_output)

      # Replay replaces the assistant projection, so every output item must
      # survive in native order or fail validation. Filtering would silently
      # discard reasoning state needed by the next stateless request.
      entries =
        Enum.with_index(output, fn item, index ->
          %{"output_index" => index, "item" => item}
        end)

      items = Enum.map(entries, & &1["item"])
      validate_items!(items, :stream)
      by_index = Map.new(entries, &{&1["output_index"], &1["item"]})

      Enum.each(state.items, fn {index, observed} ->
        actual = by_index[index]

        unless actual && actual["type"] == observed.item["type"],
          do: malformed!(:missing_hosted_output)

        if (observed.done? && observed.item != actual) or changed?(observed.item, actual, "id") or
             changed?(observed.item, actual, "action"),
           do: malformed!(:hosted_item_conflict)
      end)

      Enum.each(state.statuses, fn {index, observed} ->
        actual = by_index[index]

        unless is_map(actual) and actual["type"] == "web_search_call" and
                 (is_nil(observed["item_id"]) or observed["item_id"] == actual["id"]),
               do: malformed!(:hosted_lifecycle_conflict)

        if observed["type"] == "response.web_search_call.completed" and
             actual["status"] == "failed",
           do: malformed!(:hosted_lifecycle_conflict)
      end)

      Enum.each(state.annotations, fn {{index, content_index, annotation_index}, observed} ->
        item = by_index[index]

        unless is_map(item) and item["type"] == "message" and item["id"] == observed.item_id,
          do: malformed!(:hosted_annotation_identity)

        actual =
          with %{"type" => "message", "content" => content} <- item,
               %{"annotations" => annotations} <- Enum.at(content, content_index),
               do: Enum.at(annotations, annotation_index)

        unless actual == observed.annotation, do: malformed!(:hosted_annotation_conflict)
      end)

      {text, calls} = signature!(items, :stream)
      {streamed, actual_calls} = canonical_signature(message)

      unless calls == actual_calls and String.starts_with?(text, streamed),
        do: malformed!(:hosted_output_content_conflict)

      suffix = binary_part(text, byte_size(streamed), byte_size(text) - byte_size(streamed))
      message = append_text(message, suffix)

      if message[:response_id] && response["id"] && message.response_id != response["id"],
        do: malformed!(:hosted_response_identity)

      unless optional_string?(response["id"]), do: malformed!(:hosted_response_identity)

      envelope = %{
        "version" => 1,
        "origin" => state.prepared.origin,
        "response_id" => response["id"] || message[:response_id],
        "items" => entries
      }

      bounded!(envelope, :stream)
      metadata = Map.put(Map.get(message, :metadata, %{}), @key, envelope)

      message =
        message
        |> Map.put(:metadata, metadata)
        |> Map.put(:response_id, envelope["response_id"])

      events =
        for %{"item" => %{"type" => "web_search_call"} = item, "output_index" => index} <-
              entries,
            is_nil(state.items[index]) or not state.items[index].done?,
            do:
              observation(
                %{"type" => "response.output_item.done", "output_index" => index, "item" => item},
                message
              )

      events =
        if suffix == "",
          do: events,
          else:
            events ++
              [
                %ProviderEvent{
                  type: :content_text_delta,
                  delta: suffix,
                  index: text_index(message),
                  message: message
                }
              ]

      {events, message, state}
    else
      {[], message, state}
    end
  end

  defp configuration!(nil), do: nil

  defp configuration!(config) when is_map(config) do
    unless Enum.all?(Map.keys(config), &is_atom/1) and
             Map.get(config, :supported, false) in [true, false] and
             Map.get(config, :enabled, false) in [true, false],
           do: invalid!(:hosted_configuration)

    if config[:enabled] == true do
      unless config[:supported] == true, do: invalid!(:hosted_support_not_configured)

      access =
        case config[:mode] do
          :cached -> %{"external_web_access" => false}
          :indexed -> %{"external_web_access" => true, "indexed_web_access" => true}
          :live -> %{"external_web_access" => true}
          _ -> invalid!(:hosted_mode)
        end

      unless config[:search_context_size] in [nil, "low", "medium", "high"],
        do: invalid!(:hosted_context_size)

      types = config[:search_content_types]

      unless is_nil(types) or
               (is_list(types) and types != [] and Enum.uniq(types) == types and
                  Enum.all?(types, &(&1 in ["text", "image"]))),
             do: invalid!(:hosted_content_types)

      unless Enum.all?([:filters, :user_location], &(is_nil(config[&1]) or is_map(config[&1]))),
        do: invalid!(:hosted_configuration)

      optional =
        config
        |> Map.take([:filters, :user_location, :search_context_size, :search_content_types])
        |> Map.reject(fn {_, value} -> is_nil(value) end)
        |> json!(:request)

      Map.merge(Map.put(access, "type", "web_search"), optional)
    end
  end

  defp configuration!(_), do: invalid!(:hosted_configuration)

  defp endpoint_fingerprint!(base_url) when is_binary(base_url) do
    uri = URI.parse(base_url <> "/responses")
    unless uri.scheme in ["http", "https"] and is_binary(uri.host), do: invalid!(:hosted_endpoint)
    # Match the destination the existing transport actually submits. Userinfo and
    # query participate in affinity but never appear in persisted provenance.
    normalized = %{
      uri
      | scheme: String.downcase(uri.scheme),
        host: String.downcase(uri.host),
        fragment: nil
    }

    :crypto.hash(:sha256, URI.to_string(normalized)) |> Base.encode16(case: :lower)
  rescue
    _ -> invalid!(:hosted_endpoint)
  end

  defp endpoint_fingerprint!(_), do: invalid!(:hosted_endpoint)

  defp validate_items!(items, kind) do
    unless length(items) <= @max_items, do: fail!(kind, :hosted_items_limit)

    Enum.each(items, fn
      %{"type" => "web_search_call"} = item ->
        validate_search!(item, true, kind)

      %{"type" => "message"} = item ->
        validate_message!(item, kind)

      %{"type" => "reasoning"} = item ->
        validate_reasoning!(item, kind)

      %{"type" => type} = item when type in ["function_call", "custom_tool_call"] ->
        unless optional_string?(item["id"]) and is_binary(item["call_id"]) and
                 item["call_id"] != "" and
                 is_binary(item["name"]) and item["name"] != "" and
                 optional_string?(item["namespace"]),
               do: fail!(kind, :hosted_history_call)

      _ ->
        fail!(kind, :hosted_history_item)
    end)

    ids = for item <- items, not is_nil(item["id"]), do: item["id"]
    unless ids == Enum.uniq(ids), do: fail!(kind, :duplicate_hosted_identity)
  end

  defp validate_reasoning!(item, kind) do
    unless optional_string?(item["id"]) and
             item["status"] in [nil, "completed", "incomplete", "in_progress"] and
             optional_string?(item["encrypted_content"]) and is_list(item["summary"]),
           do: fail!(kind, :hosted_reasoning_item)

    Enum.each(item["summary"], fn
      %{"type" => "summary_text", "text" => text} when is_binary(text) ->
        unless String.valid?(text), do: fail!(kind, :hosted_reasoning_summary)

      _ ->
        fail!(kind, :hosted_reasoning_summary)
    end)

    case item["content"] do
      nil ->
        :ok

      content when is_list(content) ->
        Enum.each(content, fn
          %{"type" => "reasoning_text", "text" => text} when is_binary(text) ->
            unless String.valid?(text), do: fail!(kind, :hosted_reasoning_content)

          _ ->
            fail!(kind, :hosted_reasoning_content)
        end)

      _ ->
        fail!(kind, :hosted_reasoning_content)
    end
  end

  defp validate_search!(item, terminal?, kind) do
    unless optional_string?(item["id"]) and
             item["status"] in [nil, "in_progress", "searching", "completed", "failed"],
           do: fail!(kind, :hosted_search_item)

    if terminal? and item["status"] not in [nil, "completed", "failed"],
      do: fail!(kind, :incomplete_hosted_search)

    case item["action"] do
      nil ->
        :ok

      %{"type" => "search"} = action ->
        unless optional_string?(action["query"]) and
                 (is_nil(action["queries"]) or
                    (is_list(action["queries"]) and Enum.all?(action["queries"], &is_binary/1))),
               do: fail!(kind, :hosted_search_action)

      %{"type" => "open_page"} = action ->
        unless optional_string?(action["url"]), do: fail!(kind, :hosted_search_action)

      %{"type" => "find_in_page"} = action ->
        unless optional_string?(action["url"]) and optional_string?(action["pattern"]),
          do: fail!(kind, :hosted_search_action)

      _ ->
        fail!(kind, :hosted_search_action)
    end
  end

  defp validate_message!(item, kind) do
    unless item["role"] == "assistant" and optional_string?(item["id"]) and
             is_list(item["content"]),
           do: fail!(kind, :hosted_message)

    Enum.each(item["content"], fn
      %{"type" => "output_text", "text" => text} = part when is_binary(text) ->
        annotations = Map.get(part, "annotations", [])
        unless is_list(annotations), do: fail!(kind, :hosted_annotations)

        Enum.each(annotations, fn annotation ->
          validate_annotation!(annotation, kind)

          unless annotation["end_index"] <= byte_size(text),
            do: fail!(kind, :hosted_annotation_range)
        end)

      _ ->
        fail!(kind, :hosted_message_content)
    end)
  end

  defp validate_annotation!(
         %{
           "type" => "url_citation",
           "url" => url,
           "title" => title,
           "start_index" => first,
           "end_index" => last
         },
         kind
       )
       when is_binary(url) and is_binary(title) and is_integer(first) and is_integer(last) and
              first >= 0 and last >= first do
    uri = URI.parse(url)

    unless uri.scheme in ["http", "https"] and is_binary(uri.host),
      do: fail!(kind, :hosted_citation_url)
  end

  defp validate_annotation!(_, kind), do: fail!(kind, :hosted_annotation)

  defp signature!(items, kind) do
    text =
      for %{"type" => "message", "content" => content} <- items,
          %{"type" => "output_text", "text" => text} <- content,
          into: "",
          do: text

    calls =
      for %{"type" => type} = item <- items, type in ["function_call", "custom_tool_call"] do
        name =
          if item["namespace"], do: item["namespace"] <> "::" <> item["name"], else: item["name"]

        if type == "custom_tool_call" do
          unless is_binary(item["input"]), do: fail!(kind, :hosted_history_call)
          {item["call_id"], name, :custom, item["input"]}
        else
          unless is_binary(item["arguments"]), do: fail!(kind, :hosted_history_call)

          case Jason.decode(item["arguments"]) do
            {:ok, arguments} when is_map(arguments) ->
              {item["call_id"], name, :function, arguments}

            _ ->
              fail!(kind, :hosted_history_call)
          end
        end
      end

    {text, calls}
  end

  defp canonical_signature(message) do
    content = message[:content] || []
    unless is_list(content), do: invalid!(:hosted_history_content)
    text = for %{type: :text, text: text} <- content, into: "", do: text

    calls =
      for %{type: :tool_call} = call <- content,
          do: {call.id, call.name, Map.get(call, :input_kind, :function), call.arguments}

    {text, calls}
  end

  defp append_text(message, ""), do: message

  defp append_text(message, suffix) do
    case Enum.find_index(message.content, &(&1[:type] == :text)) do
      nil ->
        %{message | content: message.content ++ [%{type: :text, text: suffix}]}

      index ->
        %{
          message
          | content:
              List.update_at(
                message.content,
                index,
                &Map.update!(&1, :text, fn text -> text <> suffix end)
              )
        }
    end
  end

  defp text_index(message), do: Enum.find_index(message.content, &(&1[:type] == :text))

  defp observation(frame, message),
    do: %ProviderEvent{
      type: :provider_hosted_event,
      capability: "web_search",
      event: frame,
      message: message
    }

  defp changed?(before, after_item, key),
    do: not is_nil(before[key]) and before[key] != after_item[key]

  defp optional_string?(nil), do: true
  defp optional_string?(value), do: is_binary(value) and value != "" and String.valid?(value)
  defp index!(index) when is_integer(index) and index >= 0 and index < @max_items, do: index
  defp index!(_), do: malformed!(:hosted_output_index)
  defp search_stage("response.web_search_call.in_progress"), do: 0
  defp search_stage("response.web_search_call.searching"), do: 1
  defp search_stage("response.web_search_call.completed"), do: 2

  defp charge!(state, value) do
    unless state.prepared.enabled, do: malformed!(:unsolicited_hosted_output)
    bytes = state.bytes + byte_size(Jason.encode!(value))
    if bytes > @max_bytes, do: malformed!(:hosted_output_limit)
    %{state | bytes: bytes}
  end

  defp bounded!(value, kind) do
    case Jason.encode(value) do
      {:ok, encoded} when byte_size(encoded) <= @max_bytes -> :ok
      _ -> fail!(kind, :hosted_output_limit)
    end
  end

  defp json!(value, kind) do
    case Jason.encode(value) do
      {:ok, encoded} when byte_size(encoded) <= @max_bytes -> Jason.decode!(encoded)
      _ -> fail!(kind, :hosted_configuration)
    end
  end

  defp fail!(:request, reason), do: invalid!(reason)
  defp fail!(:stream, reason), do: malformed!(reason)

  defp invalid!(reason),
    do:
      raise(ProviderError,
        kind: :invalid_request,
        message: "Invalid hosted Responses request: #{reason}",
        retryable: false
      )

  defp malformed!(reason), do: raise(ProviderError.malformed(reason))
end
