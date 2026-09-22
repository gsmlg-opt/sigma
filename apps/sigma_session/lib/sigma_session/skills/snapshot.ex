defmodule Sigma.Session.Skills.Snapshot do
  @moduledoc "Prepares immutable local skill bundles through Backplane Skill Protocol."

  alias Backplane.SkillProtocol.{
    Bundle,
    BundleManifest,
    Error,
    PreparedSkill,
    SkillRef,
    TemporaryStorage
  }

  alias Sigma.Session.Skills.{Protocol, Skill}

  @operation_prefix "sigma-skill-preparation"
  @ownership_marker ".sigma-skill-owner"

  @bundle_options [
    max_entries: 500,
    max_compressed_bytes: 10 * 1024 * 1024,
    max_expanded_bytes: 20 * 1024 * 1024,
    max_file_bytes: 5 * 1024 * 1024,
    max_document_bytes: 256 * 1024,
    max_frontmatter_bytes: 256 * 1024,
    max_path_depth: 32
  ]

  @spec prepare(Skill.t()) :: {:ok, map()} | {:error, atom()}
  def prepare(skill), do: prepare(skill, [])

  @doc false
  @spec prepare(Skill.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def prepare(%Skill{} = skill, opts) when is_list(opts) do
    with :ok <- validate_skill(skill),
         {:ok, operation} <- allocate_operation(opts) do
      case prepare_owned(skill, operation, opts) do
        {:ok, snapshot} ->
          {:ok, snapshot}

        {:error, reason} ->
          cleanup_error(operation.root, reason)
      end
    end
  end

  def prepare(_skill, _opts), do: {:error, :invalid_skill}

  @spec release(map()) ::
          :ok | {:error, :invalid_snapshot | :unowned_snapshot | :resource_unavailable}
  def release(snapshot) do
    with {:ok, ownership} <- validate_ownership(snapshot) do
      release_owned(ownership)
    end
  end

  defp validate_skill(%Skill{
         path: path,
         source_id: source_id,
         source_key: source_key,
         skill_id: skill_id
       })
       when is_binary(path) and is_binary(source_id) and is_binary(source_key) and
              is_binary(skill_id),
       do: :ok

  defp validate_skill(_skill), do: {:error, :invalid_skill}

  defp allocate_operation(opts) do
    storage_root =
      opts
      |> Keyword.get(:storage_root, default_storage_root())
      |> Path.expand()

    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    with :ok <- File.mkdir_p(storage_root),
         {:ok, operation_root} <- TemporaryStorage.directory(storage_root, @operation_prefix) do
      case TemporaryStorage.write_file(marker_path(operation_root), token) do
        :ok ->
          {:ok, %{root: operation_root, token: token}}

        {:error, reason} ->
          _ = remove_operation(operation_root)
          {:error, allocation_error(reason)}
      end
    else
      {:error, reason} -> {:error, allocation_error(reason)}
    end
  end

  defp prepare_owned(skill, operation, opts) do
    bundle_opts = bundle_options(skill, opts)

    with {:ok, bundle} <- pack_with_retry(skill.path, operation.root, bundle_opts),
         {:ok, prepared} <-
           Bundle.prepare(bundle, Path.join(operation.root, "prepared"), bundle_opts),
         :ok <- remove_archive(bundle.archive_path) do
      {:ok, snapshot_map(skill, prepared, operation)}
    else
      {:error, %Error{} = error} -> {:error, Protocol.error_map(error).code}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _reason} -> {:error, :resource_unavailable}
    end
  end

  defp pack_with_retry(entry_path, operation_root, opts) do
    root = Path.dirname(entry_path)

    case Bundle.pack(root, archive_path(operation_root, 1), opts) do
      {:error, %Error{code: :source_changed}} ->
        Bundle.pack(root, archive_path(operation_root, 2), opts)

      result ->
        result
    end
  end

  defp bundle_options(skill, opts) do
    ref = %SkillRef{source_id: skill.source_id, skill_id: skill.source_key}
    cancelled? = Keyword.get(opts, :cancelled?, fn -> false end)

    Keyword.merge(@bundle_options, ref: ref, cancelled?: cancelled?)
  end

  defp snapshot_map(skill, %PreparedSkill{} = prepared, operation) do
    manifest = manifest_map(prepared.manifest)

    %{
      skill_id: skill.skill_id,
      source_id: skill.source_id,
      ref: manifest.ref,
      digest: manifest.artifact_digest,
      root: prepared.root,
      entry_body: prepared.document.body_raw,
      manifest: manifest,
      provenance: %{path: skill.path, source: skill.source},
      ownership: %{operation_root: operation.root, token: operation.token}
    }
  end

  defp manifest_map(%BundleManifest{} = manifest) do
    %{
      protocol_version: manifest.protocol_version,
      profile: manifest.profile,
      ref: ref_map(manifest.ref),
      root: manifest.root,
      entrypoint: manifest.entrypoint,
      document_metadata: manifest.document_metadata,
      artifact_format: manifest.artifact_format,
      artifact_digest: manifest.artifact_digest,
      compressed_bytes: manifest.compressed_bytes,
      unpacked_bytes: manifest.unpacked_bytes,
      required_capabilities: manifest.required_capabilities,
      files: Enum.map(manifest.files, &file_map/1)
    }
  end

  defp ref_map(%SkillRef{} = ref) do
    %{
      source_id: ref.source_id,
      skill_id: ref.skill_id,
      revision: ref.revision,
      artifact_digest: ref.artifact_digest
    }
  end

  defp file_map(%{path: path, bytes: bytes, sha256: sha256}) do
    %{path: path, bytes: bytes, sha256: sha256}
  end

  defp validate_ownership(%{
         root: prepared_root,
         ownership: %{operation_root: operation_root, token: token}
       })
       when is_binary(prepared_root) and is_binary(operation_root) and is_binary(token) and
              byte_size(token) > 0 do
    expanded_operation_root = Path.expand(operation_root)
    expected_prepared_root = Path.join(expanded_operation_root, "prepared")

    if operation_root == expanded_operation_root and
         prepared_root == expected_prepared_root and
         String.starts_with?(Path.basename(operation_root), @operation_prefix <> ".") do
      {:ok, %{root: operation_root, token: token}}
    else
      {:error, :invalid_snapshot}
    end
  end

  defp validate_ownership(_snapshot), do: {:error, :invalid_snapshot}

  defp release_owned(%{root: operation_root, token: token}) do
    case File.lstat(operation_root) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :directory}} ->
        with {:ok, %File.Stat{type: :regular}} <- File.lstat(marker_path(operation_root)),
             {:ok, ^token} <- File.read(marker_path(operation_root)),
             :ok <- remove_operation(operation_root) do
          :ok
        else
          {:error, :enoent} -> {:error, :unowned_snapshot}
          {:ok, _other} -> {:error, :unowned_snapshot}
          {:error, _reason} -> {:error, :resource_unavailable}
        end

      {:ok, _other} ->
        {:error, :unowned_snapshot}

      {:error, _reason} ->
        {:error, :resource_unavailable}
    end
  end

  defp cleanup_error(operation_root, reason) do
    case remove_operation(operation_root) do
      :ok -> {:error, reason}
      {:error, :resource_unavailable} = error -> error
    end
  end

  defp remove_operation(operation_root) do
    case File.rm_rf(operation_root) do
      {:ok, _paths} -> :ok
      {:error, _reason, _path} -> {:error, :resource_unavailable}
    end
  end

  defp remove_archive(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, _reason} -> {:error, :resource_unavailable}
    end
  end

  defp allocation_error(_reason), do: :resource_unavailable

  defp marker_path(operation_root), do: Path.join(operation_root, @ownership_marker)

  defp archive_path(operation_root, attempt),
    do: Path.join(operation_root, "bundle-#{attempt}.tar.gz")

  defp default_storage_root,
    do: Path.join([System.tmp_dir!(), "sigma", "skill-preparations"])
end
