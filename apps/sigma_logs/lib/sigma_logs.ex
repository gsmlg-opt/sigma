defmodule Sigma.Logs do
  def session_key(repo_key, session_id), do: "#{repo_key}:#{session_id}"

  def start_session(qualified_session_id),
    do: Sigma.Logs.BufferSupervisor.start_session(qualified_session_id)

  def stop_session(qualified_session_id), do: Sigma.Logs.BufferSupervisor.stop_session(qualified_session_id)
  def all(qualified_session_id), do: Sigma.Logs.Buffer.all(qualified_session_id)
  def search(qualified_session_id, opts \\ []), do: Sigma.Logs.Buffer.search(qualified_session_id, opts)
end
