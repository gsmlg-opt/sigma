defmodule PiTools.Find do
  @moduledoc false
  @behaviour PiCoding.Tool

  alias PiCoding.Utils.PathUtils
  alias PiTools.Result

  @default_limit 1000

  @impl true
  def name, do: "find"

  @impl true
  def description do
    "Find local files or directories by path or glob and return paths relative to the working directory."
  end

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "paths" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "One or more globs, files, or directories"
        },
        "hidden" => %{"type" => "boolean", "description" => "Whether hidden files are included"},
        "limit" => %{"type" => "integer", "description" => "Maximum number of returned paths", "minimum" => 1}
      },
      "required" => ["paths"]
    }
  end

  @impl true
  def execute(_tool_call_id, params, opts) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    paths = Map.get(params, "paths", [])
    hidden = Map.get(params, "hidden", false)
    limit = Map.get(params, "limit", @default_limit)

    with {:ok, matches} <- resolve_matches(paths, cwd, hidden) do
      shown = matches |> Enum.uniq() |> Enum.sort() |> Enum.take(limit)
      text = if shown == [], do: "No files matched.", else: Enum.join(shown, "\n")
      {:ok, Result.text(text, %{count: length(shown)})}
    end
  end

  defp resolve_matches(paths, cwd, hidden) when is_list(paths) do
    paths
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      case resolve_one(path, cwd, hidden) do
        {:ok, matches} -> {:cont, {:ok, acc ++ matches}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp resolve_matches(_paths, _cwd, _hidden), do: {:error, "paths must be an array of path or glob strings."}

  defp resolve_one(path, cwd, hidden) do
    if glob?(path) do
      matches =
        path
        |> Path.expand(cwd)
        |> Path.wildcard(match_dot: hidden)
        |> Enum.map(&Path.relative_to(&1, cwd))

      {:ok, matches}
    else
      case PathUtils.safe_resolve(path, cwd) do
        {:ok, abs_path} ->
          matches =
            cond do
              File.dir?(abs_path) ->
                abs_path
                |> Path.join("**/*")
                |> Path.wildcard(match_dot: hidden)
                |> Enum.map(&Path.relative_to(&1, cwd))

              File.exists?(abs_path) ->
                [Path.relative_to(abs_path, cwd)]

              true ->
                []
            end

          {:ok, matches}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp glob?(path), do: String.contains?(path, ["*", "?", "["])
end
