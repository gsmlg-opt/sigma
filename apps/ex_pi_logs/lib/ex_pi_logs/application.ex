defmodule PiLogs.Application do
  use Application

  @impl true
  def start(_type, _args) do
    PiLogs.Entry.init_counter()

    children = [
      {Registry, keys: :unique, name: PiLogs.Registry},
      {DynamicSupervisor, name: PiLogs.BufferSupervisor, strategy: :one_for_one}
    ]

    result = Supervisor.start_link(children, strategy: :one_for_one, name: PiLogs.Supervisor)
    PiLogs.Handler.attach_all()
    result
  end
end
