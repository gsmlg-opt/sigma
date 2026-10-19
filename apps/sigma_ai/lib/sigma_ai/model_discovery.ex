defmodule Sigma.Ai.ModelDiscovery do
  @moduledoc "Discovers model descriptors from a saved provider connection."

  alias Sigma.Ai.ProviderAuth

  @max_pages 20
  @openai_apis ["openai", "openai-responses", "openai-completions"]

  def discover(config, opts \\ []) do
    api = config["api_type"] || "anthropic"

    with true <- api in ["anthropic" | @openai_apis],
         {:ok, url} <- models_url(config["base_url"], api) do
      auth = [auth_type: config["auth_type"], auth_header_name: config["auth_header_name"]]

      headers =
        ProviderAuth.headers(
          config["resolved_key"],
          auth,
          if(api == "anthropic", do: "x-api-key", else: "bearer")
        )

      headers =
        if api == "anthropic", do: [{"anthropic-version", "2023-06-01"} | headers], else: headers

      fetch(url, headers, opts, nil, MapSet.new(), [], @max_pages)
    else
      false -> {:error, :unsupported}
      error -> error
    end
  end

  defp models_url(value, api) when is_binary(value) do
    uri = URI.parse(String.trim(value))

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
         is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) do
      path = String.trim_trailing(uri.path || "", "/")

      suffix =
        if api == "anthropic" and not String.ends_with?(path, "/v1"),
          do: "/v1/models",
          else: "/models"

      {:ok, URI.to_string(%{uri | path: path <> suffix})}
    else
      {:error, :invalid_url}
    end
  rescue
    ArgumentError -> {:error, :invalid_url}
  end

  defp models_url(_, _), do: {:error, :invalid_url}

  defp fetch(_url, _headers, _opts, _cursor, _seen, _models, 0), do: {:error, :invalid_response}

  defp fetch(url, headers, opts, cursor, seen, models, remaining) do
    params = if cursor, do: [after_id: cursor], else: []

    options =
      Keyword.merge(opts,
        url: url,
        headers: headers,
        params: params,
        retry: false,
        redirect: false
      )

    options = Keyword.put_new(options, :receive_timeout, 15_000)

    case Req.get(options) do
      {:ok, %{status: 200, body: %{"data" => data} = body}} when is_list(data) ->
        models = models ++ Enum.flat_map(data, &descriptor/1)

        case body["has_more"] do
          true ->
            next = nonblank(body["last_id"])

            if next && not MapSet.member?(seen, next) do
              fetch(url, headers, opts, next, MapSet.put(seen, next), models, remaining - 1)
            else
              {:error, :invalid_response}
            end

          value when value in [false, nil] ->
            {:ok, Enum.uniq_by(models, & &1["id"])}

          _ ->
            {:error, :invalid_response}
        end

      {:ok, %{status: 200}} ->
        {:error, :invalid_response}

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: 403}} ->
        {:error, :forbidden}

      {:ok, %{status: status}} when status in [404, 405, 501] ->
        {:error, :unsupported}

      {:ok, _response} ->
        {:error, :unavailable}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp descriptor(%{"id" => id} = model) do
    case nonblank(id) do
      nil ->
        []

      id ->
        descriptor = %{
          "id" => id,
          "name" => nonblank(model["name"]) || nonblank(model["display_name"]) || id
        }

        window = model["contextWindow"] || model["context_window"]

        descriptor =
          if is_integer(window) and window > 0,
            do: Map.put(descriptor, "contextWindow", window),
            else: descriptor

        [descriptor]
    end
  end

  defp descriptor(_), do: []

  defp nonblank(value) when is_binary(value),
    do: if(String.trim(value) != "", do: String.trim(value))

  defp nonblank(_), do: nil
end
