defmodule Sigma.Coding do
  @moduledoc """
  Main entry point for the Sigma.Coding application.
  Starts the dispatcher supervisor and the MCP client registry/supervisor.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Sigma.Coding.Dispatcher,
      {Registry, keys: :unique, name: Sigma.Coding.MCP.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Sigma.Coding.MCP.ClientSupervisor}
    ]

    opts = [strategy: :one_for_one, name: Sigma.Coding.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
