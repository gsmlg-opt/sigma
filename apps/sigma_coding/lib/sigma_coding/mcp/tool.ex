defmodule Sigma.Coding.MCP.Tool do
  @moduledoc """
  Runtime tool descriptor discovered from an MCP server.

  `client` is the address of the live `Backplane.McpProtocol.Client` process
  (a `:via` tuple) that owns the persistent connection to the server. Tool
  calls are routed to that client.

  A host-owned plugin may provide `call_tool`, an arity-three callback over its
  public plugin Session. It returns the same raw MCP result envelope and keeps
  result normalization and Dispatcher hooks shared with connected MCP tools.
  """

  defstruct [
    :name,
    :description,
    :schema,
    :server_id,
    :client,
    :server_tool_name,
    :call_tool
  ]
end
