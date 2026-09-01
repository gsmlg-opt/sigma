defmodule Sigma.Web.ProtocolSessionOptions do
  @moduledoc false

  alias Sigma.Agent.SessionContext
  alias Sigma.Session.{ConfigManager, RepoManager, SessionFiles, Skills}

  def resolve(snapshot, workdir, sessions_dir, session_id) do
    with {:ok, meta_path} <- SessionFiles.meta_path(sessions_dir, session_id),
         metadata <- read_metadata(meta_path),
         %{} = config <- provider_config(snapshot, metadata),
         {:ok, provider} <- provider_module(config),
         model_id when is_binary(model_id) and model_id != "" <- config["model"] do
      effective_cwd = metadata["cwd"] || snapshot.cwd || workdir
      mcp_ids = snapshot.mcp_server_ids ++ List.wrap(metadata["mcp_server_ids"] || RepoManager.mcp_server_ids(workdir))
      mcp_ids = Enum.uniq(mcp_ids)
      discovery = Sigma.Session.ContextFiles.discover(nil, effective_cwd)

      session_context =
        SessionContext.new(
          skills: [Skills.list_global().skills, Skills.list_repository(effective_cwd).skills] |> List.flatten(),
          agents_context: [ConfigManager.get_config()["system_prompt"], discovery.content],
          current_date: Date.utc_today()
        )

      [
        model: agent_model(config, model_id),
        provider: provider,
        options: provider_options(config),
        system_prompt: nil,
        session_context: session_context,
        permission_config: ConfigManager.get_permissions(),
        tools: Sigma.Tools.default_tools(),
        mcp_servers: ConfigManager.mcp_servers_for(mcp_ids),
        cwd: effective_cwd
      ]
    else
      _reason -> []
    end
  end

  defp provider_config(%{provider_id: provider_id, model_id: model_id}, metadata)
       when is_binary(provider_id) and is_binary(model_id) do
    case ConfigManager.get_provider_config(provider_id) do
      %{} = provider -> Map.put(provider, "model", model_id)
      nil -> provider_config(%{}, metadata)
    end
  end

  defp provider_config(_snapshot, %{"provider_id" => provider_id, "model_id" => model_id}) do
    case ConfigManager.get_provider_config(provider_id) do
      %{} = provider -> Map.put(provider, "model", model_id)
      nil -> ConfigManager.get_active_provider_config()
    end
  end

  defp provider_config(_snapshot, _metadata), do: ConfigManager.get_active_provider_config()

  defp provider_module(%{"api_type" => "anthropic"}), do: {:ok, Sigma.Ai.Providers.Anthropic}
  defp provider_module(%{"api_type" => "openai"}), do: {:ok, Sigma.Ai.Providers.OpenAI}

  defp provider_module(_config) do
    case Application.get_env(:sigma_web, :mock_provider_module) do
      provider when is_atom(provider) -> {:ok, provider}
      _provider -> {:error, :unknown_provider}
    end
  end

  defp provider_options(config) do
    api_type = config["api_type"] || "anthropic"

    [
      api_key: config["resolved_key"] || "",
      base_url: config["base_url"] || "",
      auth_type: config["auth_type"] || if(api_type == "openai", do: "bearer", else: "x-api-key"),
      auth_header_name: config["auth_header_name"] || ""
    ]
  end

  defp agent_model(config, model_id) do
    metadata =
      config
      |> Map.get("models", [])
      |> List.wrap()
      |> Enum.find(%{}, fn
        %{} = model -> (model["id"] || model[:id]) == model_id
        model -> to_string(model) == model_id
      end)

    metadata = if is_map(metadata), do: metadata, else: %{}
    Map.merge(metadata, %{id: model_id, api: config["id"], provider: config["id"]})
  end

  defp read_metadata(path) do
    with {:ok, content} <- File.read(path),
         {:ok, metadata} when is_map(metadata) <- Jason.decode(content) do
      metadata
    else
      _error -> %{}
    end
  end
end
