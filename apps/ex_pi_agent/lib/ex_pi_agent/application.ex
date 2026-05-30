defmodule PiAgent.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: PiAgent.RepositoryRegistry},
      {DynamicSupervisor, name: PiAgent.DynamicSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: PiAgent.Supervisor)
  end
end
