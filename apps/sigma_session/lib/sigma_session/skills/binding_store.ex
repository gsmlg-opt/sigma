defmodule Sigma.Session.Skills.BindingStore do
  @moduledoc "Atomic persistence for exact remote Skill bindings."

  alias Backplane.SkillProtocol.{Error, SkillRef}

  @spec get(String.t(), String.t(), String.t()) :: {:ok, SkillRef.t()} | {:error, Error.t()}
  def get(path, source_id, skill_id) do
    with {:ok, bindings} <- read(path),
         %{} = binding <- Map.get(bindings, key(source_id, skill_id)),
         {:ok, ref} <- decode(binding),
         true <- ref.source_id == source_id and ref.skill_id == skill_id do
      {:ok, ref}
    else
      nil -> error(:not_found, "remote Skill has no exact binding")
      false -> error(:integrity_mismatch, "remote Skill binding identity does not match")
      {:error, %Error{} = reason} -> {:error, reason}
    end
  end

  @spec put(String.t(), SkillRef.t()) :: :ok | {:error, Error.t()}
  def put(path, %SkillRef{} = ref) do
    with :ok <- exact(ref) do
      :global.trans({{__MODULE__, Path.expand(path)}, self()}, fn -> put_locked(path, ref) end)
    end
  end

  defp put_locked(path, ref) do
    with {:ok, bindings} <- read(path),
         content <- Map.put(bindings, key(ref.source_id, ref.skill_id), encode(ref)),
         {:ok, json} <- Jason.encode(content),
         :ok <- atomic_write(path, json) do
      :ok
    else
      {:error, %Error{} = reason} ->
        {:error, reason}

      {:error, _reason} ->
        error(:temporarily_unavailable, "remote Skill bindings cannot be written")
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, value} when is_map(value) -> {:ok, value}
          _ -> error(:invalid_bundle, "remote Skill binding store is invalid")
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, _reason} ->
        error(:temporarily_unavailable, "remote Skill bindings cannot be read")
    end
  end

  defp atomic_write(path, content) do
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, content),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, reason}
    end
  end

  defp encode(ref) do
    %{
      "source_id" => ref.source_id,
      "skill_id" => ref.skill_id,
      "revision" => ref.revision,
      "artifact_digest" => ref.artifact_digest
    }
  end

  defp decode(%{
         "source_id" => source_id,
         "skill_id" => skill_id,
         "revision" => revision,
         "artifact_digest" => digest
       }) do
    ref = %SkillRef{
      source_id: source_id,
      skill_id: skill_id,
      revision: revision,
      artifact_digest: digest
    }

    with :ok <- exact(ref), do: {:ok, ref}
  end

  defp decode(_binding), do: error(:invalid_bundle, "remote Skill binding is invalid")

  defp exact(%SkillRef{
         source_id: source,
         skill_id: skill,
         revision: revision,
         artifact_digest: digest
       })
       when is_binary(source) and byte_size(source) > 0 and is_binary(skill) and
              byte_size(skill) > 0 and
              is_binary(revision) and byte_size(revision) > 0 and is_binary(digest) and
              byte_size(digest) > 0,
       do: :ok

  defp exact(_ref), do: error(:invalid_request, "remote Skill binding must be exact")

  defp key(source_id, skill_id), do: source_id <> "\0" <> skill_id

  defp error(code, message),
    do: {:error, Error.new(code, :cache, message)}
end
