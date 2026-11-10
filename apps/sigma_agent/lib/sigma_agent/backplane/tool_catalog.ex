defmodule Sigma.Agent.Backplane.ToolCatalog do
  @moduledoc false

  alias Backplane.AgentRuntime.Codex.Contract
  require Logger

  alias Backplane.AgentRuntime.{Error, InputSchema, ToolRegistry}
  alias Backplane.AgentRuntime.ToolCatalog, as: RuntimeCatalog
  alias Sigma.Coding.Tool

  def admit(tools, authority, execute, opts \\ []) do
    with {:ok, contracts} <- descriptors(Keyword.get(opts, :contracts, [])),
         {:ok, profiles} <- profile_descriptors(Keyword.get(opts, :profiles, []), authority),
         {:ok, hosted} <- profile_hosted_tools(Keyword.get(opts, :profiles, [])),
         {:ok, admitted} <-
           RuntimeCatalog.admit_batch(
             Enum.map(tools, &descriptor(&1, execute)) ++ contracts ++ profiles,
             authority: authority,
             run_id: authority.run_id,
             mode: Keyword.get(opts, :mode, :strict)
           ) do
      {:ok, Map.put(admitted, :hosted_tools, hosted)}
    end
  end

  defp profile_hosted_tools(profiles) do
    declarations = Enum.map(profiles, &Map.get(&1, :hosted_tools, []))
    valid_lists? = Enum.all?(declarations, &is_list/1)
    hosted = if valid_lists?, do: Enum.concat(declarations), else: []

    if valid_lists? and length(hosted) <= 1 and
         Enum.all?(hosted, &(is_map(&1) and (&1[:type] || &1["type"]) == "web_search")) do
      {:ok, hosted}
    else
      {:error, Error.new(:validation, "provider-hosted declarations are invalid or duplicated")}
    end
  end

  # Deferred candidates follow the eager catalog's `:quarantine` admission: a tool
  # whose schema Runtime cannot validate (e.g. a draft-07 `$schema`) is left out
  # of discovery instead of failing the turn. Every other contract error is fatal.
  def deferred_candidates(tools, execute) do
    Enum.reduce_while(tools, {:ok, []}, fn tool, {:ok, acc} ->
      attrs =
        tool
        |> descriptor(execute)
        |> Map.put(:name, Tool.name(tool))
        |> Map.put(:source, %{kind: :mcp, server: tool.server_id})

      with :ok <- quarantine_schema(attrs),
           {:ok, contract} <- Contract.new(attrs) do
        {:cont, {:ok, acc ++ [contract]}}
      else
        :quarantined -> {:cont, {:ok, acc}}
        error -> {:halt, error}
      end
    end)
  end

  defp quarantine_schema(%{name: name, schema: schema}) do
    case InputSchema.validate_schema(schema) do
      {:error, %Error{class: :unsupported_capability} = error} ->
        Logger.warning(
          "MCP tool #{name} is unavailable: #{error.message} #{inspect(error.details)}"
        )

        :quarantined

      _ ->
        :ok
    end
  end

  # Compose public Codex.profile/4 bundles without reconstructing contracts:
  # the registry descriptors carry session bindings and native input formats.
  defp profile_descriptors(profiles, authority) when is_list(profiles) do
    Enum.reduce_while(profiles, {:ok, []}, fn
      %{registry: %ToolRegistry{tools: tools}, authority: profile_authority}, {:ok, acc}
      when is_map(tools) and is_map(profile_authority) ->
        if Map.take(profile_authority, [:caller, :run_id]) ==
             Map.take(authority, [:caller, :run_id]) do
          descriptors = tools |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))
          {:cont, {:ok, acc ++ descriptors}}
        else
          {:halt,
           {:error, Error.new(:forbidden, "Codex profile belongs to another caller or run")}}
        end

      _, _ ->
        {:halt, {:error, Error.new(:validation, "Codex profile bundle is malformed")}}
    end)
  end

  defp profile_descriptors(_profiles, _authority),
    do: {:error, Error.new(:validation, "Codex profiles must be a list")}

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
