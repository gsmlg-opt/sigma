defmodule Sigma.Tools.Write do
  @moduledoc false
  @behaviour Sigma.Coding.Tool

  alias Sigma.Coding.Utils.PathUtils
  alias Sigma.Tools.Result

  @impl true
  def name, do: "write"

  @impl true
  def description do
    "Create a new local file. Existing files must be changed with edit."
  end

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Path to the file to create"},
        "content" => %{"type" => "string", "description" => "Content to write to the file"}
      },
      "required" => ["path", "content"]
    }
  end

  @impl true
  def execute(_tool_call_id, params, opts) do
    path = Map.get(params, "path")
    content = Map.get(params, "content")
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    with {:ok, absolute_path} <- PathUtils.safe_resolve(path, cwd),
         :ok <- ensure_new_file(absolute_path),
         :ok <- File.mkdir_p(Path.dirname(absolute_path)),
         :ok <- write_file(absolute_path, content) do
      display_path = Path.relative_to(absolute_path, cwd)
      {:ok, Result.text("Created #{display_path}.", %{path: absolute_path})}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_new_file(path) do
    if File.exists?(path) do
      {:error, "File already exists: #{path}. Use the edit tool to modify existing files."}
    else
      :ok
    end
  end

  defp write_file(path, content) do
    case File.write(path, content) do
      :ok -> :ok
      {:error, reason} -> {:error, "Could not write file: #{path}. Reason: #{reason}"}
    end
  end
end
