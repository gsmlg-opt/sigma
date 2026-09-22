defmodule Sigma.Session.Skills.Facade do
  @moduledoc "Safe, plain-map Skill catalog boundary for public adapters."

  alias Sigma.Session.Skills
  alias Sigma.Session.Skills.RemoteAdapter

  @spec catalog(binary()) :: map()
  def catalog(workdir) when is_binary(workdir) do
    catalog = Skills.Catalog.build(workdir)

    %{
      catalog_revision: catalog.revision,
      items: Enum.map(catalog.skills, &descriptor/1),
      next_cursor: nil,
      partial: false,
      diagnostics: Enum.map(catalog.diagnostics, &diagnostic/1),
      remote_sources: remote_sources()
    }
  end

  @spec descriptor(Skills.Skill.t()) :: map()
  def descriptor(skill) do
    %{
      skill_id: skill.skill_id,
      source_id: skill.source_id,
      source_key: skill.source_key,
      name: skill.name,
      description: skill.description,
      reference: reference(skill),
      source_kind: Atom.to_string(skill.source),
      manual_only?: skill.disable_model_invocation?,
      argument_hint: skill.argument_hint,
      enabled?: skill.enabled?,
      revision: nil,
      artifact_digest: nil,
      status: if(skill.enabled?, do: "available", else: "disabled")
    }
  end

  @spec remote_sources() :: [map()]
  def remote_sources do
    RemoteAdapter.sources()
  end

  @spec remote_catalog(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def remote_catalog(params, opts \\ []), do: RemoteAdapter.catalog(params, opts)

  defp diagnostic(diagnostic) do
    %{
      code: "invalid_skill_metadata",
      message: diagnostic.message,
      status: "invalid"
    }
  end

  defp reference(%{source: :repository, name: name}), do: "repo:" <> name
  defp reference(%{source: :global, name: name}), do: "global:" <> name
end
