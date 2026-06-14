defmodule PiTools.Read do
  @moduledoc false
  @behaviour PiCoding.Tool

  alias PiCoding.Utils.PathUtils
  alias PiTools.{Hashline, Result, Store}

  @snapshot_max_bytes 4 * 1024 * 1024

  @impl true
  def name, do: "read"

  @impl true
  def description do
    "Read a local file and return hashline-numbered output anchored by a [path#TAG] header."
  end

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Path to the file to read"},
        "offset" => %{
          "type" => "integer",
          "description" => "Line number to start reading from (1-indexed)",
          "minimum" => 1
        },
        "limit" => %{"type" => "integer", "description" => "Maximum number of lines to read", "minimum" => 1}
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

    with {:ok, absolute_path} <- PathUtils.safe_resolve(path, cwd, allow_skill_files?: true),
         {:ok, raw} <- read_file(absolute_path) do
      {_bom, text} = Hashline.strip_bom(raw)
      normalized = Hashline.normalize_to_lf(text)
      display_path = Path.relative_to(absolute_path, cwd)
      tag = maybe_record_snapshot(Store.from_opts(opts), absolute_path, normalized)
      lines = String.split(normalized, "\n")
      total_lines = length(lines)
      start_index = max(offset - 1, 0)

      selected_lines =
        if limit do
          Enum.slice(lines, start_index, limit)
        else
          Enum.slice(lines, start_index, total_lines)
        end

      read_count = length(selected_lines)

      body =
        selected_lines
        |> Enum.with_index(offset)
        |> Enum.map_join("\n", fn {line, line_number} -> Hashline.format_numbered_line(line_number, line) end)

      text =
        display_path
        |> Hashline.format_header(tag)
        |> Kernel.<>("\n")
        |> Kernel.<>(body)
        |> add_range_info(offset, read_count, total_lines)

      {:ok,
       Result.text(text, %{
         path: absolute_path,
         hashline_path: display_path,
         hash: tag,
         total_lines: total_lines,
         offset: offset,
         limit: limit,
         read_lines: read_count
       })}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Could not read file: #{path}. Reason: #{reason}"}
    end
  end

  defp maybe_record_snapshot(store, absolute_path, normalized) do
    if byte_size(normalized) <= @snapshot_max_bytes do
      Store.record_snapshot(store, Store.canonical_path(absolute_path), normalized)
    else
      Hashline.compute_file_hash(normalized)
    end
  end

  defp add_range_info(text, offset, read_count, total_count) do
    if offset > 1 or read_count < total_count do
      end_line = offset + read_count - 1
      info = "\n\n[Showing lines #{offset}-#{end_line} of #{total_count}."

      if end_line < total_count do
        text <> info <> " Use offset=#{end_line + 1} to continue.]"
      else
        text <> info <> "]"
      end
    else
      text
    end
  end
end
