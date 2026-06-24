defmodule Sigma.Coding.Tools.Edit do
  @moduledoc """
  Tool for editing file contents.
  """
  @behaviour Sigma.Coding.Tool

  alias Sigma.Coding.Utils.PathUtils

  @impl true
  def name, do: "edit"

  @impl true
  def description do
    "Edit a file. If old_content is provided, replaces it with content. Otherwise, overwrites the file."
  end

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "Path to the file to edit (relative or absolute)"
        },
        "content" => %{
          "type" => "string",
          "description" => "The new content to write or the replacement text."
        },
        "old_content" => %{
          "type" => "string",
          "description" => "Optional: The exact text to replace. If not provided, the entire file is overwritten."
        }
      },
      "required" => ["path", "content"]
    }
  end

  @impl true
  def execute(_tool_call_id, params, opts) do
    path = Map.get(params, "path")
    content = Map.get(params, "content")
    old_content = Map.get(params, "old_content")
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    case PathUtils.safe_resolve(path, cwd) do
      {:ok, absolute_path} ->
        do_edit(absolute_path, content, old_content)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_edit(path, content, nil) do
    case File.write(path, content) do
      :ok ->
        {:ok,
         %{
           content: [%{type: :text, text: "Successfully overwrote #{path}.", text_signature: nil}],
           details: %{path: path, mode: :overwrite}
         }}

      {:error, reason} ->
        {:error, "Could not write to file: #{path}. Reason: #{reason}"}
    end
  end

  defp do_edit(path, new_content, old_content) do
    case File.read(path) do
      {:ok, current_content} ->
        case count_occurrences(current_content, old_content) do
          0 ->
            {:error, "The provided old_content was not found in the file."}

          1 ->
            updated_content = String.replace(current_content, old_content, new_content)

            case File.write(path, updated_content) do
              :ok ->
                {:ok,
                 %{
                   content: [
                     %{type: :text, text: "Successfully replaced content in #{path}.", text_signature: nil}
                   ],
                   details: %{path: path, mode: :replace}
                 }}

              {:error, reason} ->
                {:error, "Could not write to file: #{path}. Reason: #{reason}"}
            end

          n ->
            {:error,
             "The provided old_content matches #{n} locations in the file. Please provide more context to uniquely identify the block to replace."}
        end

      {:error, reason} ->
        {:error, "Could not read file for editing: #{path}. Reason: #{reason}"}
    end
  end

  defp count_occurrences(string, ""), do: String.length(string) + 1

  defp count_occurrences(string, substring) do
    string
    |> String.split(substring)
    |> length()
    |> Kernel.-(1)
  end
end
