defmodule Sigma.Coding.ExtensionRegistry do
  @moduledoc """
  Thin in-memory façade for BEAM-native extension tool registration.

  Phase 1 (ADR 0002): `register_tool/1` and `list_tools/0` only.
  Session defaults still come from `Sigma.Tools.default_tools/0`; this module
  does not replace the dispatcher or Tool Runtime V2 path.
  """

  use GenServer

  @type tool_module :: module()

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Registers a module that implements `Sigma.Coding.Tool`.

  On success returns `{:ok, tool_name}`. Duplicate names overwrite the previous
  module for that name (Phase 1 policy).
  """
  @spec register_tool(tool_module()) :: {:ok, String.t()} | {:error, term()}
  def register_tool(module) when is_atom(module) do
    with :ok <- ensure_tool_module(module),
         name when is_binary(name) and name != "" <- safe_name(module) do
      GenServer.call(__MODULE__, {:register, name, module})
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_tool}
    end
  end

  def register_tool(_), do: {:error, :invalid_tool}

  @doc """
  Returns registered tool modules in registration order (latest replace keeps position).
  """
  @spec list_tools() :: [tool_module()]
  def list_tools do
    GenServer.call(__MODULE__, :list)
  end

  @doc false
  @spec reset!() :: :ok
  def reset! do
    GenServer.call(__MODULE__, :reset)
  end

  @impl true
  def init(_), do: {:ok, %{order: [], by_name: %{}}}

  @impl true
  def handle_call({:register, name, module}, _from, state) do
    {order, by_name} =
      case Map.fetch(state.by_name, name) do
        {:ok, _old} ->
          {state.order, Map.put(state.by_name, name, module)}

        :error ->
          {state.order ++ [name], Map.put(state.by_name, name, module)}
      end

    {:reply, {:ok, name}, %{state | order: order, by_name: by_name}}
  end

  def handle_call(:list, _from, state) do
    tools = Enum.map(state.order, &Map.fetch!(state.by_name, &1))
    {:reply, tools, state}
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{order: [], by_name: %{}}}
  end

  defp ensure_tool_module(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        required = [
          {:name, 0},
          {:description, 0},
          {:schema, 0},
          {:execute, 3}
        ]

        if Enum.all?(required, fn {fun, arity} -> function_exported?(module, fun, arity) end) do
          :ok
        else
          {:error, :invalid_tool}
        end

      {:error, reason} ->
        {:error, {:not_loaded, reason}}
    end
  end

  defp safe_name(module) do
    try do
      module.name()
    rescue
      _ -> nil
    end
  end
end
