defmodule Sigma.Web.AgentSocket do
  @moduledoc "Protocol V1 WebSocket entrypoint for registered repositories."

  use Phoenix.Socket

  alias Sigma.Session.{ConfigManager, RepoManager}

  channel "session:*", Sigma.Web.SessionChannel

  @impl true
  def connect(%{"repository" => encoded_repository, "token" => token}, socket, _connect_info) do
    with :ok <- authenticate(token),
         {:ok, workdir} <- Base.url_decode64(encoded_repository, padding: false),
         %{} = repo <- RepoManager.get_repo(workdir) do
      workdir = Path.expand(repo["path"])

      {:ok,
       socket
       |> assign(:workdir, workdir)
       |> assign(:sessions_dir, ConfigManager.ensure_sessions_dir(workdir))}
    else
      _reason -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(_socket), do: nil

  defp authenticate(token) when is_binary(token) do
    expected =
      Application.get_env(:sigma_web, :protocol_token) || System.get_env("SIGMA_PROTOCOL_TOKEN")

    if is_binary(expected) and byte_size(expected) >= 32 and byte_size(token) == byte_size(expected) and
         Plug.Crypto.secure_compare(token, expected) do
      :ok
    else
      :error
    end
  end

  defp authenticate(_token), do: :error
end
