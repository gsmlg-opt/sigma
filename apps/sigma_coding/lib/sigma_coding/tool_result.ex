defmodule Sigma.Coding.ToolResult do
  @moduledoc "Normalized successful tool result."

  @enforce_keys [:content]
  defstruct [:content, details: %{}, is_error: false, terminate: false]

  @type t :: %__MODULE__{
          content: [map()],
          details: term(),
          is_error: boolean(),
          terminate: boolean()
        }

  alias Sigma.Coding.{ToolError, ToolUpdate}

  def normalize({:ok, %__MODULE__{} = result}), do: {:ok, result}
  def normalize({:error, %ToolError{} = error}), do: {:error, error}

  def normalize({:ok, result}) when is_map(result) do
    with {:ok, content} <- normalize_content(Map.get(result, :content, Map.get(result, "content"))) do
      {:ok,
       %__MODULE__{
         content: content,
         details: Map.get(result, :details, Map.get(result, "details", %{})),
         is_error: Map.get(result, :is_error, Map.get(result, "is_error", false)) == true,
         terminate: Map.get(result, :terminate, Map.get(result, "terminate", false)) == true
       }}
    else
      {:error, reason} -> {:error, ToolError.new(:malformed_result, reason)}
    end
  end

  def normalize({:error, reason}), do: {:error, ToolError.new(:execution, reason)}
  def normalize(nil), do: {:error, ToolError.new(:malformed_result, :empty_result)}
  def normalize(other), do: {:error, ToolError.new(:malformed_result, {:unknown_result, other})}

  def normalize_update(tool_call_id, sequence, raw_update) do
    case normalize({:ok, raw_update}) do
      {:ok, result} ->
        {:ok,
         %ToolUpdate{
           tool_call_id: tool_call_id,
           sequence: sequence,
           content: result.content,
           details: result.details
         }}

      {:error, _reason} = error ->
        error
    end
  end

  defp normalize_content(content) when is_binary(content),
    do: {:ok, [%{type: :text, text: content}]}

  defp normalize_content(content) when is_list(content) do
    if Enum.all?(content, &valid_content_block?/1) do
      {:ok, content}
    else
      {:error, :invalid_content}
    end
  end

  defp normalize_content(_content), do: {:error, :missing_content}

  defp valid_content_block?(%{type: :text, text: text}) when is_binary(text), do: true
  defp valid_content_block?(%{"type" => "text", "text" => text}) when is_binary(text), do: true

  defp valid_content_block?(%{type: :image, data: data, mime_type: mime_type})
       when is_binary(data) and is_binary(mime_type),
       do: true

  defp valid_content_block?(%{"type" => "image", "data" => data, "mime_type" => mime_type})
       when is_binary(data) and is_binary(mime_type),
       do: true

  defp valid_content_block?(_block), do: false
end
