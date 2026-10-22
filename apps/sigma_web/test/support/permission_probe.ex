defmodule Sigma.Web.PermissionProbe do
  @moduledoc false
  @behaviour Sigma.Coding.Tool

  def name, do: "permission_probe"
  def description, do: "Test-only side effect for approval and child isolation coverage"

  def schema do
    %{
      "type" => "object",
      "properties" => %{"path" => %{"type" => "string"}},
      "required" => ["path"]
    }
  end

  def metadata do
    %{
      effect: :write,
      concurrency: :sequential,
      interruptible: true,
      default_deadline_ms: 30_000,
      approval_tier: :guarded
    }
  end

  def execute(_id, arguments, opts) do
    path = Path.expand(arguments["path"], Keyword.fetch!(opts, :cwd))

    with :ok <- File.write(path, "permitted") do
      {:ok, %{content: [%{type: :text, text: "permitted"}]}}
    end
  end
end
