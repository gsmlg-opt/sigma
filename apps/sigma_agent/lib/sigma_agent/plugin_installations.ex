defmodule Sigma.Agent.PluginInstallations do
  @moduledoc """
  Shared host boundary for explicit plugin installation in settings and Protocol.

  Request history remains immutable. This view joins the application-owned request
  and installation ledgers; it does not assign requests to a transcript branch or
  activate plugin MCP. Installed skills are picked up at the next native binding.
  """

  alias Sigma.Agent.Backplane.PluginResources
  alias Sigma.Session.ConfigManager

  @receipt_fields ~w(request_id registry_url plugin_id release_id artifact_digest content_digest status started_at installed_at)
  @public_fields ~w(requestId registryUrl pluginId releaseId artifactDigest contentDigest status startedAt installedAt)

  def configured do
    PluginResources.open(apply(ConfigManager, :get_plugin_config, []))
  end

  def list(host, options \\ %{}) do
    with :ok <- validate_page(options),
         {:ok, snapshot} <- snapshot(host),
         revision = revision(host, snapshot),
         :ok <- current_revision(revision, options),
         items = summaries(snapshot),
         offset = Map.get(options, "offset", 0),
         true <- offset <= length(items) do
      page = Enum.slice(items, offset, Map.get(options, "limit", 20))
      next = offset + length(page)

      {:ok,
       %{
         "configured" => not is_nil(host),
         "registryUrl" => if(host, do: host.registry_url),
         "revision" => revision,
         "offset" => offset,
         "nextOffset" => if(next < length(items), do: next),
         "total" => length(items),
         "items" => page
       }}
    else
      false -> {:error, :invalid_plugin_requests_page}
      {:error, _} = error -> error
    end
  end

  def install(host, request_id, confirmation_source \\ nil)

  def install(nil, _request_id, _source), do: {:error, :plugin_host_unconfigured}

  def install(host, request_id, source) when is_binary(request_id) and request_id != "" do
    with {:ok, installed} <- PluginResources.install(host, request_id, source),
         do: {:ok, receipt(installed)}
  end

  def install(_host, _request_id, _source), do: {:error, :invalid_plugin_request_id}

  defp snapshot(nil), do: {:ok, %{requests: [], installations: []}}
  defp snapshot(host), do: PluginResources.requests(host)

  defp summaries(snapshot) do
    installed = Map.new(snapshot.installations, &{&1["request_id"], &1})

    snapshot.requests
    |> Enum.sort_by(&{&1["requested_at"], &1["id"]}, :desc)
    |> Enum.map(fn request ->
      request_summary = %{
        "requestId" => request["id"],
        "pluginId" => request["arguments"]["tool_id"],
        "registryUrl" => request["registry_url"],
        "requestStatus" => request["status"],
        "status" => "requested",
        "requestedAt" => request["requested_at"]
      }

      case installed[request["id"]] do
        nil -> request_summary
        installation -> Map.merge(request_summary, receipt(installation))
      end
    end)
  end

  defp receipt(installation) do
    @receipt_fields
    |> Enum.zip(@public_fields)
    |> Enum.reduce(%{}, fn {source, target}, result ->
      case Map.fetch(installation, source) do
        {:ok, value} -> Map.put(result, target, value)
        :error -> result
      end
    end)
  end

  defp revision(host, snapshot) do
    identity = if host, do: {host.root, host.registry_url}

    :crypto.hash(:sha256, :erlang.term_to_binary({identity, snapshot}, [:deterministic]))
    |> Base.url_encode64(padding: false)
  end

  defp current_revision(revision, options) do
    case options["expectedRevision"] do
      nil -> :ok
      ^revision -> :ok
      _ -> {:error, :plugin_requests_stale}
    end
  end

  defp validate_page(options) when is_map(options) and not is_struct(options) do
    offset = Map.get(options, "offset", 0)
    limit = Map.get(options, "limit", 20)
    expected = options["expectedRevision"]

    if Enum.all?(Map.keys(options), &(&1 in ~w(offset limit expectedRevision))) and
         is_integer(offset) and offset >= 0 and is_integer(limit) and limit in 1..50 and
         (is_nil(expected) or (is_binary(expected) and expected != "")) and
         (offset == 0 or not is_nil(expected)),
       do: :ok,
       else: {:error, :invalid_plugin_requests_page}
  end

  defp validate_page(_options), do: {:error, :invalid_plugin_requests_page}
end
