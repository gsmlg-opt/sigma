defmodule Sigma.Agent.Backplane.ToolBackend do
  @moduledoc false

  alias Backplane.AgentRuntime.Error
  alias Sigma.Coding.{ToolError, ToolResult}

  def execute(%{backend_context: %{execute: execute}} = operation) when is_function(execute, 1) do
    operation |> execute.() |> normalize_result()
  end

  defp normalize_result({:error, %Error{class: :unknown_outcome}} = result), do: result

  defp normalize_result({:error, %ToolError{kind: :unknown_outcome} = error}) do
    {:error, Error.new(:unknown_outcome, error.message, details: Map.from_struct(error))}
  end

  defp normalize_result(result) do
    case ToolResult.normalize(result) do
      {:ok, result} ->
        {:ok, Map.from_struct(result)}

      {:error, error} ->
        # A returned tool failure belongs in the model's transcript. It is not
        # a runtime cancellation or proof that the requested action succeeded.
        {:ok,
         %{
           content: [%{type: :text, text: "Error (#{error.kind}): #{error.message}"}],
           is_error: true,
           details: %{error: Map.from_struct(error)}
         }}
    end
  end
end
