defmodule PiCoding do
  @moduledoc """
  Main entry point for the PiCoding application.
  Starts the dispatcher supervisor.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PiCoding.Dispatcher
    ]

    opts = [strategy: :one_for_one, name: PiCoding.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
