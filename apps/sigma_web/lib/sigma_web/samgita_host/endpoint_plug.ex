defmodule Sigma.Web.SamgitaHost.EndpointPlug do
  @moduledoc """
  Mounts the samgita_protocol WebSocket host at exactly `/app-server`.

  Other paths pass through untouched (the upstream plug would answer them 404).
  Authentication reuses the Protocol V1 bearer token (`SIGMA_PROTOCOL_TOKEN`).
  """
  @behaviour Plug

  alias Sigma.Web.ProtocolToken
  alias Sigma.Web.SamgitaHost.Handler

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{request_path: "/app-server"} = conn, _opts) do
    SamgitaProtocolWebSocket.Plug.call(conn,
      authenticate: &authenticate/1,
      handler: Handler,
      handler_state: &Handler.state/1
    )
  end

  def call(conn, _opts), do: conn

  defp authenticate(token) do
    case ProtocolToken.verify(token) do
      :ok -> {:ok, :sigma_protocol_token}
      :error -> {:error, :unauthorized}
    end
  end
end
