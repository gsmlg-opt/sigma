defmodule Sigma.Session.Skills.Catalog do
  @moduledoc "Source-aware local skill catalog and deterministic resolver."

  alias Sigma.Session.Skills

  @type t :: %{
          revision: binary(),
          skills: [Skills.Skill.t()],
          diagnostics: [Skills.Diagnostic.t()]
        }

  @spec build(binary()) :: t()
  def build(workdir) when is_binary(workdir) do
    global = Skills.list_global_for_repository(workdir)
    repository = Skills.list_repository(workdir)

    skills =
      [
        annotate(repository.skills, :repository, repository.dir),
        annotate(global.skills, :global, global.dir)
      ]
      |> List.flatten()

    diagnostics = repository.diagnostics ++ global.diagnostics

    %{
      revision: revision(skills, diagnostics),
      skills: skills,
      diagnostics: diagnostics
    }
  end

  @spec automatic(t()) :: [Skills.Skill.t()]
  def automatic(%{skills: skills}),
    do: Enum.reject(skills, &(!&1.enabled? or &1.disable_model_invocation?))

  @spec resolve(t(), binary()) :: {:ok, Skills.Skill.t()} | {:error, atom()}
  def resolve(%{skills: skills}, reference) when is_binary(reference) do
    reference = String.trim(reference)
    {scope, name} = split_reference(reference)

    candidates =
      skills
      |> Enum.filter(fn skill ->
        skill.name == name and (is_nil(scope) or skill.source == scope)
      end)
      |> prioritize(scope)

    case candidates do
      [] -> {:error, :skill_not_found}
      [%{enabled?: false}] -> {:error, :skill_disabled}
      [skill] -> {:ok, skill}
      _many -> {:error, :ambiguous_skill}
    end
  end

  def resolve(_catalog, _reference), do: {:error, :skill_not_found}

  defp prioritize(candidates, nil) do
    case Enum.filter(candidates, &(&1.source == :repository)) do
      [] -> Enum.filter(candidates, &(&1.source == :global))
      repository -> repository
    end
  end

  defp prioritize(candidates, _scope), do: candidates

  defp annotate(skills, source, root) do
    Enum.map(skills, fn skill ->
      source_key = Path.relative_to(skill.path, root)
      source_id = source_id(source, root)
      skill_id = source_id <> ":" <> source_key

      Map.merge(skill, %{
        source: source,
        source_id: source_id,
        source_key: source_key,
        skill_id: skill_id
      })
    end)
  end

  defp source_id(:global, _root), do: "global"
  defp source_id(:repository, root), do: "repo-" <> digest(Path.expand(root))

  defp split_reference("repo:" <> name), do: {:repository, name}
  defp split_reference("global:" <> name), do: {:global, name}
  defp split_reference(name), do: {nil, name}

  defp revision(skills, diagnostics) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary({skills, diagnostics}))
    |> Base.encode16(case: :lower)
  end

  defp digest(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower) |> binary_part(0, 16)
end
