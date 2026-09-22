defmodule Sigma.Session.Skills.RemoteCache do
  @moduledoc "Host-owned cache of package-verified remote Skill roots."

  alias Backplane.SkillProtocol.{
    Error,
    Parser,
    PreparedSkill,
    Resource,
    SkillRef,
    Validator,
    Wire
  }

  @metadata_file "metadata.json"

  @spec publish(String.t(), PreparedSkill.t(), String.t()) ::
          {:ok, PreparedSkill.t()} | {:error, Error.t()}
  def publish(cache_root, %PreparedSkill{manifest: %{ref: %SkillRef{} = ref}} = prepared, stage)
      when is_binary(stage) do
    final = entry_path(cache_root, ref)

    :global.trans({{__MODULE__, final}, self()}, fn ->
      with :ok <- File.mkdir_p(Path.dirname(final)),
           :ok <- write_metadata(stage, prepared),
           {:ok, cached} <- publish_or_load(stage, final, ref) do
        {:ok, cached}
      end
    end)
  end

  @spec load(String.t(), SkillRef.t()) :: {:ok, PreparedSkill.t()} | {:error, Error.t()}
  def load(cache_root, %SkillRef{} = ref), do: load_entry(entry_path(cache_root, ref), ref)

  defp publish_or_load(stage, final, ref) do
    case File.rename(stage, final) do
      :ok ->
        load_entry(final, ref)

      {:error, :eexist} ->
        load_entry(final, ref)

      {:error, _reason} ->
        error(:temporarily_unavailable, "verified remote Skill cache cannot be published")
    end
  end

  defp load_entry(entry, ref) do
    with {:ok, bytes} <- File.read(Path.join(entry, @metadata_file)),
         {:ok, metadata} <- Jason.decode(bytes),
         %{"manifest" => manifest_map} <- metadata,
         {:ok, manifest} <- Wire.decode_manifest_map(manifest_map, ref.source_id),
         :ok <- same_ref(manifest.ref, ref),
         root = Path.join(entry, "prepared"),
         true <- File.dir?(root),
         skeletal = %PreparedSkill{root: root, manifest: manifest, document: nil},
         {:ok, document_bytes} <- Resource.read(skeletal, manifest.entrypoint),
         {:ok, document} <- Parser.parse(document_bytes),
         {:ok, document} <-
           Validator.validate(document, supported_capabilities: manifest.required_capabilities) do
      {:ok, %{skeletal | document: document}}
    else
      false -> error(:not_found, "verified remote Skill cache entry is unavailable")
      {:error, :enoent} -> error(:not_found, "verified remote Skill cache entry is unavailable")
      {:error, %Error{} = reason} -> {:error, reason}
      _ -> error(:invalid_bundle, "verified remote Skill cache entry is invalid")
    end
  end

  defp write_metadata(stage, prepared) do
    metadata = %{"manifest" => Wire.manifest_map(prepared.manifest)}

    with {:ok, encoded} <- Jason.encode(metadata),
         :ok <- File.write(Path.join(stage, @metadata_file), encoded) do
      :ok
    else
      {:error, _reason} ->
        error(:temporarily_unavailable, "verified remote Skill metadata cannot be written")
    end
  end

  defp same_ref(%SkillRef{} = left, %SkillRef{} = right) do
    if left == right,
      do: :ok,
      else: error(:integrity_mismatch, "verified remote Skill cache identity does not match")
  end

  defp entry_path(root, ref) do
    Path.join([
      Path.expand(root),
      component(ref.source_id),
      component(ref.skill_id),
      component(ref.revision),
      component(ref.artifact_digest)
    ])
  end

  defp component(value), do: :crypto.hash(:sha256, value) |> Base.url_encode64(padding: false)

  defp error(code, message), do: {:error, Error.new(code, :cache, message)}
end
