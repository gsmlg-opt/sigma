defmodule Sigma.Agent.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Sigma.Agent.RepositoryRegistry},
      {Registry, keys: :unique, name: Sigma.Agent.ProtocolSubscriptionRegistry},
      {DynamicSupervisor,
       name: Sigma.Agent.ProtocolSubscriptionSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Sigma.Agent.DynamicSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Sigma.Agent.Supervisor)
  end
end
