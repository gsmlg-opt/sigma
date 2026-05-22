defmodule PiCoding.Tools.Grep do
  @moduledoc """
  Tool for searching file contents by regex pattern.
  """
  @behaviour PiCoding.Tool

  alias PiCoding.Utils.PathUtils

  @default_limit 100
  @max_line_length 500

  @impl true
  def name, do: "grep"

  @impl true
  def description do
    "Search file contents using a regex pattern. Returns matching lines with file path and line number in 'file:line: content' format. Use the glob parameter to restrict which files are searched."
  end

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{
          "type" => "string",
          "description" => "Search pattern (regular expression)"
        },
        "path" => %{
          "type" => "string",
          "description" => "File or directory to search (default: current working directory)"
        },
        "glob" => %{
          "type" => "string",
          "description" => "Glob pattern to filter files, e.g. '*.ex' or '**/*.exs'"
        },
        "ignore_case" => %{
          "type" => "boolean",
          "description" => "Case-insensitive search (default: false)"
        },
        "context" => %{
          "type" => "integer",
          "description" => "Number of lines of context to show around each match (default: 0)",
          "minimum" => 0
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Maximum number of matches to return (default: #{@default_limit})",
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
    glob_filter = Map.get(params, "glob")
    ignore_case = Map.get(params, "ignore_case", false)
    context_lines = Map.get(params, "context", 0)
    limit = Map.get(params, "limit", @default_limit)
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    re_flags = if ignore_case, do: "i", else: ""

    case Regex.compile(pattern, re_flags) do
      {:error, {msg, _}} ->
        {:error, "Invalid regex: #{msg}"}

      {:ok, re} ->
        case PathUtils.safe_resolve(search_path, cwd) do
          {:error, reason} ->
            {:error, reason}

          {:ok, abs_path} ->
            files = collect_files(abs_path, glob_filter)
            {matches, limit_reached} = search_files(files, re, context_lines, limit, cwd)

            text =
              case matches do
                [] ->
                  "No matches found for: #{pattern}"

                lines ->
                  result = Enum.join(lines, "\n")

                  if limit_reached,
                    do: result <> "\n(#{limit} match limit reached)",
                    else: result
              end

            {:ok,
             %{
               content: [%{type: :text, text: text, text_signature: nil}],
               details: %{match_count: length(matches)}
             }}
        end
    end
  end

  defp collect_files(abs_path, glob_filter) do
    if File.dir?(abs_path) do
      patterns =
        if glob_filter do
          # Direct match (root level) + recursive match (**/ prefix)
          [Path.join(abs_path, glob_filter), Path.join(abs_path, "**/" <> glob_filter)]
        else
          [Path.join(abs_path, "**/*")]
        end

      patterns
      |> Enum.flat_map(&Path.wildcard(&1, match_dot: false))
      |> Enum.uniq()
      |> Enum.filter(&File.regular?/1)
    else
      if File.regular?(abs_path), do: [abs_path], else: []
    end
  end

  defp search_files(files, re, context_lines, limit, cwd) do
    Enum.reduce_while(files, {[], false}, fn file, {acc, _} ->
      remaining = limit - length(acc)

      if remaining <= 0 do
        {:halt, {acc, true}}
      else
        case File.read(file) do
          {:ok, content} ->
            rel = Path.relative_to(file, cwd)
            new_matches = grep_file(content, re, rel, context_lines, remaining)
            new_acc = acc ++ new_matches
            reached = length(new_acc) >= limit
            if reached, do: {:halt, {new_acc, true}}, else: {:cont, {new_acc, false}}

          _ ->
            {:cont, {acc, false}}
        end
      end
    end)
  end

  defp grep_file(content, re, rel_path, context_lines, limit) do
    lines = String.split(content, ~r/\R/u)
    total = length(lines)

    matching_indices =
      lines
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _} -> Regex.match?(re, line) end)
      |> Enum.map(fn {_, idx} -> idx end)

    Enum.reduce_while(matching_indices, [], fn match_idx, acc ->
      if length(acc) >= limit do
        {:halt, acc}
      else
        start_idx = max(1, match_idx - context_lines)
        end_idx = min(total, match_idx + context_lines)

        block =
          Enum.slice(lines, (start_idx - 1)..(end_idx - 1))
          |> Enum.with_index(start_idx)
          |> Enum.map_join("\n", fn {line, line_no} ->
            sep = if line_no == match_idx, do: ":", else: "-"

            truncated =
              if String.length(line) > @max_line_length,
                do: String.slice(line, 0, @max_line_length) <> "…",
                else: line

            "#{rel_path}:#{line_no}#{sep} #{truncated}"
          end)

        {:cont, acc ++ [block]}
      end
    end)
  end
end
