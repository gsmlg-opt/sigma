defmodule PiTools.Bash do
  @moduledoc false
  @behaviour PiCoding.Tool

  @impl true
  def name, do: "bash"

  @impl true
  def description, do: PiCoding.Tools.Bash.description()

  @impl true
  def schema, do: PiCoding.Tools.Bash.schema()

  @impl true
  def execute(tool_call_id, params, opts), do: PiCoding.Tools.Bash.execute(tool_call_id, params, opts)
end
