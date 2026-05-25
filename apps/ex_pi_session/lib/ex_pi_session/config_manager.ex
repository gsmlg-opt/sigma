defmodule PiSession.ConfigManager do
  @moduledoc """
  Manages AI provider and model configurations.
  """

  @agent_dir_name ".pi"
  @config_subdir "agent"

  @settings_file "settings.json"
  @auth_file "auth.json"
  @models_file "models.json"
  @mcp_file "mcp.json"
  @agents_file "AGENTS.md"
  @credential_ref_regex ~r/^\{\{credential:([^}]+)\}\}$/

  @default_system_prompt ""

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
            {id, %{"id" => id, "name" => data["name"] || id, "key" => key}}

          _ ->
            {id, %{"id" => id, "name" => data["name"] || id, "key" => ""}}
        end
      end)

    # Providers from models.json
    providers =
      Enum.into(models_data["providers"] || %{}, %{}, fn {id, p} ->
        model_ids = Enum.map(p["models"] || [], & &1["id"])

        {id,
         %{
           "id" => id,
           # pi uses provider ID as name in many places
           "name" => p["name"] || id,
           "api_type" =>
             case p["api"] do
               "anthropic-messages" -> "anthropic"
               "openai-completions" -> "openai"
               _ -> p["api"] || "anthropic"
             end,
           # pi usually stores key under provider ID in auth.json
           "credential_id" => p["credential_id"] || id,
           "model" => List.first(model_ids) || "",
           "models" => model_ids,
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

    # We need to know what to drop
    old_config = get_config()
    deleted_cred_ids = Map.keys(old_config["credentials"]) -- Map.keys(config["credentials"])
    deleted_provider_ids = Map.keys(old_config["providers"]) -- Map.keys(config["providers"])

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
    existing_auth = Map.drop(existing_auth, deleted_cred_ids)

    new_auth_entries =
      Enum.into(config["credentials"], %{}, fn {id, c} ->
        {id, %{"type" => "api_key", "key" => c["key"], "name" => c["name"]}}
      end)

    auth = Map.merge(existing_auth, new_auth_entries)
    save_json(@auth_file, auth)

    # 4. Save models.json (merge providers)
    existing_models = load_json(@models_file, %{"providers" => %{}})
    existing_providers = Map.drop(existing_models["providers"] || %{}, deleted_provider_ids)

    new_providers =
      Enum.into(config["providers"], %{}, fn {id, p} ->
        {id,
         %{
           "name" => p["name"],
           "baseUrl" => p["base_url"],
           "credential_id" => p["credential_id"],
           "api" =>
             case p["api_type"] do
               "anthropic" -> "anthropic-messages"
               "openai" -> "openai-completions"
               _ -> p["api_type"]
             end,
           "models" => [%{"id" => p["model"]}]
         }}
      end)

    providers = Map.merge(existing_providers, new_providers)
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

  # MCP server configuration

  @doc """
  Loads global MCP server configuration from `~/.pi/agent/mcp.json`.

  The saved format uses the Claude-style `mcpServers` top-level key. Loading
  also accepts VS Code-style `servers` so users can drop common `mcp.json`
  files into the pi config directory.
  """
  def get_mcp_config do
    @mcp_file
    |> load_json(%{})
    |> normalize_mcp_config()
  end

  def save_mcp_config(config) do
    servers =
      config
      |> normalize_mcp_config()
      |> Map.fetch!("servers")

    save_json(@mcp_file, %{"mcpServers" => servers})
    {:ok, %{"servers" => servers}}
  end

  def list_mcp_servers do
    get_mcp_config()["servers"]
  end

  def get_mcp_server(id) do
    list_mcp_servers()[id]
  end

  def put_mcp_server(id, server_config) do
    id = normalize_mcp_server_id(id)

    if id == "" do
      {:error, :invalid_id}
    else
      config = get_mcp_config()
      servers = Map.put(config["servers"], id, normalize_mcp_server(server_config))
      save_mcp_config(%{"servers" => servers})
    end
  end

  def update_mcp_server(old_id, updates) do
    config = get_mcp_config()
    old_id = normalize_mcp_server_id(old_id)
    new_id = updates |> Map.get("id", old_id) |> normalize_mcp_server_id()

    cond do
      new_id == "" ->
        {:error, :invalid_id}

      old_id != new_id and Map.has_key?(config["servers"], new_id) ->
        {:error, :id_conflict}

      true ->
        server =
          config["servers"]
          |> Map.get(old_id, %{})
          |> Map.merge(Map.drop(updates, ["id"]))
          |> normalize_mcp_server()

        servers =
          config["servers"]
          |> Map.delete(old_id)
          |> Map.put(new_id, server)

        save_mcp_config(%{"servers" => servers})
    end
  end

  def delete_mcp_server(id) do
    config = get_mcp_config()
    servers = Map.delete(config["servers"], id)
    save_mcp_config(%{"servers" => servers})
  end

  def mcp_servers_for(server_ids) when is_list(server_ids) do
    servers = list_mcp_servers()
    credentials = get_config()["credentials"] || %{}

    server_ids
    |> Enum.filter(&Map.has_key?(servers, &1))
    |> Enum.into(%{}, fn id -> {id, resolve_mcp_credentials(servers[id], credentials)} end)
  end

  def mcp_servers_for(_), do: %{}

  @doc "Returns the path to the global mcp.json file."
  def mcp_file do
    Path.join(agent_dir(), @mcp_file)
  end

  # ── Path helpers (pi-compatible) ─────────────────────────────────────────

  @doc "Returns the pi agent config directory (~/.pi/agent/)."
  def agent_dir do
    Application.get_env(:ex_pi_session, :agent_dir) ||
      Path.join([System.user_home!(), @agent_dir_name, @config_subdir])
  end

  @doc "Returns the root sessions directory (~/.pi/agent/sessions/)."
  def sessions_root do
    Path.join(agent_dir(), "sessions")
  end

  @doc """
  Returns the session directory for a working directory, using pi's path encoding.

  Pi encodes the cwd as `--Users-gao-Workspace-example--` (slashes → dashes,
  wrapped in double dashes). This matches the original pi TypeScript agent so
  sessions are shared between the two tools.
  """
  def sessions_dir(cwd) do
    Path.join(sessions_root(), pi_safe_path(cwd))
  end

  @doc "Returns the path to repos.jsonl."
  def repos_file do
    Path.join(agent_dir(), "repos.jsonl")
  end

  defp pi_safe_path(cwd) do
    safe =
      cwd
      |> String.replace_leading("/", "")
      |> String.replace(~r|[/:\\]|, "-")

    "--#{safe}--"
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
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, data} -> data
            {:error, _} -> default
          end

        _ ->
          default
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
    agent_dir()
  end

  defp normalize_mcp_config(config) when is_map(config) do
    servers = config["mcpServers"] || config["servers"] || %{}

    normalized_servers =
      servers
      |> Enum.into(%{}, fn {id, server} ->
        {normalize_mcp_server_id(id), normalize_mcp_server(server)}
      end)
      |> Enum.reject(fn {id, _server} -> id == "" end)
      |> Map.new()

    %{"servers" => normalized_servers}
  end

  defp normalize_mcp_config(_), do: %{"servers" => %{}}

  defp normalize_mcp_server(server) when is_map(server) do
    server = stringify_keys(server)

    type =
      case server["type"] do
        nil -> if server["url"], do: "http", else: "stdio"
        transport when transport in ["streamable-http", "sse"] -> "http"
        other -> other
      end

    server
    |> Map.put("type", type)
    |> normalize_mcp_server_fields(type)
  end

  defp normalize_mcp_server(_),
    do: %{"type" => "stdio", "command" => "", "args" => [], "env" => %{}}

  defp normalize_mcp_server_fields(server, "stdio") do
    server
    |> Map.drop(["url", "headers"])
    |> Map.put("command", server["command"] || "")
    |> Map.put("args", normalize_list(server["args"]))
    |> Map.put("env", normalize_map(server["env"]))
  end

  defp normalize_mcp_server_fields(server, "http") do
    server
    |> Map.drop(["command", "args", "env"])
    |> Map.put("url", server["url"] || "")
    |> Map.put("headers", normalize_map(server["headers"]))
  end

  defp normalize_mcp_server_fields(server, _type), do: server

  defp normalize_mcp_server_id(id) when is_binary(id) do
    id
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9_-]/, "_")
  end

  defp normalize_mcp_server_id(id), do: id |> to_string() |> normalize_mcp_server_id()

  defp stringify_keys(map) do
    Enum.into(map, %{}, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp normalize_list(value) when is_list(value), do: value
  defp normalize_list(_), do: []

  defp normalize_map(value) when is_map(value), do: stringify_keys(value)
  defp normalize_map(_), do: %{}

  defp resolve_mcp_credentials(server, credentials) do
    server
    |> Map.update(
      "args",
      [],
      &Enum.map(&1, fn value -> resolve_credential_ref(value, credentials) end)
    )
    |> Map.update("env", %{}, &resolve_credential_map(&1, credentials))
    |> Map.update("headers", %{}, &resolve_credential_map(&1, credentials))
  end

  defp resolve_credential_map(values, credentials) when is_map(values) do
    Enum.into(values, %{}, fn {key, value} ->
      {key, resolve_credential_ref(value, credentials)}
    end)
  end

  defp resolve_credential_map(_values, _credentials), do: %{}

  defp resolve_credential_ref(value, credentials) when is_binary(value) do
    case Regex.run(@credential_ref_regex, value) do
      [_, credential_id] ->
        case credentials[credential_id] do
          %{"key" => key} -> key
          _ -> value
        end

      _ ->
        value
    end
  end

  defp resolve_credential_ref(value, _credentials), do: value
end
