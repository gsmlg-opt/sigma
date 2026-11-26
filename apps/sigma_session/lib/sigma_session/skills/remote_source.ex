defmodule Sigma.Session.Skills.RemoteSource do
  @moduledoc "Configured Backplane Skill Protocol source with exact offline reads."

  alias Backplane.SkillProtocol.{Client, Error, SkillRef, Source.Backplane, TemporaryStorage}
  alias Sigma.Session.ConfigManager
  alias Sigma.Session.Skills.{BindingStore, RemoteCache}

  @enforce_keys [:source, :source_id, :cache_root, :binding_path]
  defstruct [:source, :client, :source_id, :cache_root, :binding_path, :access_scope]

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

    client_opts = Keyword.put_new(client_opts, :transport, Sigma.Session.Skills.HTTPTransport)

    with {:ok, client} <- Client.new(client_opts),
         {:ok, source} <- Backplane.new(client) do
      agent_dir = Keyword.get(opts, :agent_dir, ConfigManager.agent_dir())

      {:ok,
       %__MODULE__{
         source: source,
         client: client,
         source_id: client.source_id,
         access_scope: access_scope(opts),
         cache_root: Keyword.get(opts, :cache_root, Path.join(agent_dir, "skill-cache")),
         binding_path:
           Keyword.get(opts, :binding_path, Path.join(agent_dir, "skill-bindings.json"))
       }}
    end
  end

  @spec catalog(t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def catalog(%__MODULE__{source: source}, opts \\ []) do
    if opts[:view] in [:always, "always"] and not discovery_available?() do
      discovery_unavailable()
    else
      Backplane.catalog(source, opts)
    end
  end

  # TODO(upstream): gsmlg-opt/backplane#193 Adopt the published discovery SDK.
  def discovery_available? do
    Code.ensure_loaded?(Backplane) and function_exported?(Backplane, :search, 2)
  end

  def search(%__MODULE__{source: source}, opts) do
    if discovery_available?(),
      do: apply(Backplane, :search, [source, opts]),
      else: discovery_unavailable()
  end

  # TODO(upstream): gsmlg-opt/backplane#193 Adopt the published creation SDK.
  def create_available? do
    Code.ensure_loaded?(Client) and function_exported?(Client, :create, 3)
  end

  def create(%__MODULE__{client: client}, attrs, opts \\ []) do
    if create_available?(),
      do: apply(Client, :create, [client, attrs, opts]),
      else:
        {:error,
         Error.new(
           :unsupported_capability,
           :wire,
           "Backplane skill creation SDK needs an upgrade"
         )}
  end

  defp discovery_unavailable do
    {:error,
     Error.new(:unsupported_capability, :wire, "Backplane discovery SDK needs an upgrade")}
  end

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
    access_scope = remote.access_scope.()

    with {:ok, operation} <- allocate_operation(remote.cache_root),
         stage = Path.join(operation, "entry"),
         :ok <- File.mkdir(stage) do
      destination = Path.join(stage, "prepared")
      revision = Keyword.get(opts, :revision)

      package_opts =
        opts |> Keyword.drop([:offline, :revision]) |> Keyword.put(:destination, destination)

      result =
        with {:ok, prepared} <-
               Backplane.prepare(remote.source, skill_id, revision, package_opts),
             {:ok, cached} <- RemoteCache.publish(remote.cache_root, prepared, stage),
             :ok <-
               BindingStore.put(remote.binding_path, cached.manifest.ref, access_scope) do
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
           BindingStore.get(
             remote.binding_path,
             remote.source_id,
             skill_id,
             remote.access_scope.()
           ),
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

  # Persist only an opaque access identity. The credential remains in auth.json and
  # is read afresh so rotation invalidates old offline bindings as well.
  defp access_scope(opts) do
    supplier = Keyword.get(opts, :credential_supplier, fn -> nil end)

    identity =
      {Keyword.get(opts, :endpoint), Keyword.get(opts, :access_context_id),
       Keyword.get(opts, :credential_id)}

    fn ->
      credential = supplier.()

      :crypto.hash(:sha256, :erlang.term_to_binary({identity, credential}))
      |> Base.encode16(case: :lower)
    end
  end

  defp error(code, message), do: {:error, Error.new(code, :cache, message)}
end
