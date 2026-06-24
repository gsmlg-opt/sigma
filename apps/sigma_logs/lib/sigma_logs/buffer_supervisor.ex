defmodule Sigma.Logs.BufferSupervisor do
  def start_session(session_id) do
    DynamicSupervisor.start_child(
      __MODULE__,
      {Sigma.Logs.Buffer, session_id: session_id}
    )
  end

  def stop_session(session_id) do
    case GenServer.whereis({:via, Registry, {Sigma.Logs.Registry, session_id}}) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end
end
