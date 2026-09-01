defmodule Sigma.Ai.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(
      [{Task.Supervisor, name: Sigma.Ai.ProviderTaskSupervisor}],
      strategy: :one_for_one,
      name: Sigma.Ai.Supervisor
    )
  end
end
