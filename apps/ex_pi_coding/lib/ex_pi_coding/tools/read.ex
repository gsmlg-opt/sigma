defmodule PiCoding.Tools.Read do
  @moduledoc """
  Tool for reading file contents.
  """
  @behaviour PiCoding.Tool

  alias PiCoding.Utils.PathUtils

  @impl true
  def name, do: "read"

  @impl true
  def description do
    "Read the content of a file. Supports optional line range via offset and limit."
  end

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "Path to the file to read (relative or absolute)"
        },
        "offset" => %{
          "type" => "integer",
          "description" => "Line number to start reading from (1-indexed)",
          "minimum" => 1
        },
        "limit" => %{
          "type" => "integer",
          "description" => "Maximum number of lines to read",
          "minimum" => 1
        }
      },
      "required" => ["path"]
    }
  end

  @impl true
  def execute(_tool_call_id, params, opts) do
    path = Map.get(params, "path")
    offset = Map.get(params, "offset", 1)
    limit = Map.get(params, "limit")
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    case PathUtils.safe_resolve(path, cwd) do
      {:ok, absolute_path} ->
        do_read(absolute_path, offset, limit)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_read(path, offset, limit) do
    case File.read(path) do
      {:ok, content} ->
        lines = String.split(content, ~r/\R/u)
        total_lines = length(lines)

        # offset is 1-indexed
        start_index = max(0, offset - 1)

        selected_lines =
          if limit do
            Enum.slice(lines, start_index, limit)
          else
            Enum.slice(lines, start_index, total_lines)
          end

        read_count = length(selected_lines)
        result_text = Enum.join(selected_lines, "\n")

        final_text = add_range_info(result_text, offset, read_count, total_lines)

        {:ok,
         %{
           content: [%{type: :text, text: final_text, text_signature: nil}],
           details: %{
             path: path,
             total_lines: total_lines,
             offset: offset,
             limit: limit,
             read_lines: read_count
           }
         }}

      {:error, reason} ->
        {:error, "Could not read file: #{path}. Reason: #{reason}"}
    end
  end

  defp add_range_info(text, offset, read_count, total_count) do
    if offset > 1 or read_count < total_count do
      end_line = offset + read_count - 1
      info = "\n\n[Showing lines #{offset}-#{end_line} of #{total_count}."

      if end_line < total_count do
        next_offset = end_line + 1
        text <> info <> " Use offset=#{next_offset} to continue.]"
      else
        text <> info <> "]"
      end
    else
      text
    end
  end
end
