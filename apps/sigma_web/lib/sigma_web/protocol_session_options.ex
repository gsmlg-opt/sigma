defmodule Sigma.Web.ProtocolSessionOptions do
  @moduledoc false

  alias Sigma.Agent.{ContextPolicy, SessionContext}
  alias Sigma.Session.{ConfigManager, Models, RepoManager, SessionFiles, Skills}

  def validate_agent_model(agent) do
    with %{context_snapshot: %{model: model}} when is_map(model) <- Sigma.Agent.status(agent),
         provider_id <- model[:provider] || model["provider"] || model[:api] || model["api"],
         model_id <- model[:id] || model["id"] do
      case Application.get_env(:sigma_web, :test_provider_config) do
        %{"id" => ^provider_id, "model" => ^model_id} ->
          :ok

        _ ->
          case Models.resolve(provider_id, model_id) do
            {:ok, _} -> :ok
            error -> error
          end
      end
    else
      _ -> {:error, :model_unavailable}
    end
  catch
    :exit, _ -> {:error, :session_unavailable}
  end

  def prepare_create(payload) do
    config = ConfigManager.get_config()

    {provider_id, model_id} =
      if Map.has_key?(payload, "providerId") or Map.has_key?(payload, "modelId"),
        do: {payload["providerId"], payload["modelId"]},
        else: {config["active_provider_id"], config["default_model_id"]}

    with %{} = model <-
           Enum.find(
             Models.list(config),
             &(&1.provider_id == provider_id and &1.model_id == model_id)
           ),
         {:ok, _} <- Models.resolve(provider_id, model_id),
         metadata when is_map(metadata) <- payload["metadata"] || %{},
         {:ok, limit} <-
           ContextPolicy.new_session_limit(model.metadata, metadata["context_limit"]) do
      {:ok,
       payload
       |> Map.put("providerId", provider_id)
       |> Map.put("modelId", model_id)
       |> Map.put("metadata", Map.put(metadata, "context_limit", limit))}
    else
      nil -> {:error, :model_unavailable}
      {:error, _} = error -> error
      _ -> {:error, :invalid_session_metadata}
    end
  end

  def resolve(snapshot, workdir, sessions_dir, session_id, initial_metadata \\ nil) do
    with {:ok, meta_path} <- SessionFiles.meta_path(sessions_dir, session_id),
         metadata <- initial_metadata || read_metadata(meta_path),
         %{} = config <- provider_config(snapshot, metadata),
         {:ok, provider} <- provider_module(config),
         model_id when is_binary(model_id) and model_id != "" <- config["model"] do
      effective_cwd = metadata["cwd"] || snapshot.cwd || workdir

      mcp_ids =
        snapshot.mcp_server_ids ++
          List.wrap(metadata["mcp_server_ids"] || RepoManager.mcp_server_ids(workdir))

      mcp_ids = Enum.uniq(mcp_ids)
      discovery = Sigma.Session.ContextFiles.discover(nil, effective_cwd)
      skills_catalog = Skills.Catalog.build(effective_cwd)

      session_context =
        SessionContext.new(
          skills: Skills.Catalog.automatic(skills_catalog),
          agents_context: [ConfigManager.get_config()["system_prompt"], discovery.content],
          current_date: Date.utc_today()
        )

      [
        model: agent_model(config, model_id),
        context_limit: existing_context_limit(metadata),
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

  defp provider_config(%{provider_id: provider_id, model_id: model_id}, _metadata)
       when is_binary(provider_id) and is_binary(model_id) do
    case Models.resolve(provider_id, model_id) do
      {:ok, config} -> config
      _ -> nil
    end
  end

  defp provider_config(_snapshot, %{"provider_id" => provider_id, "model_id" => model_id}) do
    case Models.resolve(provider_id, model_id) do
      {:ok, config} -> config
      _ -> nil
    end
  end

  defp provider_config(_snapshot, _metadata), do: ConfigManager.get_active_provider_config()

  defp existing_context_limit(metadata) do
    case ContextPolicy.parse_context_limit(metadata["context_limit"]) do
      {:ok, limit} -> limit
      _ -> ContextPolicy.default_context_limit()
    end
  end

  defp provider_module(%{"api_type" => "anthropic"}), do: {:ok, Sigma.Ai.Providers.Anthropic}
  defp provider_module(%{"api_type" => "openai"}), do: {:ok, Sigma.Ai.Providers.OpenAIResponses}

  defp provider_module(%{"api_type" => "openai-responses"}),
    do: {:ok, Sigma.Ai.Providers.OpenAIResponses}

  defp provider_module(%{"api_type" => "openai-completions"}),
    do: {:ok, Sigma.Ai.Providers.OpenAI}

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
      auth_type: config["auth_type"] || default_auth_type(api_type),
      auth_header_name: config["auth_header_name"] || ""
    ]
  end

  defp default_auth_type(api_type)
       when api_type in ["openai", "openai-responses", "openai-completions"],
       do: "bearer"

  defp default_auth_type(_api_type), do: "x-api-key"

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
