defmodule Sigma.Web.SamgitaHost.ThreadId do
  @moduledoc """
  Codec for samgita_protocol thread ids.

  A thread id is `<base64url(repo_path)>.<session_id>`. Later protocol requests
  carry only the thread id, so it must name the registered repository the
  session lives in. The split is at the first `.`; base64url never emits one,
  so session ids may contain dots.
  """

  alias Sigma.Session.{ConfigManager, RepoManager}

  @type decoded :: %{repo_path: String.t(), sessions_dir: String.t(), session_id: String.t()}

  @spec encode(String.t(), String.t()) :: String.t()
  def encode(repo_path, session_id) do
    Base.url_encode64(repo_path, padding: false) <> "." <> session_id
  end

  @spec decode(term()) :: {:ok, decoded()} | {:error, :not_found}
  def decode(thread_id) when is_binary(thread_id) do
    with [encoded, session_id] when encoded != "" and session_id != "" <-
           String.split(thread_id, ".", parts: 2),
         {:ok, path} <- Base.url_decode64(encoded, padding: false),
         {:ok, repo_path} <- registered(path) do
      {:ok,
       %{
         repo_path: repo_path,
         sessions_dir: ConfigManager.ensure_sessions_dir(repo_path),
         session_id: session_id
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  def decode(_), do: {:error, :not_found}

  @spec repository(term()) :: {:ok, String.t()} | {:error, :invalid_params}
  def repository(path) when is_binary(path) do
    with :absolute <- Path.type(path),
         {:ok, repo_path} <- registered(path) do
      {:ok, repo_path}
    else
      _ -> {:error, :invalid_params}
    end
  end

  def repository(_), do: {:error, :invalid_params}

  defp registered(path) do
    case RepoManager.get_repo(path) do
      %{"path" => repo_path} -> {:ok, Path.expand(repo_path)}
      nil -> :error
    end
  end
end
