defmodule Sigma.Agent.Backplane.PluginPackages do
  @moduledoc false

  # All calls run inside PluginResources' application-owned writer. Installing
  # is an explicit host operation, separate from the native request tool.
  alias Backplane.AgentRuntime.Error
  alias Backplane.PluginProtocol.{Archive, Client}
  alias Sigma.Agent.Backplane.Store.FileSystem

  def install(root, client, request) do
    with {:ok, records} <- load(root) do
      case Enum.find(records, &(&1["request_id"] == request["id"])) do
        nil -> prepare(root, client, request, records)
        %{"status" => "installed"} = record -> {:ok, record}
        %{"status" => "installing"} = record -> reconcile(root, record, records)
        record -> error(:execution_failure, "plugin installation previously failed", record)
      end
    end
  end

  def lookup(root, registry, request_id) do
    with {:ok, records} <- load(root) do
      case Enum.find(records, &(&1["request_id"] == request_id)) do
        %{"registry_url" => ^registry, "status" => "installed"} = record -> {:ok, record}
        nil -> error(:unavailable, "plugin request has no installation")
        record -> error(:unavailable, "plugin installation is not available", record)
      end
    end
  end

  def installed(root, registry) do
    with {:ok, records} <- load(root) do
      installed =
        records
        |> Enum.filter(&(&1["registry_url"] == registry and &1["status"] == "installed"))
        |> Enum.group_by(& &1["plugin_id"])
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {_plugin, releases} ->
          Enum.max_by(releases, &{&1["installed_at"], &1["request_id"]})
        end)

      {:ok, installed}
    end
  end

  def records(root, registry) do
    with {:ok, records} <- load(root),
         do: {:ok, Enum.filter(records, &(&1["registry_url"] == registry))}
  end

  defp prepare(root, client, request, records) do
    with %{"tool_type" => "plugin", "action_type" => "install", "tool_id" => id} <-
           request["arguments"],
         {:ok, descriptor} <- Client.resolve(client, plugin_id: id),
         %{"plugin_id" => ^id, "release_id" => release, "artifact_digest" => digest} <-
           descriptor,
         true <- is_binary(release) and release != "",
         {:ok, package} <- Client.download(client, digest),
         {:ok, canonical} <- Archive.pack(package.files, modes: package.modes) do
      record = %{
        "request_id" => request["id"],
        "registry_url" => request["registry_url"],
        "plugin_id" => id,
        "release_id" => release,
        "artifact_digest" => digest,
        "content_digest" => Archive.digest(canonical),
        "root" => Path.join([root, "packages", digest]),
        "data_dir" =>
          Path.join([root, "data", Archive.digest(Jason.encode!([request["registry_url"], id]))]),
        "status" => "installing",
        "started_at" => System.system_time(:microsecond)
      }

      with :ok <- save(root, records ++ [record]) do
        case materialize(record, package) do
          :ok -> complete(root, record, records ++ [record])
          {:error, cause} -> fail(root, record, records ++ [record], cause)
        end
      end
    else
      {:error, cause} -> error(:execution_failure, "plugin package preparation failed", cause)
      other -> error(:validation, "plugin request or resolved release is invalid", other)
    end
  end

  defp materialize(record, package) do
    if File.exists?(record["root"]) do
      verify(record)
    else
      stage = record["root"] <> ".stage-" <> Base.url_encode64(:crypto.strong_rand_bytes(12))

      result =
        with :ok <- File.mkdir_p(stage),
             :ok <- write_files(stage, package),
             :ok <- File.rename(stage, record["root"]) do
          :ok
        end

      case File.rm_rf(stage) do
        {:ok, _} -> result
        {:error, cause, path} -> {:error, %{installation: result, cleanup: {cause, path}}}
      end
    end
  end

  defp write_files(stage, package) do
    package.files
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn {relative, bytes}, :ok ->
      path = Path.join(stage, relative)

      result =
        with :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- FileSystem.write_atomic(path, bytes),
             do: File.chmod(path, Map.fetch!(package.modes, relative))

      case result do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp reconcile(root, record, records) do
    case verify(record) do
      :ok -> complete(root, record, records)
      {:error, cause} -> error(:unknown_outcome, "plugin installation remains unconfirmed", cause)
    end
  end

  defp verify(record) do
    with {:ok, snapshot} <- Archive.read_directory_with_metadata(record["root"]),
         {:ok, bytes} <- Archive.pack(snapshot.files, modes: snapshot.modes) do
      if Archive.digest(bytes) == record["content_digest"],
        do: :ok,
        else: {:error, :installed_content_changed}
    end
  end

  defp complete(root, record, records) do
    installed =
      record
      |> Map.put("status", "installed")
      |> Map.put("installed_at", System.system_time(:microsecond))

    with :ok <- save(root, replace(records, installed)), do: {:ok, installed}
  end

  defp fail(root, record, records, cause) do
    failed = Map.merge(record, %{"status" => "failed", "failure" => inspect(cause)})

    case save(root, replace(records, failed)) do
      :ok ->
        error(:execution_failure, "plugin package installation failed", cause)

      {:error, persistence} ->
        error(:unknown_outcome, "plugin installation failure was not recorded", %{
          installation: cause,
          persistence: persistence
        })
    end
  end

  defp replace(records, record),
    do: Enum.map(records, &if(&1["request_id"] == record["request_id"], do: record, else: &1))

  defp load(root) do
    case File.read(Path.join(root, "installations.json")) do
      {:ok, bytes} ->
        case Jason.decode(bytes) do
          {:ok, %{"version" => 1, "installations" => records}} when is_list(records) ->
            if Enum.all?(records, &record?/1) and
                 length(Enum.uniq_by(records, & &1["request_id"])) == length(records),
               do: {:ok, records},
               else: error(:execution_failure, "plugin installation store has malformed records")

          other ->
            error(:execution_failure, "plugin installation store is malformed", other)
        end

      {:error, :enoent} ->
        {:ok, []}

      {:error, cause} ->
        error(:execution_failure, "plugin installation store read failed", cause)
    end
  end

  defp record?(record) when is_map(record) do
    Enum.all?(
      ~w(request_id registry_url plugin_id release_id artifact_digest content_digest root data_dir),
      &(is_binary(record[&1]) and record[&1] != "")
    ) and record["status"] in ~w(installing installed failed) and
      is_integer(record["started_at"]) and
      (record["status"] != "installed" or is_integer(record["installed_at"]))
  end

  defp record?(_), do: false

  defp save(root, records) do
    with {:ok, bytes} <- Jason.encode(%{version: 1, installations: records}),
         :ok <- File.mkdir_p(root),
         :ok <- FileSystem.write_atomic(Path.join(root, "installations.json"), bytes) do
      :ok
    else
      {:error, cause} ->
        error(:unknown_outcome, "plugin installation persistence is unconfirmed", cause)
    end
  end

  defp error(class, message, cause \\ nil),
    do: {:error, Error.new(class, message, cause: cause)}
end
