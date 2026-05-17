defmodule ExPiSession.ConfigManager do
  @moduledoc """
  Manages AI provider and model configurations.
  """

  @config_file "config.json"

  @default_config %{
    "active_provider" => "anthropic",
    "providers" => %{
      "anthropic" => %{
        "id" => "anthropic",
        "name" => "Anthropic",
        "api_key" => "",
        "base_url" => "https://api.anthropic.com",
        "default_model" => "claude-3-5-sonnet-latest",
        "models" => [
          "claude-3-5-sonnet-latest",
          "claude-3-5-haiku-latest",
          "claude-3-opus-latest"
        ]
      },
      "openai" => %{
        "id" => "openai",
        "name" => "OpenAI",
        "api_key" => "",
        "base_url" => "https://api.openai.com/v1",
        "default_model" => "gpt-4o",
        "models" => [
          "gpt-4o",
          "gpt-4o-mini",
          "o1-preview",
          "o1-mini"
        ]
      }
    }
  }

  def get_config do
    path = config_path()

    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          user_config = Jason.decode!(content)
          # Merge with defaults to ensure new fields are present
          deep_merge(@default_config, user_config)

        _ ->
          @default_config
      end
    else
      @default_config
    end
  end

  def save_config(config) do
    path = config_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(config, pretty: true))
    {:ok, config}
  end

  def get_active_provider do
    config = get_config()
    provider_id = config["active_provider"]
    config["providers"][provider_id]
  end

  def update_provider_config(provider_id, updates) do
    config = get_config()
    providers = config["providers"]
    provider = providers[provider_id] || %{}
    new_provider = Map.merge(provider, updates)
    new_providers = Map.put(providers, provider_id, new_provider)

    config
    |> Map.put("providers", new_providers)
    |> save_config()
  end

  def set_active_provider(provider_id) do
    get_config()
    |> Map.put("active_provider", provider_id)
    |> save_config()
  end

  defp config_path do
    root = get_priv_root()
    Path.join(root, @config_file)
  end

  defp get_priv_root do
    if Mix.env() == :dev do
      # Find umbrella root by looking for mix.exs
      cwd = File.cwd!()
      root = if File.exists?(Path.join(cwd, "apps")), do: cwd, else: Path.expand("../..", cwd)
      Path.join(root, "apps/ex_pi_session/priv")
    else
      case :code.priv_dir(:ex_pi_session) do
        {:error, :bad_name} -> Path.expand("priv", File.cwd!())
        path -> List.to_string(path)
      end
    end
  end

  defp deep_merge(left, right) do
    Map.merge(left, right, fn _k, v1, v2 ->
      if is_map(v1) and is_map(v2) do
        deep_merge(v1, v2)
      else
        v2
      end
    end)
  end
end
