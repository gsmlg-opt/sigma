defmodule Sigma.Agent.Backplane.ToolBackend do
  @moduledoc false

  def execute(%{backend_context: %{execute: execute}} = operation) when is_function(execute, 1) do
    execute.(operation)
  end
end
