defmodule PiLogs.BufferSupervisor do
  def start_session(session_id) do
    DynamicSupervisor.start_child(
      __MODULE__,
      {PiLogs.Buffer, session_id: session_id}
    )
  end

  def stop_session(session_id) do
    case GenServer.whereis({:via, Registry, {PiLogs.Registry, session_id}}) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end
end
