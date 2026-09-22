defmodule Sigma.Session.Skills.RemoteSource do
  @moduledoc "Configured Backplane Skill Protocol read source with exact offline reuse."

  alias Backplane.SkillProtocol.{Client, Error, SkillRef, Source.Backplane, TemporaryStorage}
  alias Sigma.Session.ConfigManager
  alias Sigma.Session.Skills.{BindingStore, RemoteCache}

  @enforce_keys [:source, :source_id, :cache_root, :binding_path]
  defstruct [:source, :source_id, :cache_root, :binding_path]

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts) when is_list(opts) do
    client_opts =
      Keyword.take(opts, [
        :endpoint,
        :source_id,
        :access_context_id,
        :credential_supplier,
        :transport,
        :max_json_bytes,
        :max_artifact_bytes,
        :overall_timeout_ms,
        :max_attempts,
        :retry_delays_ms,
        :clock,
        :sleep,
        :cancelled?
      ])

    with {:ok, client} <- Client.new(client_opts),
         {:ok, source} <- Backplane.new(client) do
      agent_dir = Keyword.get(opts, :agent_dir, ConfigManager.agent_dir())

      {:ok,
       %__MODULE__{
         source: source,
         source_id: client.source_id,
         cache_root: Keyword.get(opts, :cache_root, Path.join(agent_dir, "skill-cache")),
         binding_path:
           Keyword.get(opts, :binding_path, Path.join(agent_dir, "skill-bindings.json"))
       }}
    end
  end

  @spec catalog(t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def catalog(%__MODULE__{source: source}, opts \\ []), do: Backplane.catalog(source, opts)

  @spec resolve(t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, Backplane.SkillProtocol.BundleManifest.t()} | {:error, Error.t()}
  def resolve(%__MODULE__{source: source}, skill_id, revision \\ nil, opts \\ []),
    do: Backplane.resolve(source, skill_id, revision, opts)

  @spec prepare(t(), String.t(), keyword()) ::
          {:ok, Backplane.SkillProtocol.PreparedSkill.t()} | {:error, Error.t()}
  def prepare(%__MODULE__{} = remote, skill_id, opts \\ []) when is_binary(skill_id) do
    if Keyword.get(opts, :offline, false) do
      prepare_offline(remote, skill_id, opts)
    else
      prepare_online(remote, skill_id, opts)
    end
  end

  defp prepare_online(remote, skill_id, opts) do
    with {:ok, operation} <- allocate_operation(remote.cache_root),
         stage = Path.join(operation, "entry"),
         :ok <- File.mkdir(stage) do
      destination = Path.join(stage, "prepared")
      revision = Keyword.get(opts, :revision)

      package_opts =
        opts |> Keyword.drop([:offline, :revision]) |> Keyword.put(:destination, destination)

      result =
        with {:ok, prepared} <- Backplane.prepare(remote.source, skill_id, revision, package_opts),
             {:ok, cached} <- RemoteCache.publish(remote.cache_root, prepared, stage),
             :ok <- BindingStore.put(remote.binding_path, cached.manifest.ref) do
          {:ok, cached}
        end

      File.rm_rf(operation)
      result
    else
      {:error, %Error{} = reason} ->
        {:error, reason}

      {:error, _reason} ->
        error(:temporarily_unavailable, "remote Skill cache operation cannot be allocated")
    end
  end

  defp prepare_offline(remote, skill_id, opts) do
    requested_revision = Keyword.get(opts, :revision)

    with {:ok, %SkillRef{} = ref} <-
           BindingStore.get(remote.binding_path, remote.source_id, skill_id),
         :ok <- requested_revision(ref, requested_revision),
         {:ok, prepared} <- RemoteCache.load(remote.cache_root, ref) do
      {:ok, prepared}
    end
  end

  defp requested_revision(_ref, nil), do: :ok
  defp requested_revision(%SkillRef{revision: revision}, revision), do: :ok

  defp requested_revision(_ref, _requested),
    do: error(:revision_unavailable, "requested remote Skill revision is not bound")

  defp allocate_operation(cache_root) do
    operations = Path.join(Path.expand(cache_root), ".operations")

    with :ok <- File.mkdir_p(operations) do
      TemporaryStorage.directory(operations, "prepare")
    end
  end

  defp error(code, message), do: {:error, Error.new(code, :cache, message)}
end
