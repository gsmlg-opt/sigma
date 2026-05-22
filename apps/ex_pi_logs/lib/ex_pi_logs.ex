defmodule PiLogs do
  def start_session(session_id), do: PiLogs.BufferSupervisor.start_session(session_id)
  def stop_session(session_id), do: PiLogs.BufferSupervisor.stop_session(session_id)
  def all(session_id), do: PiLogs.Buffer.all(session_id)
  def search(session_id, opts \\ []), do: PiLogs.Buffer.search(session_id, opts)
end
