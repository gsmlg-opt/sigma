defmodule Sigma.Agent.Backplane.CollaborationBackend do
  @moduledoc false

  def execute(%{backend_context: %{host: host}} = operation) do
    with :ok <- Sigma.Agent.Subagents.origin(host, operation) do
      case Backplane.AgentRuntime.Codex.Backend.execute(operation) do
        {:error, %Backplane.AgentRuntime.Error{} = error} = result ->
          # Only an acknowledged pre-start receipt proves the host refused its
          # own child configuration before provider/tool dispatch. Started or
          # uncertain failures retain Runtime's uncertainty semantics.
          if Sigma.Agent.Subagents.rejected_before_start?(host, error),
            do: Backplane.AgentRuntime.ToolEffects.reject(operation, error),
            else: result

        result ->
          result
      end
    end
  end
end
