defmodule PiCoding.MCP do
  @moduledoc """
  Discovers and executes tools exposed by configured MCP servers.
  """

  alias PiCoding.MCP.Client
  alias PiCoding.MCP.Tool

  def tools_for_servers(servers, opts \\ []) when is_map(servers) do
    servers
    |> Enum.flat_map(fn {server_id, server} ->
      case Client.list_tools(server, opts) do
        {:ok, tools} ->
          Enum.map(tools, &to_tool(server_id, server, &1))

        {:error, reason} ->
          :telemetry.execute(
            [:ex_pi, :mcp, :server, :error],
            %{system_time: System.system_time()},
            %{server_id: server_id, reason: inspect(reason)}
          )

          []
      end
    end)
  end

  def call_tool(%Tool{} = tool, _tool_call_id, params, opts) do
    case Client.call_tool(tool.server, tool.server_tool_name, params, opts) do
      {:ok, result} ->
        {:ok,
         %{
           content: normalize_content(result["content"]),
           details: result,
           is_error: result["isError"] == true
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp to_tool(server_id, server, mcp_tool) do
    server_tool_name = mcp_tool["name"] || ""

    %Tool{
      name: tool_name(server_id, server_tool_name),
      description: mcp_tool["description"] || "MCP tool #{server_id}/#{server_tool_name}",
      schema: mcp_tool["inputSchema"] || %{"type" => "object", "properties" => %{}},
      server_id: server_id,
      server: server,
      server_tool_name: server_tool_name
    }
  end

  defp tool_name(server_id, tool_name) do
    "mcp__#{tool_safe_name(server_id, 20)}__#{tool_safe_name(tool_name, 36)}"
  end

  defp tool_safe_name(value, max_length) do
    safe =
      value
      |> to_string()
      |> String.replace(~r/[^A-Za-z0-9_-]/, "_")

    if String.length(safe) <= max_length do
      safe
    else
      hash = :crypto.hash(:sha256, safe) |> Base.encode16(case: :lower) |> String.slice(0, 6)

      safe
      |> String.slice(0, max_length - 7)
      |> then(&"#{&1}_#{hash}")
    end
  end

  defp normalize_content(content) when is_list(content) do
    Enum.map(content, &normalize_content_block/1)
  end

  defp normalize_content(content) when is_binary(content) do
    [%{type: :text, text: content}]
  end

  defp normalize_content(_), do: []

  defp normalize_content_block(%{"type" => "text", "text" => text}) do
    %{type: :text, text: text}
  end

  defp normalize_content_block(%{"type" => "image", "data" => data, "mimeType" => mime_type}) do
    %{type: :image, data: data, mime_type: mime_type}
  end

  defp normalize_content_block(%{"type" => "image", "data" => data, "mime_type" => mime_type}) do
    %{type: :image, data: data, mime_type: mime_type}
  end

  defp normalize_content_block(block) do
    %{type: :text, text: inspect(block)}
  end
end
