defmodule Sigma.Session.Skills do
  @moduledoc "Discovers Agent Skills from user and repository skill directories."

  alias Backplane.SkillProtocol.Descriptor
  alias Backplane.SkillProtocol.Source.Local
  alias Sigma.Session.{ConfigManager, RepoManager, Skills.Protocol}

  @max_depth 32
  @max_entries 2_000
  @max_diagnostics 100

  defmodule Skill do
    @moduledoc false
    @type t :: %__MODULE__{}
    @enforce_keys [:name, :description, :path, :source]
    defstruct [
      :name,
      :description,
      :path,
      :source,
      :skill_id,
      :source_id,
      :source_key,
      metadata: %{},
      argument_hint: nil,
      disable_model_invocation?: false,
      enabled?: true
    ]
  end

  defmodule Diagnostic do
    @moduledoc false
    @enforce_keys [:path, :message]
    defstruct [:path, :message]
  end

  def global_skills_dir do
    Application.get_env(:sigma_session, :global_skills_dir) ||
      Path.join([System.user_home!(), ".agents", "skills"])
  end

  def repository_skills_dir(workdir), do: Path.join([workdir, ".agents", "skills"])

  def list_global do
    disabled = ConfigManager.disabled_global_skills() |> MapSet.new()
    global_skills_dir() |> discover_dir(:global) |> mark_enabled(disabled) |> public_result()
  end

  def list_repository(workdir),
    do:
      workdir
      |> repository_skills_dir()
      |> discover_dir(:repository)
      |> mark_enabled(MapSet.new(RepoManager.disabled_skills(workdir)))
      |> public_result()

  @doc """
  Global skills with the project-level disabled names for `workdir` applied
  on top of the global `disabledSkills` setting. A global skill is enabled
  only when it is enabled globally and not disabled for this project.
  """
  def list_global_for_repository(workdir) do
    disabled = disabled_global_and_project(workdir)
    global_skills_dir() |> discover_dir(:global) |> mark_enabled(disabled) |> public_result()
  end

  defp disabled_global_and_project(workdir) do
    ConfigManager.disabled_global_skills()
    |> Enum.concat(RepoManager.disabled_skills(workdir))
    |> MapSet.new()
  end

  def list_dir(root_dir, source) do
    root_dir |> discover_dir(source) |> public_result()
  end

  @doc false
  def discover_dir(root_dir, source) when source in [:repository, :global] do
    if File.dir?(root_dir) do
      root = Path.expand(root_dir)
      source_id = source_id(source, root)

      discover_root(root_dir, root, source, source_id)
    else
      %{dir: root_dir, entries: [], skills: [], diagnostics: []}
    end
  end

  defp discover_root(root_dir, root, source, source_id) do
    roots = [%{source_id: source_id, path: root, precedence: precedence(source)}]

    case Local.discover_with_diagnostics(roots,
           max_depth: @max_depth,
           max_entries: @max_entries,
           max_diagnostics: @max_diagnostics
         ) do
      {:ok, descriptors, package_diagnostics} ->
        {entries, document_diagnostics} = load_descriptors(descriptors, source)

        diagnostics =
          package_diagnostics
          |> Enum.map(&package_diagnostic(&1, root))
          |> Kernel.++(document_diagnostics)
          |> Enum.take(@max_diagnostics)

        %{
          dir: root_dir,
          entries: entries,
          skills: entries |> Enum.map(& &1.skill) |> Enum.sort_by(& &1.name),
          diagnostics: diagnostics
        }

      {:error, error} ->
        %{path: path, message: message} = Protocol.discovery_error(error)

        %{
          dir: root_dir,
          entries: [],
          skills: [],
          diagnostics: [%Diagnostic{path: path, message: message}]
        }
    end
  end

  defp load_descriptors(descriptors, source) do
    descriptors
    |> Enum.map(&load_skill(&1, source))
    |> Enum.reduce({[], []}, fn
      {:ok, entry}, {entries, diagnostics} -> {[entry | entries], diagnostics}
      {:error, diagnostic}, {entries, diagnostics} -> {entries, [diagnostic | diagnostics]}
    end)
    |> then(fn {entries, diagnostics} ->
      {Enum.reverse(entries), Enum.reverse(diagnostics)}
    end)
  end

  defp load_skill(%Descriptor{} = descriptor, source) do
    with {:ok, content} <- File.read(descriptor.path),
         {:ok, document} <- Protocol.parse_document(content) do
      source_id = descriptor.ref.source_id
      source_key = descriptor.ref.skill_id

      skill = %Skill{
        name: document.name,
        description: document.description,
        path: descriptor.path,
        source: source,
        skill_id: source_id <> ":" <> source_key,
        source_id: source_id,
        source_key: source_key,
        metadata: document.metadata,
        argument_hint: document.metadata["argument-hint"],
        disable_model_invocation?: document.metadata["disable-model-invocation"] == true
      }

      {:ok,
       %{
         skill: skill,
         document: document,
         descriptor: descriptor
       }}
    else
      {:error, error} when is_map(error) ->
        {:error,
         %Diagnostic{
           path: descriptor.ref.skill_id,
           message: Protocol.primary_diagnostic_message(error)
         }}

      {:error, _reason} ->
        {:error,
         %Diagnostic{path: descriptor.ref.skill_id, message: "skill document cannot be read"}}
    end
  end

  defp package_diagnostic(diagnostic, root) do
    %{path: path, message: message} = Protocol.discovery_diagnostic(diagnostic)

    message =
      with true <- path != ".",
           {:ok, content} <- File.read(Path.join(root, path)),
           {:error, error} <- Protocol.parse_document(content) do
        Protocol.primary_diagnostic_message(error)
      else
        _ -> message
      end

    %Diagnostic{path: path, message: message}
  end

  defp mark_enabled(result, disabled_names) do
    entries =
      Enum.map(result.entries, fn %{skill: skill} = entry ->
        %{entry | skill: %{skill | enabled?: not MapSet.member?(disabled_names, skill.name)}}
      end)

    %{
      result
      | entries: entries,
        skills: entries |> Enum.map(& &1.skill) |> Enum.sort_by(& &1.name)
    }
  end

  defp public_result(result), do: Map.drop(result, [:entries])
  defp precedence(:repository), do: 0
  defp precedence(:global), do: 100
  defp source_id(:global, _root), do: "global"
  defp source_id(:repository, root), do: "repo-" <> digest(root)

  defp digest(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower) |> binary_part(0, 16)
end
