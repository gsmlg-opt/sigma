defmodule Sigma.Agent.Terminals.Subsystem do
  @moduledoc "Fail-stop terminal branch isolated from the core session restart budget."

  use Supervisor

  alias Sigma.Agent.Terminals.{Identity, Manager}

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: Keyword.get(opts, :shutdown, 10_000),
      type: :supervisor
    }
  end

  @impl true
  def init(opts) do
    worker_supervisor = Keyword.fetch!(opts, :worker_supervisor)
    manager_name = Keyword.fetch!(opts, :manager_name)
    session = Keyword.fetch!(opts, :session)

    manager_opts =
      opts
      |> Keyword.take([:limits, :ledger, :backend, :backend_opts, :id_generator, :clock])
      |> Keyword.merge(session: session, name: manager_name, worker_supervisor: worker_supervisor)

    children = [
      %{
        id: :terminal_workers,
        start:
          {DynamicSupervisor, :start_link, [[name: worker_supervisor, strategy: :one_for_one]]},
        restart: :permanent,
        type: :supervisor
      },
      %{id: :terminal_manager, start: {Manager, :start_link, [manager_opts]}, restart: :permanent}
    ]

    Supervisor.init(children, strategy: :one_for_all, max_restarts: 0)
  end

  def session(repository_id, session_id, incarnation_id),
    do: Identity.session(repository_id, session_id, incarnation_id)
end
