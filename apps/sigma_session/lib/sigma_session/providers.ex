defmodule Sigma.Session.Providers do
  @moduledoc "Resolve explicitly configured shared connections for each service."
  alias Sigma.Session.ConfigManager

  def resolve_service(provider_id, service) when service in [:mcp, :skills] do
    ConfigManager.transaction(fn ->
      case ConfigManager.get_config()["providers"][provider_id] do
        %{"kind" => "backplane"} = provider ->
          origin = String.trim_trailing(String.trim(provider["service_origin"] || ""), "/")
          credential_id = provider["credential_id"] || ""

          cond do
            not valid_origin?(origin) ->
              {:error, :invalid_service_origin}

            not ConfigManager.credential_available?(credential_id) ->
              {:error, :credential_unavailable}

            true ->
              {:ok,
               %{
                 provider_id: provider_id,
                 kind: "backplane",
                 service: service,
                 origin: origin,
                 url: if(service == :mcp, do: origin <> "/mcp", else: origin),
                 credential_id: credential_id,
                 credential_supplier: ConfigManager.credential_supplier(credential_id),
                 auth_type: "bearer",
                 auth_header_name: "authorization"
               }}
          end

        nil ->
          {:error, :provider_unavailable}

        _ ->
          {:error, :service_unavailable}
      end
    end)
  end

  def valid_http_url?(url) when is_binary(url) do
    uri = URI.parse(url)

    uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
      is_nil(uri.userinfo) and is_nil(uri.fragment)
  end

  def valid_http_url?(_), do: false

  defp valid_origin?(origin) do
    uri = URI.parse(origin)
    valid_http_url?(origin) and uri.path in [nil, "", "/"] and is_nil(uri.query)
  end

  def auth_headers(service) do
    case service.credential_supplier.() do
      key when is_binary(key) and key != "" -> %{"authorization" => "Bearer " <> key}
      _ -> %{}
    end
  end
end
