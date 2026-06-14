defmodule PiTools.Edit do
  @moduledoc false
  @behaviour PiCoding.Tool

  alias PiCoding.Utils.PathUtils
  alias PiTools.{Hashline, Result, Store}

  @impl true
  def name, do: "edit"

  @impl true
  def description do
    "Apply an oh-my-pi hashline patch. Input must start with [path#TAG] headers copied from read/search/write/edit output, then hashline operations: replace N..M:, delete N..M, insert before N:, insert after N:, insert head:, or insert tail:. Body rows for replace/insert must be +TEXT. Do not send unified diff, apply_patch, git conflict, or @@/@@@ hunk syntax."
  end

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "input" => %{
          "type" => "string",
          "description" =>
            "Hashline patch only. Format: [PATH#TAG] followed by operations such as replace N..M:\\n+new text, delete N..M, insert before N:\\n+new text, insert after N:\\n+new text, insert head:\\n+new text, or insert tail:\\n+new text. Do not send unified diff, apply_patch, git conflict markers, @@/@@@ hunk headers, or -removed/+added diff rows."
        }
      },
      "required" => ["input"]
    }
  end

  @impl true
  def execute(_tool_call_id, params, opts) do
    with {:ok, input} <- fetch_input(params),
         {:ok, sections} <- Hashline.parse_sections(input, Keyword.get(opts, :cwd, File.cwd!())),
         {:ok, prepared} <- prepare_sections(sections, opts),
         :ok <- reject_duplicate_paths(prepared),
         {:ok, results} <- commit_sections(prepared, opts) do
      {:ok, render_results(results)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_input(params) do
    case Map.get(params, "input") || Map.get(params, "_input") do
      input when is_binary(input) ->
        {:ok, input}

      _ ->
        {:error,
         "edit requires an input hashline patch; legacy path/content replacement params are not supported."}
    end
  end

  defp prepare_sections(sections, opts) do
    Enum.reduce_while(sections, {:ok, []}, fn section, {:ok, acc} ->
      case prepare_section(section, opts) do
        {:ok, prepared} -> {:cont, {:ok, [prepared | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, prepared} -> {:ok, Enum.reverse(prepared)}
      error -> error
    end
  end

  defp prepare_section(section, opts) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    path = Map.fetch!(section, "path")
    expected_hash = Map.fetch!(section, "file_hash")
    diff = Map.fetch!(section, "diff")

    with {:ok, absolute_path} <- PathUtils.safe_resolve(path, cwd),
         {:ok, raw} <- read_file(path, absolute_path) do
      {bom, text_without_bom} = Hashline.strip_bom(raw)
      line_ending = Hashline.detect_line_ending(text_without_bom)
      normalized = Hashline.normalize_to_lf(text_without_bom)
      canonical_path = Store.canonical_path(absolute_path)
      actual_hash = Hashline.compute_file_hash(normalized)

      if actual_hash == expected_hash do
        apply_section(section, %{
          path: path,
          absolute_path: absolute_path,
          canonical_path: canonical_path,
          expected_hash: expected_hash,
          before: normalized,
          bom: bom,
          line_ending: line_ending,
          diff: diff
        })
      else
        {:error,
         mismatch_message(Store.from_opts(opts), canonical_path, path, expected_hash, actual_hash)}
      end
    end
  end

  defp read_file(display_path, absolute_path) do
    case File.read(absolute_path) do
      {:ok, content} ->
        {:ok, content}

      {:error, :enoent} ->
        {:error, "File not found: #{display_path}. Use the write tool to create new files."}

      {:error, reason} ->
        {:error, "Could not read file for editing: #{display_path}. Reason: #{reason}"}
    end
  end

  defp apply_section(section, prepared) do
    case Hashline.apply_edits(prepared.before, prepared.diff) do
      {:ok, %{"text" => after_text} = apply_result} ->
        {:ok,
         Map.merge(prepared, %{
           after: after_text,
           first_changed_line: Map.get(apply_result, "first_changed_line"),
           warnings: Map.get(apply_result, "warnings", []),
           op: if(after_text == prepared.before, do: :noop, else: :update),
           section: section
         })}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp mismatch_message(store, canonical_path, path, expected_hash, actual_hash) do
    if Store.by_hash(store, canonical_path, expected_hash) do
      "Edit rejected for #{path}: file changed between read and edit. Section is bound to ##{expected_hash}, but the current file hashes to ##{actual_hash}. Re-read the file with `read` before retrying."
    else
      "Edit rejected for #{path}: hash ##{expected_hash} is not from this session. The current file hashes to ##{actual_hash}. Re-read the file with `read` to copy a current [path#tag] header."
    end
  end

  defp reject_duplicate_paths(prepared) do
    prepared
    |> Enum.reduce_while(MapSet.new(), fn entry, seen ->
      if MapSet.member?(seen, entry.canonical_path) do
        {:halt,
         {:error,
          "Multiple hashline sections resolve to the same file (#{entry.path}). Merge their ops under one header before applying."}}
      else
        {:cont, MapSet.put(seen, entry.canonical_path)}
      end
    end)
    |> case do
      %MapSet{} -> :ok
      error -> error
    end
  end

  defp commit_sections(prepared, opts) do
    store = Store.from_opts(opts)
    input_hash = prepared |> Enum.map(& &1.diff) |> Enum.join("\n") |> Store.hash_patch_input()

    Enum.reduce_while(prepared, {:ok, []}, fn entry, {:ok, acc} ->
      cond do
        entry.op == :noop ->
          noop = Store.record_noop(store, entry.canonical_path, input_hash)
          message = no_change_message(entry.path, noop.count)
          {:halt, {:error, message}}

        true ->
          persisted = entry.bom <> Hashline.restore_line_endings(entry.after, entry.line_ending)

          case File.write(entry.absolute_path, persisted) do
            :ok ->
              tag = Store.record_snapshot(store, entry.canonical_path, entry.after)
              Store.reset_noop(store, entry.canonical_path)

              result =
                Map.merge(entry, %{hash: tag, header: Hashline.format_header(entry.path, tag)})

              {:cont, {:ok, [result | acc]}}

            {:error, reason} ->
              {:halt, {:error, "Could not write file: #{entry.path}. Reason: #{reason}"}}
          end
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp no_change_message(path, count) when count >= 3 do
    "STOP. Edits to #{path} have been a byte-identical no-op #{count} times in a row. Re-read the file before issuing another edit."
  end

  defp no_change_message(path, _count) do
    "Edits to #{path} parsed and applied cleanly, but produced no change. Re-read the file before issuing another edit."
  end

  defp render_results(results) do
    text =
      results
      |> Enum.map_join("\n\n", fn result ->
        warning_block =
          case result.warnings do
            [] -> ""
            warnings -> "\n\nWarnings:\n" <> Enum.join(warnings, "\n")
          end

        result.header <> "\n" <> diff_preview(result.before, result.after) <> warning_block
      end)

    details = %{
      per_file_results:
        Enum.map(results, fn result ->
          %{
            path: result.path,
            first_changed_line: result.first_changed_line,
            op: result.op,
            hash: result.hash
          }
        end)
    }

    Result.text(text, details)
  end

  defp diff_preview(before, after_text) do
    before_lines = String.split(before, "\n")
    after_lines = String.split(after_text, "\n")
    max = max(length(before_lines), length(after_lines))

    0..(max - 1)
    |> Enum.flat_map(fn index ->
      before_line = Enum.at(before_lines, index)
      after_line = Enum.at(after_lines, index)

      cond do
        before_line == after_line -> []
        before_line == nil -> ["+#{after_line}"]
        after_line == nil -> ["-#{before_line}"]
        true -> ["-#{before_line}", "+#{after_line}"]
      end
    end)
    |> Enum.join("\n")
  end
end
