defmodule PiCoding.MCP.Tool do
  @moduledoc """
  Runtime tool descriptor discovered from an MCP server.
  """

  defstruct [
    :name,
    :description,
    :schema,
    :server_id,
    :server,
    :server_tool_name
  ]
end
