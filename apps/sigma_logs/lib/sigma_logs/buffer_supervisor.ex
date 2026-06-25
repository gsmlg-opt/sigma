defmodule Sigma.Logs.BufferSupervisor do
  def start_session(qualified_session_id) do
    DynamicSupervisor.start_child(
      __MODULE__,
      {Sigma.Logs.Buffer, session_id: qualified_session_id}
    )
  end

  def stop_session(qualified_session_id) do
    case GenServer.whereis({:via, Registry, {Sigma.Logs.Registry, qualified_session_id}}) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end
end
