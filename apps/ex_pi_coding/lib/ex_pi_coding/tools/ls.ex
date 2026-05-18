defmodule ExPiCoding.Tools.LS do
  @moduledoc """
  Tool for listing directory contents.
  """
  @behaviour ExPiCoding.Tool

  alias ExPiCoding.Utils.PathUtils

  @default_limit 500

  @impl true
  def name, do: "ls"

  @impl true
  def description do
    "List the contents of a directory. Returns each entry prefixed with [dir] or [file]. Does not recurse — use glob with ** patterns to find files recursively."
  end

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "Directory to list (default: current working directory)"
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Maximum number of entries to return (default: #{@default_limit})",
          "minimum" => 1
        }
      },
      "required" => []
    }
  end

  @impl true
  def execute(_tool_call_id, params, opts) do
    list_path = Map.get(params, "path", ".")
    limit = Map.get(params, "limit", @default_limit)
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    case PathUtils.safe_resolve(list_path, cwd) do
      {:error, reason} ->
        {:error, reason}

      {:ok, abs_path} ->
        if not File.dir?(abs_path) do
          {:error, "Not a directory: #{list_path}"}
        else
          case File.ls(abs_path) do
            {:error, reason} ->
              {:error, "Could not list directory: #{reason}"}

            {:ok, entries} ->
              sorted = Enum.sort(entries)
              truncated = length(sorted) > limit
              shown = Enum.take(sorted, limit)

              lines =
                Enum.map(shown, fn entry ->
                  abs_entry = Path.join(abs_path, entry)
                  tag = if File.dir?(abs_entry), do: "[dir] ", else: "[file]"
                  "#{tag} #{entry}"
                end)

              suffix =
                if truncated,
                  do: ["(#{limit} entry limit reached — use a more specific path)"],
                  else: []

              text = Enum.join(lines ++ suffix, "\n")

              {:ok,
               %{
                 content: [%{type: :text, text: text, text_signature: nil}],
                 details: %{path: abs_path, count: length(shown)}
               }}
          end
        end
    end
  end
end
