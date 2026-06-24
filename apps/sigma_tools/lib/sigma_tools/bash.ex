defmodule Sigma.Tools.Bash do
  @moduledoc false
  @behaviour Sigma.Coding.Tool

  @impl true
  def name, do: "bash"

  @impl true
  def description, do: Sigma.Coding.Tools.Bash.description()

  @impl true
  def schema, do: Sigma.Coding.Tools.Bash.schema()

  @impl true
  def execute(tool_call_id, params, opts), do: Sigma.Coding.Tools.Bash.execute(tool_call_id, params, opts)
end
