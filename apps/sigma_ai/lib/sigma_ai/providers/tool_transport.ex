defmodule Sigma.Ai.Providers.ToolTransport do
  @moduledoc false

  alias Sigma.Ai.ProviderError

  # These protocols have no lossless native custom/namespace representation.
  # TODO(upstream): gsmlg-opt/backplane#160 — adopt the Anthropic projection once published.
  # Reject declarations and replay alike before constructing a network request.
  def require_json_functions!(context, protocol) do
    tools = context[:tools] || []

    if Enum.any?(context.messages, fn message ->
         metadata = Map.get(message, :metadata, %{})
         is_map(metadata) and Map.has_key?(metadata, "openai_responses_hosted")
       end) do
      raise ProviderError,
        kind: :invalid_request,
        message: "#{protocol} does not support hosted Responses history; use OpenAI Responses",
        retryable: false
    end

    calls =
      for %{role: :assistant, content: content} <- context.messages,
          is_list(content),
          %{type: :tool_call} = call <- content,
          do: call

    if Enum.any?(tools ++ calls, &native_tool?/1) do
      raise ProviderError,
        kind: :invalid_request,
        message:
          "#{protocol} does not support native custom tools, tool namespaces, or output schemas; use OpenAI Responses",
        retryable: false
    end

    if Enum.any?(calls, fn call ->
         call[:input_kind] not in [nil, :function] or not is_map(call[:arguments])
       end) do
      raise ProviderError,
        kind: :invalid_request,
        message: "#{protocol} function tool arguments must be a structured JSON object",
        retryable: false
    end
  end

  defp native_tool?(tool) do
    tool[:type] in [:custom, "custom", :web_search, "web_search"] or tool[:input_kind] == :custom or
      not is_nil(tool[:output_schema]) or
      (is_binary(tool[:name]) and String.contains?(tool.name, "::"))
  end
end
