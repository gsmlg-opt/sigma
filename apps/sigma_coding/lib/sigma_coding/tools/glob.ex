defmodule Sigma.Coding.Tools.Glob do
  @moduledoc """
  Tool for finding files by glob pattern.
  """
  @behaviour Sigma.Coding.Tool

  alias Sigma.Coding.Utils.PathUtils

  @default_limit 1000

  @impl true
  def name, do: "glob"

  @impl true
  def description do
    "Find files and directories matching a glob pattern. Use ** for recursive matching (e.g. 'src/**/*.ex', '**/*.json'). Returns paths relative to the working directory, sorted alphabetically."
  end

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{
          "type" => "string",
          "description" =>
            "Glob pattern to match, e.g. '*.ex', '**/*.json', 'lib/**/*.ex'. Use ** for recursive matching."
        },
        "path" => %{
          "type" => "string",
          "description" => "Directory to search in (default: current working directory)"
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Maximum number of results to return (default: #{@default_limit})",
          "minimum" => 1
        }
      },
      "required" => ["pattern"]
    }
  end

  @impl true
  def execute(_tool_call_id, params, opts) do
    pattern = Map.get(params, "pattern")
    search_path = Map.get(params, "path", ".")
    limit = Map.get(params, "limit", @default_limit)
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    case PathUtils.safe_resolve(search_path, cwd) do
      {:ok, abs_dir} ->
        full_pattern = Path.join(abs_dir, pattern)
        all_matches = Path.wildcard(full_pattern, match_dot: false)
        truncated = length(all_matches) > limit
        matches = all_matches |> Enum.take(limit) |> Enum.map(&Path.relative_to(&1, cwd))

        text =
          case matches do
            [] ->
              "No files matched: #{pattern}"

            paths ->
              result = Enum.join(paths, "\n")

              if truncated,
                do: result <> "\n(limit of #{limit} reached, refine your pattern)",
                else: result
          end

        {:ok,
         %{
           content: [%{type: :text, text: text, text_signature: nil}],
           details: %{count: length(matches)}
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
