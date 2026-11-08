defmodule Sigma.Ai.Providers.ProtocolRequest do
  @moduledoc false

  # Pure Sigma context -> provider-neutral Backplane Request projection shared by
  # providers that delegate native tool identity to the public protocol codec.
  # The protocol package deliberately does not own HTTP transport or credentials.

  alias Backplane.AiProtocol.Request

  @doc """
  Builds a validated `Backplane.AiProtocol.Request`.

  Options:
    * `:output_schema_extension` - extension key carrying a tool's output schema.
    * `:reasoning` - `:structured` (`%{text: ...}` data) or `:text` (binary data).
  """
  def build(model, context, opts) do
    input =
      [system_message(context[:system] || context[:system_prompt]) | context.messages]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&message(&1, opts))

    Request.new(%{
      model: model.id,
      input: input,
      tools: Enum.map(context[:tools] || [], &tool(&1, opts)),
      settings: %{}
    })
  end

  @doc "True when a context declares or replays native custom/namespaced/output-schema tools."
  def native_tools?(context) do
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

  def system_text(nil), do: nil
  def system_text(""), do: nil
  def system_text(text) when is_binary(text), do: text

  def system_text(blocks) when is_list(blocks) do
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

  defp system_message(system) do
    case system_text(system) do
      nil -> nil
      text -> %{role: :system, content: [%{type: :text, text: text}]}
    end
  end

  defp message(%{role: role, content: content}, opts) when role in [:user, :system, :assistant],
    do: %{role: role, content: content(content, opts)}

  defp message(%{role: :tool_result, tool_call_id: id, content: content}, opts) do
    # A silent tool still has a result; the canonical protocol represents its
    # empty output with no content blocks, while the wire output remains "".
    blocks =
      content
      |> content(opts)
      |> Enum.reject(&match?(%{type: :text, text: ""}, &1))

    %{role: :tool, tool_call_id: id, content: blocks}
  end

  defp message(_message, _opts), do: %{role: :invalid, content: []}

  defp content(content, _opts) when is_binary(content),
    do: [%{type: :text, text: content}]

  defp content(content, opts) when is_list(content),
    do: Enum.map(content, &block(&1, opts))

  defp content(_content, _opts), do: [%{type: :invalid}]

  defp block(%{type: :text, text: text}, _opts),
    do: %{type: :text, text: text}

  defp block(%{type: :image, data: data, mime_type: mime} = image, _opts),
    do: %{
      type: :image,
      data: maybe_put(%{"data" => data, "mime_type" => mime}, "detail", image[:detail])
    }

  defp block(%{type: :thinking, thinking: thinking}, opts) do
    case Keyword.get(opts, :reasoning, :structured) do
      :text -> %{type: :reasoning, data: thinking}
      :structured -> %{type: :reasoning, data: %{text: thinking}}
    end
  end

  defp block(%{type: :tool_call, id: id, name: name, arguments: arguments} = call, _opts) do
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

  defp block(_block, _opts), do: %{type: :invalid}

  defp tool(tool, opts) do
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
          do: %{Keyword.fetch!(opts, :output_schema_extension) => tool.output_schema},
          else: %{}
        )
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
