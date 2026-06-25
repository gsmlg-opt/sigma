defmodule Sigma.Ai.ProviderAuth do
  @moduledoc false

  def headers(api_key, options, default_type) do
    auth_type = normalize_auth_type(options[:auth_type], default_type)
    [{header_name(auth_type, options, default_type), header_value(auth_type, api_key)}]
  end

  defp normalize_auth_type(value, fallback) do
    normalize_auth_type_value(value) || normalize_auth_type_value(fallback) || "x-api-key"
  end

  defp normalize_auth_type_value(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> normalize_auth_type_value()
  end

  defp normalize_auth_type_value(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "x-api-key" -> "x-api-key"
      "x_api_key" -> "x-api-key"
      "bearer" -> "bearer"
      "bearer_token" -> "bearer"
      "bearer token" -> "bearer"
      "custom" -> "custom_header"
      "custom_header" -> "custom_header"
      "custom header" -> "custom_header"
      _ -> nil
    end
  end

  defp normalize_auth_type_value(_value), do: nil

  defp header_name("bearer", _options, _default_type), do: "Authorization"
  defp header_name("x-api-key", _options, _default_type), do: "x-api-key"

  defp header_name("custom_header", options, default_type) do
    case trim_option(options[:auth_header_name]) do
      "" -> default_header_name(default_type)
      name -> name
    end
  end

  defp default_header_name(default_type) do
    case normalize_auth_type_value(default_type) do
      "bearer" -> "Authorization"
      _ -> "x-api-key"
    end
  end

  defp header_value("bearer", api_key), do: "Bearer #{api_key || ""}"
  defp header_value(_auth_type, api_key), do: api_key || ""

  defp trim_option(value) when is_binary(value), do: String.trim(value)
  defp trim_option(_value), do: ""
end
