defmodule Sigma.Agent.Backplane.ToolCatalog do
  @moduledoc false

  alias Backplane.AgentRuntime.Codex.Contract
  alias Backplane.AgentRuntime.ToolCatalog, as: RuntimeCatalog
  alias Sigma.Coding.Tool

  def admit(tools, authority, execute, opts \\ []) do
    with {:ok, contracts} <- descriptors(Keyword.get(opts, :contracts, [])) do
      RuntimeCatalog.admit_batch(
        Enum.map(tools, &descriptor(&1, execute)) ++ contracts,
        authority: authority,
        run_id: authority.run_id,
        mode: Keyword.get(opts, :mode, :strict)
      )
    end
  end

  defp descriptors(contracts) do
    Enum.reduce_while(contracts, {:ok, []}, fn contract, {:ok, acc} ->
      case Contract.new(contract) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [Contract.descriptor(normalized)]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp descriptor(tool, execute) do
    metadata = Tool.metadata(tool, %{arguments: %{}, id: "schema", name: Tool.name(tool)}, [])

    %{
      tool_name: Tool.name(tool),
      tool_revision: 1,
      description: Tool.description(tool),
      backend: Sigma.Agent.Backplane.ToolBackend,
      backend_context: %{execute: execute},
      schema: Tool.schema(tool),
      safety: %{
        read_only: metadata.effect == :read,
        retry_safe: metadata.effect == :read,
        parallel_safe: metadata.concurrency == :shared,
        requires_approval: false
      }
    }
  end
end
