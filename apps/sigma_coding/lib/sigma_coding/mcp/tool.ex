defmodule Sigma.Coding.MCP.Tool do
  @moduledoc """
  Runtime tool descriptor discovered from an MCP server.

  `client` is the address of the live `Anubis.Client` process (a `:via`
  tuple) that owns the persistent connection to the server. Tool calls are
  routed to that client.
  """

  defstruct [
    :name,
    :description,
    :schema,
    :server_id,
    :client,
    :server_tool_name
  ]
end
