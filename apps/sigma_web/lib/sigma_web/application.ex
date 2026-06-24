defmodule Sigma.Web.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Sigma.Web.PubSub},
      {DynamicSupervisor, name: Sigma.Web.WebShellSupervisor, strategy: :one_for_one},
      Sigma.Web.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Sigma.Web.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    Sigma.Web.Endpoint.config_change(changed, removed)
    :ok
  end
end
