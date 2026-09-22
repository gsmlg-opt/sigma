defmodule Sigma.Session.Skills.RemoteAdapter do
  @moduledoc "Session-owned configured remote Skill catalog and preparation boundary."

  alias Backplane.SkillProtocol.{Descriptor, Error, PreparedSkill, SkillRef}
  alias Sigma.Session.{ConfigManager, SlashCommands}
  alias Sigma.Session.Skills.{Protocol, RemoteSource}

  @default_limit 50
  @max_limit 100

  @spec sources() :: [map()]
  def sources do
    Enum.map(ConfigManager.skill_sources(), fn source ->
      %{
        source_id: source.source_id,
        name: source.name,
        kind: source.kind,
        enabled?: source.enabled?,
        offline?: source.offline?,
        status: source_status(source)
      }
    end)
  end

  @spec catalog(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def catalog(params, opts \\ []) when is_map(params) and is_list(opts) do
    source_id = value(params, :source_id)

    with {:ok, source} <- configured_source(source_id),
         :ok <- searchable(source),
         {:ok, remote} <- remote_source(source, opts),
         {:ok, result} <- RemoteSource.catalog(remote, catalog_options(params)) do
      items = Enum.map(result.data, &descriptor(&1, source))

      {:ok,
       %{
         catalog_revision: revision(items, result.next_cursor),
         items: items,
         next_cursor: result.next_cursor,
         partial: true,
         diagnostics: [],
         remote_sources: sources()
       }}
    else
      {:error, %Error{} = error} -> {:error, Protocol.error_map(error)}
      {:error, %{code: _code} = error} -> {:error, error}
      {:error, code} when is_atom(code) -> {:error, safe_error(code)}
    end
  end

  @spec prepare(binary(), binary(), keyword()) :: {:ok, map()} | {:error, map()}
  def prepare(reference, arguments, opts \\ [])
      when is_binary(reference) and is_binary(arguments) and is_list(opts) do
    with {:ok, source, skill_id} <- configured_reference(reference),
         :ok <- preparable(source),
         {:ok, remote} <- remote_source(source, opts),
         {:ok, %PreparedSkill{} = prepared} <-
           RemoteSource.prepare(remote, skill_id, offline: source.offline?) do
      ref = ref_map(prepared.manifest.ref)
      digest = prepared.manifest.artifact_digest

      {:ok,
       %{
         content: SlashCommands.expand_body(prepared.document.body_raw, arguments),
         skill: %{ref: ref, digest: digest},
         prepared_resources: [
           %{
             root: prepared.root,
             ref: ref,
             digest: digest,
             release: fn -> :ok end
           }
         ]
       }}
    else
      {:error, %Error{} = error} -> {:error, Protocol.error_map(error)}
      {:error, %{code: _code} = error} -> {:error, error}
      {:error, code} when is_atom(code) -> {:error, safe_error(code)}
    end
  end

  defp configured_source(source_id) when is_binary(source_id) and source_id != "" do
    case Enum.find(ConfigManager.skill_sources(), &(&1.source_id == source_id)) do
      nil -> {:error, :skill_not_found}
      source -> {:ok, source}
    end
  end

  defp configured_source(_source_id), do: {:error, :invalid_skill_metadata}

  defp configured_reference(reference) do
    ConfigManager.skill_sources()
    |> Enum.sort_by(&byte_size(&1.source_id), :desc)
    |> Enum.find_value({:error, :skill_not_found}, fn source ->
      prefix = source.source_id <> ":"

      if String.starts_with?(reference, prefix) do
        case String.replace_prefix(reference, prefix, "") do
          "" -> {:error, :skill_not_found}
          skill_id -> {:ok, source, skill_id}
        end
      end
    end)
  end

  defp searchable(%{enabled?: false}), do: {:error, :skill_disabled}
  defp searchable(%{offline?: true}), do: {:error, :remote_unavailable}
  defp searchable(source), do: valid_source(source)

  defp preparable(%{enabled?: false}), do: {:error, :skill_disabled}
  defp preparable(source), do: valid_source(source)

  defp valid_source(source) do
    if source_status(source) in ["configured", "offline"],
      do: :ok,
      else: {:error, :invalid_skill_metadata}
  end

  defp remote_source(source, opts) do
    source_opts =
      opts
      |> Keyword.get(
        :source_options,
        Application.get_env(:sigma_session, :remote_skill_source_options, [])
      )
      |> Keyword.merge(
        endpoint: source.base_url,
        source_id: source.source_id,
        access_context_id: source.access_context_id,
        credential_supplier: ConfigManager.credential_supplier(source.credential_id)
      )

    RemoteSource.new(source_opts)
  end

  defp catalog_options(params) do
    [
      q: optional_string(value(params, :q)),
      cursor: optional_string(value(params, :cursor)),
      limit: limit(value(params, :limit)),
      fields: [:argument_hint]
    ]
  end

  defp value(params, :source_id),
    do: Map.get(params, :source_id) || Map.get(params, "source_id") || Map.get(params, "sourceId")

  defp value(params, key), do: Map.get(params, key) || Map.get(params, Atom.to_string(key))

  defp optional_string(value) when is_binary(value) and value != "", do: value
  defp optional_string(_value), do: nil

  defp limit(value) when is_integer(value), do: value |> max(1) |> min(@max_limit)

  defp limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> limit(parsed)
      _invalid -> @default_limit
    end
  end

  defp limit(_value), do: @default_limit

  defp descriptor(%Descriptor{ref: %SkillRef{} = ref} = descriptor, source) do
    %{
      skill_id: source.source_id <> ":" <> ref.skill_id,
      source_id: source.source_id,
      source_key: ref.skill_id,
      name: descriptor.name,
      description: descriptor.description || "",
      reference: source.source_id <> ":" <> ref.skill_id,
      source_kind: "backplane",
      manual_only?: true,
      argument_hint: optional_descriptor_field(descriptor, :argument_hint),
      enabled?: descriptor.publication_status == "ready",
      revision: descriptor.revision,
      artifact_digest: descriptor.artifact_digest,
      status: descriptor.publication_status
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

  defp optional_descriptor_field(descriptor, field), do: Map.get(descriptor, field)

  defp source_status(source) do
    cond do
      not source.enabled? -> "disabled"
      source.base_url == "" -> "invalid_configuration"
      source.credential_id == "" -> "invalid_configuration"
      source.access_context_id == "" -> "invalid_configuration"
      source.offline? -> "offline"
      not ConfigManager.credential_available?(source.credential_id) -> "credential_unavailable"
      true -> "configured"
    end
  end

  defp revision(items, cursor) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary({items, cursor}))
    |> Base.encode16(case: :lower)
  end

  defp safe_error(code) do
    messages = %{
      skill_not_found: "Skill not found",
      skill_disabled: "Skill is disabled",
      remote_unavailable: "Skill source is unavailable",
      invalid_skill_metadata: "Skill source configuration is invalid"
    }

    %{code: code, message: Map.get(messages, code, "Skill operation failed"), retryable?: false}
  end
end
