defmodule PiWeb.SessionManager do
  @moduledoc """
  Compatibility facade for the repository-owned `PiAgent.Runtime`.
  """

  def get_agent(session_id, opts \\ []) when is_binary(session_id) do
    repo_path =
      Keyword.get(opts, :repo_path) || Keyword.get(opts, :workdir) || Keyword.get(opts, :cwd) ||
        File.cwd!()

    if is_binary(repo_path) do
      case PiAgent.Runtime.get_session(repo_path, session_id, opts) do
        {:ok, %{agent: agent, policy: policy}} -> {:ok, {agent, policy}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :missing_repo_path}
    end
  end
end
