defmodule PiWeb.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: PiWeb.SessionRegistry},
      {Phoenix.PubSub, name: PiWeb.PubSub},
      {DynamicSupervisor, name: PiWeb.AgentSupervisor, strategy: :one_for_one},
      PiWeb.SessionManager,
      PiWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: PiWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    PiWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
