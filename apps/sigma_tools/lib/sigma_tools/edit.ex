defmodule Sigma.Tools.Edit do
  @moduledoc false
  @behaviour Sigma.Coding.Tool

  alias Backplane.AgentRuntime.Codex.ApplyPatch
  alias Backplane.AgentRuntime.Error
  alias Sigma.Coding.ToolError
  alias Sigma.Tools.Result

  @impl true
  def name, do: "edit"

  @impl true
  def description do
    "Apply an apply_patch patch to add, update, delete, or move files in the working directory. Use *** Begin Patch and *** End Patch, file operation headers, and context hunks with space, - and + prefixes."
  end

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "input" => %{
          "type" => "string",
          "description" =>
            "apply_patch text enclosed by *** Begin Patch and *** End Patch. Use *** Add File: PATH with + lines, *** Delete File: PATH, or *** Update File: PATH with @@ context hunks. To rename while editing, put *** Move to: NEW_PATH after the update header."
        }
      },
      "required" => ["input"]
    }
  end

  @impl true
  def execute(_tool_call_id, params, opts) do
    input = Map.get(params, "input") || Map.get(params, "_input")
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    if is_binary(input) do
      case ApplyPatch.apply(cwd, input) do
        {:ok, %{files: files} = details} ->
          {:ok, Result.text("Applied patch:\n" <> summary(files, cwd), details)}

        {:error, %Error{} = error} ->
          applied = Map.get(error.details, :files, [])

          message =
            if applied == [],
              do: error.message,
              else: error.message <> "\nAlready applied changes:\n" <> summary(applied, cwd)

          uncertain = Map.get(error.details, :uncertain_files, [])

          message =
            if uncertain == [],
              do: message,
              else:
                message <>
                  "\nFiles with uncertain contents:\n" <>
                  Enum.map_join(uncertain, "\n", &Path.relative_to(&1, cwd))

          details = Map.put(error.details, :cause, error.cause)
          {:error, ToolError.new(error.class, message, details: details)}
      end
    else
      {:error, ToolError.new(:validation, "edit requires an input apply_patch patch.")}
    end
  end

  defp summary(files, cwd) do
    Enum.map_join(files, "\n", fn file ->
      marker =
        case file.action do
          :added -> "A"
          :deleted -> "D"
          :updated -> "M"
          :moved -> "R"
        end

      path = Path.relative_to(file.path, cwd)

      if file.action == :moved,
        do: "#{marker} #{Path.relative_to(file.from, cwd)} -> #{path}",
        else: "#{marker} #{path}"
    end)
  end
end
