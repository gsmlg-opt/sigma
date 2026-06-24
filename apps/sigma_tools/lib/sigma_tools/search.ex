defmodule Sigma.Tools.Search do
  @moduledoc false
  @behaviour Sigma.Coding.Tool

  alias Sigma.Coding.Utils.PathUtils
  alias Sigma.Tools.{Hashline, Result, Store}

  @default_limit 100
  @max_line_length 500

  @impl true
  def name, do: "search"

  @impl true
  def description do
    "Search local file contents with a regex and return matching lines grouped under hashline [path#TAG] headers."
  end

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{"type" => "string", "description" => "Regex pattern to search for"},
        "paths" => %{
          "oneOf" => [%{"type" => "string"}, %{"type" => "array", "items" => %{"type" => "string"}}],
          "description" => "File, directory, or glob path(s) to search"
        },
        "i" => %{"type" => "boolean", "description" => "Case-insensitive search"},
        "limit" => %{"type" => "integer", "description" => "Maximum number of matches", "minimum" => 1}
      },
      "required" => ["pattern", "paths"]
    }
  end

  @impl true
  def execute(_tool_call_id, params, opts) do
    pattern = Map.get(params, "pattern")
    paths = params |> Map.get("paths") |> List.wrap()
    ignore_case = Map.get(params, "i", false)
    limit = Map.get(params, "limit", @default_limit)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    flags = if ignore_case, do: "i", else: ""

    with {:ok, re} <- compile_regex(pattern, flags),
         {:ok, files} <- resolve_files(paths, cwd) do
      {groups, count} = search_files(files, re, limit, cwd, Store.from_opts(opts))

      text =
        case groups do
          [] -> "No matches found for: #{pattern}"
          groups -> Enum.join(groups, "\n\n")
        end

      {:ok, Result.text(text, %{match_count: count})}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp compile_regex(pattern, flags) do
    case Regex.compile(pattern, flags) do
      {:ok, re} -> {:ok, re}
      {:error, {msg, _}} -> {:error, "Invalid regex: #{msg}"}
    end
  end

  defp resolve_files(paths, cwd) do
    paths
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      case resolve_one(path, cwd) do
        {:ok, files} -> {:cont, {:ok, acc ++ files}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, files |> Enum.uniq() |> Enum.sort()}
      error -> error
    end
  end

  defp resolve_one(path, cwd) do
    if glob?(path) do
      {:ok, Path.wildcard(Path.expand(path, cwd), match_dot: false) |> Enum.filter(&File.regular?/1)}
    else
      case PathUtils.safe_resolve(path, cwd) do
        {:ok, abs_path} when is_binary(abs_path) ->
          cond do
            File.regular?(abs_path) -> {:ok, [abs_path]}
            File.dir?(abs_path) -> {:ok, Path.wildcard(Path.join(abs_path, "**/*"), match_dot: false) |> Enum.filter(&File.regular?/1)}
            true -> {:ok, []}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp search_files(files, re, limit, cwd, store) do
    Enum.reduce_while(files, {[], 0}, fn file, {groups, count} ->
      if count >= limit do
        {:halt, {groups, count}}
      else
        case File.read(file) do
          {:ok, raw} ->
            {_bom, text} = Hashline.strip_bom(raw)
            normalized = Hashline.normalize_to_lf(text)
            remaining = limit - count
            matches = grep_file(normalized, re, remaining)

            if matches == [] do
              {:cont, {groups, count}}
            else
              rel = Path.relative_to(file, cwd)
              tag = Store.record_snapshot(store, Store.canonical_path(file), normalized)
              header = Hashline.format_header(rel, tag)
              lines = Enum.map_join(matches, "\n", fn {line_no, line} -> "#{line_no}:#{truncate(line)}" end)
              {:cont, {[header <> "\n" <> lines | groups], count + length(matches)}}
            end

          {:error, _reason} ->
            {:cont, {groups, count}}
        end
      end
    end)
    |> then(fn {groups, count} -> {Enum.reverse(groups), count} end)
  end

  defp grep_file(text, re, limit) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce_while([], fn {line, line_no}, acc ->
      cond do
        length(acc) >= limit -> {:halt, acc}
        Regex.match?(re, line) -> {:cont, [{line_no, line} | acc]}
        true -> {:cont, acc}
      end
    end)
    |> Enum.reverse()
  end

  defp truncate(line) do
    if String.length(line) > @max_line_length do
      String.slice(line, 0, @max_line_length) <> "..."
    else
      line
    end
  end

  defp glob?(path), do: String.contains?(path, ["*", "?", "["])
end
