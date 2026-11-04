defmodule Sigma.Agent.Backplane.HostedTools do
  @moduledoc false

  alias Backplane.AgentRuntime.{Codex.Hosted, Error}
  alias Sigma.Ai.Providers.OpenAIResponses

  @keys %{
    "supported" => :supported,
    "enabled" => :enabled,
    "mode" => :mode,
    "filters" => :filters,
    "userLocation" => :user_location,
    "searchContextSize" => :search_context_size,
    "searchContentTypes" => :search_content_types
  }

  def from_config(config) when is_map(config) do
    model =
      config
      |> Map.get("models", [])
      |> List.wrap()
      |> Enum.find(%{}, &(is_map(&1) and (&1["id"] || &1[:id]) == config["model"]))

    hosted =
      if Map.has_key?(model, "hostedTools"),
        do: model["hostedTools"],
        else: config["hostedTools"]

    case hosted do
      nil -> nil
      %{} -> normalize(hosted["webSearch"])
      _ -> :invalid
    end
  end

  def configuration(provider, _model, options) do
    case Keyword.get(options, :hosted_web_search) do
      nil ->
        {:ok, nil}

      config when is_map(config) ->
        if config[:supported] == true and config[:enabled] == true do
          configure(provider, config)
        else
          {:ok, nil}
        end

      _ ->
        invalid()
    end
  end

  def negotiate(["web_search"], %{provider: OpenAIResponses}),
    do: {:ok, %{accepted: ["web_search"]}}

  def negotiate(_capabilities, _context),
    do: {:error, Error.new(:unsupported_capability, "provider-hosted capability is unavailable")}

  def observe(event), do: Hosted.observe(__MODULE__, [event])

  def observe_hosted(events) do
    case Jason.encode(events) do
      {:ok, bytes} when byte_size(bytes) <= 1_048_576 -> {:ok, %{observed: length(events)}}
      _ -> invalid()
    end
  end

  defp configure(OpenAIResponses, config) do
    with true <- Enum.all?(Map.keys(config), &(&1 in Map.values(@keys))),
         {:ok, bytes} when byte_size(bytes) <= 16_384 <- Jason.encode(config),
         hosted <- %{
           adapter: __MODULE__,
           capabilities: ["web_search"],
           context: %{provider: OpenAIResponses},
           web_search: Map.drop(config, [:supported, :enabled])
         },
         {:ok, [_declaration]} <- Hosted.declarations(%{provider_hosted: hosted}) do
      {:ok, hosted}
    else
      {:error, %Error{}} = error -> error
      _ -> invalid()
    end
  end

  defp configure(_provider, _config),
    do:
      {:error,
       Error.new(:unsupported_capability, "provider-hosted web search requires OpenAI Responses")}

  defp normalize(nil), do: nil

  defp normalize(config) when is_map(config) do
    Map.new(config, fn
      {"mode", "cached"} -> {:mode, :cached}
      {"mode", "indexed"} -> {:mode, :indexed}
      {"mode", "live"} -> {:mode, :live}
      {key, value} -> {Map.get(@keys, key, key), value}
    end)
  end

  defp normalize(_), do: :invalid
  defp invalid, do: {:error, Error.new(:validation, "invalid provider-hosted configuration")}
end
