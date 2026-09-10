defmodule Sigma.Session.Skills do
  @moduledoc "Discovers Agent Skills from user and repository skill directories."

  alias Sigma.Session.{ConfigManager, RepoManager, Skills.Parser}

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
    global_skills_dir() |> list_dir(:global) |> mark_enabled(disabled)
  end

  def list_repository(workdir),
    do:
      workdir
      |> repository_skills_dir()
      |> list_dir(:repository)
      |> mark_enabled(MapSet.new(RepoManager.disabled_skills(workdir)))

  @doc """
  Global skills with the project-level disabled names for `workdir` applied
  on top of the global `disabledSkills` setting. A global skill is enabled
  only when it is enabled globally and not disabled for this project.
  """
  def list_global_for_repository(workdir) do
    disabled = disabled_global_and_project(workdir)
    global_skills_dir() |> list_dir(:global) |> mark_enabled(disabled)
  end

  defp disabled_global_and_project(workdir) do
    ConfigManager.disabled_global_skills()
    |> Enum.concat(RepoManager.disabled_skills(workdir))
    |> MapSet.new()
  end

  def list_dir(root_dir, source) do
    if File.dir?(root_dir) do
      {skills, diagnostics} =
        root_dir
        |> skill_files()
        |> Enum.map(&load_skill(&1, source))
        |> Enum.reduce({[], []}, fn
          {:ok, skill}, {skills, diagnostics} -> {[skill | skills], diagnostics}
          {:error, diagnostic}, {skills, diagnostics} -> {skills, [diagnostic | diagnostics]}
        end)

      %{
        dir: root_dir,
        skills: Enum.sort_by(skills, & &1.name),
        diagnostics: Enum.reverse(diagnostics)
      }
    else
      %{dir: root_dir, skills: [], diagnostics: []}
    end
  end

  defp skill_files(dir) do
    skill_file = Path.join(dir, "SKILL.md")

    cond do
      File.regular?(skill_file) ->
        [skill_file]

      true ->
        case File.ls(dir) do
          {:ok, entries} ->
            entries
            |> Enum.reject(&skip_entry?/1)
            |> Enum.sort()
            |> Enum.flat_map(fn entry ->
              path = Path.join(dir, entry)
              if File.dir?(path), do: skill_files(path), else: []
            end)

          {:error, _reason} ->
            []
        end
    end
  end

  defp skip_entry?(entry), do: String.starts_with?(entry, ".") or entry == "node_modules"

  defp load_skill(path, source) do
    with {:ok, content} <- File.read(path),
         {:ok, metadata} <- Parser.parse(content),
         :ok <- valid_policy_types(metadata),
         {:ok, description} <- required_description(metadata),
         {:ok, name} <- skill_name(metadata, path) do
      {:ok,
       %Skill{
         name: name,
         description: description,
         path: path,
         source: source,
         metadata: metadata,
         argument_hint: Map.get(metadata, "argument-hint"),
         disable_model_invocation?: Map.get(metadata, "disable-model-invocation") == true
       }}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, %Diagnostic{path: path, message: "could not read skill: #{reason}"}}

      {:error, message} ->
        {:error, %Diagnostic{path: path, message: message}}
    end
  end

  defp skill_name(metadata, path) do
    case Map.get(metadata, "name") do
      nil ->
        {:ok, path |> Path.dirname() |> Path.basename()}

      name when is_binary(name) ->
        if String.trim(name) == "" do
          {:error, "name must be a non-empty string"}
        else
          {:ok, String.trim(name)}
        end

      _name ->
        {:error, "name must be a non-empty string"}
    end
  end

  defp mark_enabled(result, disabled_names) do
    skills =
      Enum.map(result.skills, &%{&1 | enabled?: not MapSet.member?(disabled_names, &1.name)})

    %{result | skills: skills}
  end

  defp required_description(metadata) do
    case Map.get(metadata, "description") do
      description when is_binary(description) ->
        if String.trim(description) == "" do
          {:error, "description is required"}
        else
          {:ok, String.trim(description)}
        end

      nil ->
        {:error, "description is required"}

      _description ->
        {:error, "description must be a string"}
    end
  end

  defp valid_policy_types(metadata) do
    with :ok <- validate_boolean(metadata, "disable-model-invocation"),
         :ok <- validate_string(metadata, "argument-hint") do
      :ok
    end
  end

  defp validate_boolean(metadata, key) do
    case Map.get(metadata, key) do
      nil -> :ok
      value when is_boolean(value) -> :ok
      _value -> {:error, "#{key} must be a boolean"}
    end
  end

  defp validate_string(metadata, key) do
    case Map.get(metadata, key) do
      nil -> :ok
      value when is_binary(value) -> :ok
      _value -> {:error, "#{key} must be a string"}
    end
  end
end
