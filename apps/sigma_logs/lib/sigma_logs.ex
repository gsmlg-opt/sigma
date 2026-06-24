defmodule Sigma.Logs do
  def start_session(session_id), do: Sigma.Logs.BufferSupervisor.start_session(session_id)
  def stop_session(session_id), do: Sigma.Logs.BufferSupervisor.stop_session(session_id)
  def all(session_id), do: Sigma.Logs.Buffer.all(session_id)
  def search(session_id, opts \\ []), do: Sigma.Logs.Buffer.search(session_id, opts)
end
