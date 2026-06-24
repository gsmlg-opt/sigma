defmodule Sigma.Logs.Application do
  use Application

  @impl true
  def start(_type, _args) do
    Sigma.Logs.Entry.init_counter()

    children = [
      {Registry, keys: :unique, name: Sigma.Logs.Registry},
      {DynamicSupervisor, name: Sigma.Logs.BufferSupervisor, strategy: :one_for_one}
    ]

    result = Supervisor.start_link(children, strategy: :one_for_one, name: Sigma.Logs.Supervisor)
    Sigma.Logs.Handler.attach_all()
    result
  end
end
