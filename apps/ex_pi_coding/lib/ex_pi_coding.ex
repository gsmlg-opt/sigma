defmodule PiCoding do
  @moduledoc """
  Main entry point for the PiCoding application.
  Starts the dispatcher supervisor and the MCP client registry/supervisor.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PiCoding.Dispatcher,
      {Registry, keys: :unique, name: PiCoding.MCP.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: PiCoding.MCP.ClientSupervisor}
    ]

    opts = [strategy: :one_for_one, name: PiCoding.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
