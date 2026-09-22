defmodule Sigma.Session.Skills.Catalog do
  @moduledoc "Source-aware local skill catalog and deterministic resolver."

  alias Backplane.SkillProtocol.{Eligibility, Resolver}
  alias Sigma.Session.{ConfigManager, RepoManager, Skills}

  @type t :: %{
          revision: binary(),
          skills: [Skills.Skill.t()],
          entries: [map()],
          diagnostics: [Skills.Diagnostic.t()]
        }

  @spec build(binary()) :: t()
  def build(workdir) when is_binary(workdir) do
    global = Skills.discover_dir(Skills.global_skills_dir(), :global)
    repository = Skills.discover_dir(Skills.repository_skills_dir(workdir), :repository)

    entries =
      repository.entries
      |> mark_entries_enabled(RepoManager.disabled_skills(workdir))
      |> Kernel.++(
        global.entries
        |> mark_entries_enabled(
          ConfigManager.disabled_global_skills() ++ RepoManager.disabled_skills(workdir)
        )
      )

    skills = Enum.map(entries, & &1.skill)

    diagnostics = repository.diagnostics ++ global.diagnostics

    %{
      revision: revision(skills, diagnostics),
      skills: skills,
      entries: entries,
      diagnostics: diagnostics
    }
  end

  @spec automatic(t()) :: [Skills.Skill.t()]
  def automatic(catalog), do: eligible(catalog, :automatic)

  @spec explicit(t()) :: [Skills.Skill.t()]
  def explicit(catalog), do: eligible(catalog, :explicit)

  @spec resolve(t(), binary()) :: {:ok, Skills.Skill.t()} | {:error, atom()}
  def resolve(catalog, reference), do: resolve(catalog, reference, :explicit)

  @spec resolve(t(), binary(), :automatic | :explicit) ::
          {:ok, Skills.Skill.t()} | {:error, atom()}
  def resolve(%{entries: entries}, reference, trigger)
      when is_binary(reference) and trigger in [:automatic, :explicit] do
    reference = String.trim(reference)

    with {:ok, resolved} <- resolve_descriptor(entries, reference),
         %{skill: skill, document: document} <- Enum.find(entries, &(&1.descriptor == resolved)) do
      case Eligibility.evaluate(document, trigger, %{enabled: skill.enabled?}) do
        {:ok, :eligible} -> {:ok, skill}
        {:error, %{code: :host_disabled}} -> {:error, :skill_disabled}
        {:error, %{code: :explicit_disabled}} -> {:error, :skill_disabled}
        {:error, %{code: :manual_only}} -> {:error, :manual_invocation_required}
        {:error, %{code: :not_user_invocable}} -> {:error, :unsupported_skill_kind}
      end
    else
      {:error, %{code: :not_found}} -> {:error, :skill_not_found}
      {:error, %{code: :ambiguous_skill}} -> {:error, :ambiguous_skill}
    end
  end

  def resolve(_catalog, _reference, _trigger), do: {:error, :skill_not_found}

  defp eligible(%{entries: entries}, trigger) do
    entries
    |> Enum.filter(fn %{document: document, skill: skill} ->
      Eligibility.evaluate(document, trigger, %{enabled: skill.enabled?}) == {:ok, :eligible}
    end)
    |> Enum.map(& &1.skill)
  end

  defp resolve_descriptor(entries, "repo:" <> name),
    do: resolve_source(entries, :repository, name)

  defp resolve_descriptor(entries, "global:" <> name), do: resolve_source(entries, :global, name)

  defp resolve_descriptor(entries, name),
    do: Resolver.resolve(Enum.map(entries, & &1.descriptor), name)

  defp resolve_source(entries, source, name) do
    descriptors =
      entries
      |> Enum.filter(&(&1.skill.source == source))
      |> Enum.map(& &1.descriptor)

    Resolver.resolve(descriptors, name)
  end

  defp mark_entries_enabled(entries, disabled_names) do
    disabled = MapSet.new(disabled_names)

    Enum.map(entries, fn %{skill: skill} = entry ->
      %{entry | skill: %{skill | enabled?: not MapSet.member?(disabled, skill.name)}}
    end)
  end

  defp revision(skills, diagnostics) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary({skills, diagnostics}))
    |> Base.encode16(case: :lower)
  end
end
