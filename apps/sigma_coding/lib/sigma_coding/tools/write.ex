defmodule Sigma.Coding.Tools.Write do
  @moduledoc """
  Tool for creating new files.
  """
  @behaviour Sigma.Coding.Tool

  alias Sigma.Coding.Utils.PathUtils

  @impl true
  def name, do: "write"

  @impl true
  def description do
    "Create a new file with the given content. Fails if the file already exists — use the edit tool to modify existing files. Parent directories are created automatically."
  end

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "Path to the file to create (relative or absolute)"
        },
        "content" => %{
          "type" => "string",
          "description" => "Content to write to the file"
        }
      },
      "required" => ["path", "content"]
    }
  end

  @impl true
  def execute(_tool_call_id, params, opts) do
    path = Map.get(params, "path")
    content = Map.get(params, "content")
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    case PathUtils.safe_resolve(path, cwd) do
      {:ok, absolute_path} ->
        if File.exists?(absolute_path) do
          {:error,
           "File already exists: #{absolute_path}. Use the edit tool to modify existing files."}
        else
          absolute_path
          |> Path.dirname()
          |> File.mkdir_p!()

          case File.write(absolute_path, content) do
            :ok ->
              {:ok,
               %{
                 content: [%{type: :text, text: "Created #{absolute_path}.", text_signature: nil}],
                 details: %{path: absolute_path}
               }}

            {:error, reason} ->
              {:error, "Could not write file: #{absolute_path}. Reason: #{reason}"}
          end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
