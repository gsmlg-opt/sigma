defmodule ExPiSession.ConfigManager do
  @moduledoc """
  Manages AI provider and model configurations.
  """

  @agent_dir_name ".pi"
  @config_subdir "agent"

  @settings_file "settings.json"
  @auth_file "auth.json"
  @models_file "models.json"
  @agents_file "AGENTS.md"

  @default_system_prompt "You are an expert coding assistant operating inside π (ExPi), an Elixir-based coding agent.\nYou help users by reading files, executing commands, editing code, and writing new files.\n\nGuidelines:\n- Be concise in your responses.\n- Show file paths clearly when working with files.\n- Use bash for file operations like ls, rg, find.\n- When editing files, ensure the code remains correct and idiomatic.\n- You have access to tools for reading files, executing bash commands, and editing/writing files."

  def get_config do
    settings = load_json(@settings_file, %{})
    auth = load_json(@auth_file, %{})
    models_data = load_json(@models_file, %{"providers" => %{}})
    system_prompt = load_text(@agents_file, @default_system_prompt)

    # Transform pi format to our internal flat format for the UI
    active_provider_id = settings["defaultProvider"] || ""

    # Credentials from auth.json (API keys only for now)
    credentials =
      Enum.into(auth, %{}, fn {id, data} ->
        case data do
          %{"type" => "api_key", "key" => key} ->
            {id, %{"id" => id, "name" => id, "key" => key}}

          _ ->
            {id, %{"id" => id, "name" => id, "key" => ""}}
        end
      end)

    # Providers from models.json
    providers =
      Enum.into(models_data["providers"] || %{}, %{}, fn {id, p} ->
        {id,
         %{
           "id" => id,
           # pi uses provider ID as name in many places
           "name" => id,
           "api_type" =>
             case p["api"] do
               "anthropic-messages" -> "anthropic"
               "openai-completions" -> "openai"
               _ -> p["api"] || "anthropic"
             end,
           # pi usually stores key under provider ID in auth.json
           "credential_id" => id,
           "model" => (p["models"] && List.first(p["models"])["id"]) || "",
           "base_url" => p["baseUrl"] || ""
         }}
      end)

    %{
      "active_provider_id" => active_provider_id,
      "system_prompt" => system_prompt,
      "credentials" => credentials,
      "providers" => providers
    }
  end

  def save_config(config) do
    # 1. Save AGENTS.md (overwrite)
    save_text(@agents_file, config["system_prompt"])

    # 2. Save settings.json (merge)
    active_provider = config["providers"][config["active_provider_id"]]
    existing_settings = load_json(@settings_file, %{})

    settings =
      Map.merge(existing_settings, %{
        "defaultProvider" => config["active_provider_id"],
        "defaultModel" => (active_provider && active_provider["model"]) || ""
      })

    save_json(@settings_file, settings)

    # 3. Save auth.json (merge)
    existing_auth = load_json(@auth_file, %{})

    new_auth_entries =
      Enum.into(config["credentials"], %{}, fn {id, c} ->
        {id, %{"type" => "api_key", "key" => c["key"]}}
      end)

    auth = Map.merge(existing_auth, new_auth_entries)
    save_json(@auth_file, auth)

    # 4. Save models.json (merge providers)
    existing_models = load_json(@models_file, %{"providers" => %{}})

    new_providers =
      Enum.into(config["providers"], %{}, fn {id, p} ->
        {id,
         %{
           "baseUrl" => p["base_url"],
           "api" =>
             case p["api_type"] do
               "anthropic" -> "anthropic-messages"
               "openai" -> "openai-completions"
               _ -> p["api_type"]
             end,
           "models" => [%{"id" => p["model"]}]
         }}
      end)

    providers = Map.merge(existing_models["providers"] || %{}, new_providers)
    models_data = Map.put(existing_models, "providers", providers)
    save_json(@models_file, models_data)

    {:ok, config}
  end

  # Credentials Management

  def add_credential(name, key) do
    id = "cred_#{System.unique_integer([:positive])}"
    config = get_config()
    credentials = Map.get(config, "credentials", %{})
    new_cred = %{"id" => id, "name" => name, "key" => key}

    config
    |> Map.put("credentials", Map.put(credentials, id, new_cred))
    |> save_config()
  end

  def update_credential(id, updates) do
    config = get_config()
    credentials = config["credentials"]
    cred = credentials[id] || %{"id" => id}
    new_cred = Map.merge(cred, updates)

    config
    |> Map.put("credentials", Map.put(credentials, id, new_cred))
    |> save_config()
  end

  def delete_credential(id) do
    config = get_config()
    credentials = Map.delete(config["credentials"], id)

    # Also clear credential_id from any providers using it
    providers =
      Enum.into(config["providers"], %{}, fn {pid, p} ->
        if p["credential_id"] == id do
          {pid, Map.put(p, "credential_id", "")}
        else
          {pid, p}
        end
      end)

    config
    |> Map.put("credentials", credentials)
    |> Map.put("providers", providers)
    |> save_config()
  end

  # Providers Management

  def add_provider(params) do
    id = "prov_#{System.unique_integer([:positive])}"
    config = get_config()
    providers = Map.get(config, "providers", %{})
    new_provider = Map.put(params, "id", id)

    config
    |> Map.put("providers", Map.put(providers, id, new_provider))
    |> save_config()
  end

  def update_provider(id, updates) do
    config = get_config()
    providers = config["providers"]
    provider = providers[id] || %{"id" => id}
    new_provider = Map.merge(provider, updates)

    config
    |> Map.put("providers", Map.put(providers, id, new_provider))
    |> save_config()
  end

  def delete_provider(id) do
    config = get_config()
    providers = Map.delete(config["providers"], id)

    # Reset active provider if deleted
    active_id = if config["active_provider_id"] == id, do: "", else: config["active_provider_id"]

    config
    |> Map.put("providers", providers)
    |> Map.put("active_provider_id", active_id)
    |> save_config()
  end

  def set_active_provider(id) do
    get_config()
    |> Map.put("active_provider_id", id)
    |> save_config()
  end

  def update_system_prompt(prompt) do
    get_config()
    |> Map.put("system_prompt", prompt)
    |> save_config()
  end

  def get_active_provider_config do
    config = get_config()
    provider_id = config["active_provider_id"]
    provider = config["providers"][provider_id]

    if provider do
      # Resolve credential from auth.json
      # In pi, auth keys usually match the provider ID or specific auth keys
      # Our transform_messages already put keys into credentials map
      credential =
        config["credentials"][provider["credential_id"]] || config["credentials"][provider_id]

      Map.put(provider, "resolved_key", (credential && credential["key"]) || "")
    else
      nil
    end
  end

  # Specialized persistence helpers

  defp load_json(filename, default) do
    path = Path.join(get_config_dir(), filename)

    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} -> Jason.decode!(content)
        _ -> default
      end
    else
      default
    end
  end

  defp save_json(filename, data) do
    path = Path.join(get_config_dir(), filename)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(data, pretty: true))
  end

  defp load_text(filename, default) do
    path = Path.join(get_config_dir(), filename)

    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} -> content
        _ -> default
      end
    else
      default
    end
  end

  defp save_text(filename, text) do
    path = Path.join(get_config_dir(), filename)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
  end

  defp get_config_dir do
    Path.join([System.user_home!(), @agent_dir_name, @config_subdir])
  end
end
