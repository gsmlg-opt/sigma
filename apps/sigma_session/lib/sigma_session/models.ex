defmodule Sigma.Session.Models do
  @moduledoc "Explicit configured model collection, identified by provider/model pair."
  alias Sigma.Session.ConfigManager

  def list(config \\ ConfigManager.get_config()) do
    config
    |> Map.get("providers", %{})
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {provider_id, provider} ->
      provider
      |> Map.get("models", [])
      |> Enum.map(fn descriptor ->
        metadata = descriptor(descriptor)
        id = metadata["id"]

        %{
          provider_id: provider_id,
          model_id: id,
          name: nonblank(metadata["name"]) || id,
          provider_name: provider["name"] || provider_id,
          default_context_limit: context_limit(metadata["defaultContextLimit"]),
          metadata: metadata
        }
      end)
      |> Enum.reject(&(&1.model_id == ""))
      |> Enum.uniq_by(& &1.model_id)
    end)
  end

  def resolve(provider_id, model_id) do
    config = ConfigManager.get_config()

    if Enum.any?(list(config), &(&1.provider_id == provider_id and &1.model_id == model_id)) do
      provider = config["providers"][provider_id]
      key = get_in(config, ["credentials", provider["credential_id"], "key"]) || ""
      {:ok, provider |> Map.put("model", model_id) |> Map.put("resolved_key", key)}
    else
      {:error, :model_unavailable}
    end
  end

  def add(provider_id, descriptors) when is_list(descriptors) do
    ConfigManager.transaction(fn ->
      with {:ok, provider} <- provider(provider_id),
           {:ok, added} <- normalize_descriptors(descriptors) do
        existing = provider["models"] || []
        merged = Enum.uniq_by(existing ++ added, &descriptor(&1)["id"])
        ConfigManager.put_provider_models(provider_id, merged)
      end
    end)
  end

  def update(provider_id, model_id, updates) when is_map(updates) do
    ConfigManager.transaction(fn ->
      with {:ok, provider} <- provider(provider_id),
           {:ok, _} <- resolve(provider_id, model_id),
           {:ok, [updated]} <-
             normalize_descriptors([
               Map.merge(
                 Enum.find(provider["models"], &(descriptor(&1)["id"] == model_id))
                 |> descriptor(),
                 stringify(updates)
               )
             ]) do
        if updated["id"] == model_id do
          models =
            Enum.map(provider["models"], fn model ->
              if descriptor(model)["id"] == model_id, do: updated, else: model
            end)

          ConfigManager.put_provider_models(provider_id, models)
        else
          {:error, :invalid_model_id}
        end
      end
    end)
  end

  def remove(provider_id, model_id) do
    ConfigManager.transaction(fn ->
      with {:ok, provider} <- provider(provider_id),
           {:ok, _} <- resolve(provider_id, model_id) do
        config = ConfigManager.get_config()
        models = Enum.reject(provider["models"], &(descriptor(&1)["id"] == model_id))

        with {:ok, _} <- ConfigManager.put_provider_models(provider_id, models) do
          if config["active_provider_id"] == provider_id and
               config["default_model_id"] == model_id,
             do: ConfigManager.put_default_model("", ""),
             else: {:ok, ConfigManager.get_config()}
        end
      end
    end)
  end

  def set_default(provider_id, model_id) do
    ConfigManager.transaction(fn ->
      with {:ok, _} <- resolve(provider_id, model_id),
           do: ConfigManager.put_default_model(provider_id, model_id)
    end)
  end

  defp provider(id) do
    case ConfigManager.get_config()["providers"][id] do
      nil -> {:error, :provider_unavailable}
      provider -> {:ok, provider}
    end
  end

  defp normalize_descriptors(descriptors) do
    Enum.reduce_while(descriptors, {:ok, []}, fn value, {:ok, result} ->
      model = descriptor(value)
      id = model["id"]
      limit = model["defaultContextLimit"]

      cond do
        id == "" ->
          {:halt, {:error, :invalid_model_id}}

        not blank?(limit) and is_nil(context_limit(limit)) ->
          {:halt, {:error, :invalid_context_limit}}

        true ->
          {:cont, {:ok, result ++ [Map.put(model, "defaultContextLimit", context_limit(limit))]}}
      end
    end)
  end

  defp descriptor(value) when is_map(value),
    do: value |> stringify() |> Map.update("id", "", &trim/1)

  defp descriptor(value), do: %{"id" => trim(value)}
  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_), do: ""

  defp nonblank(value) do
    case trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp blank?(value), do: is_nil(value) or (is_binary(value) and String.trim(value) == "")
  defp context_limit(value) when is_integer(value) and value > 0, do: value

  defp context_limit(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} when number > 0 -> number
      _ -> nil
    end
  end

  defp context_limit(_), do: nil
end
