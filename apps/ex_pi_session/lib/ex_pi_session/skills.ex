defmodule PiSession.Skills do
  @moduledoc """
  Discovers Agent Skills from user and repository skill directories.
  """

  defmodule Skill do
    @moduledoc false

    @enforce_keys [:name, :description, :path, :source]
    defstruct [:name, :description, :path, :source, disable_model_invocation?: false]
  end

  defmodule Diagnostic do
    @moduledoc false

    @enforce_keys [:path, :message]
    defstruct [:path, :message]
  end

  @doc "Returns the user-level skills directory."
  def global_skills_dir do
    Application.get_env(:ex_pi_session, :global_skills_dir) ||
      Path.join([System.user_home!(), ".agents", "skills"])
  end

  @doc "Returns the repository-level skills directory for a working directory."
  def repository_skills_dir(workdir) do
    Path.join([workdir, ".agents", "skills"])
  end

  @doc "Lists user-level skills from ~/.agents/skills."
  def list_global do
    list_dir(global_skills_dir(), :global)
  end

  @doc "Lists repository-level skills from <workdir>/.agents/skills."
  def list_repository(workdir) do
    workdir
    |> repository_skills_dir()
    |> list_dir(:repository)
  end

  @doc "Lists skills in a specific directory and tags them with their source."
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

  defp skip_entry?(entry) do
    String.starts_with?(entry, ".") or entry == "node_modules"
  end

  defp load_skill(path, source) do
    with {:ok, content} <- File.read(path),
         metadata <- parse_frontmatter(content),
         {:ok, description} <- required_description(metadata) do
      name =
        metadata
        |> Map.get("name", path |> Path.dirname() |> Path.basename())
        |> to_string()
        |> String.trim()

      {:ok,
       %Skill{
         name: name,
         description: description,
         path: path,
         source: source,
         disable_model_invocation?: Map.get(metadata, "disable-model-invocation") == true
       }}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, %Diagnostic{path: path, message: "could not read skill: #{reason}"}}

      {:error, message} ->
        {:error, %Diagnostic{path: path, message: message}}
    end
  end

  defp required_description(metadata) do
    case metadata |> Map.get("description", "") |> to_string() |> String.trim() do
      "" -> {:error, "description is required"}
      description -> {:ok, description}
    end
  end

  defp parse_frontmatter(content) do
    content
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.split("\n", trim: false)
    |> frontmatter_lines()
    |> Enum.reduce(%{}, fn line, metadata ->
      case parse_metadata_line(line) do
        nil -> metadata
        {key, value} -> Map.put(metadata, key, value)
      end
    end)
  end

  defp frontmatter_lines(["---" | rest]) do
    case Enum.split_while(rest, &(&1 != "---")) do
      {lines, ["---" | _body]} -> lines
      _ -> []
    end
  end

  defp frontmatter_lines(_lines), do: []

  defp parse_metadata_line(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" or String.starts_with?(trimmed, "#") ->
        nil

      String.contains?(trimmed, ":") ->
        [key, value] = String.split(trimmed, ":", parts: 2)
        {String.trim(key), parse_scalar(value)}

      true ->
        nil
    end
  end

  defp parse_scalar(value) do
    value = String.trim(value)

    case value do
      "true" -> true
      "false" -> false
      _ -> trim_quotes(value)
    end
  end

  defp trim_quotes(value) do
    cond do
      String.starts_with?(value, "\"") and String.ends_with?(value, "\"") ->
        value |> String.trim_leading("\"") |> String.trim_trailing("\"")

      String.starts_with?(value, "'") and String.ends_with?(value, "'") ->
        value |> String.trim_leading("'") |> String.trim_trailing("'")

      true ->
        value
    end
  end
end
