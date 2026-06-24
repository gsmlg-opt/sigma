defmodule Sigma.Coding.PermissionPolicy do
  @moduledoc """
  A GenServer that manages permission rules for tool execution.
  """

  use GenServer

  @type action :: :allow | :deny | :ask

  @doc """
  Starts the permission policy GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc """
  Sets the default action to `:allow`.
  """
  def allow_all(pid \\ __MODULE__) do
    GenServer.call(pid, :allow_all)
  end

  @doc """
  Sets the default action to `:deny`.
  """
  def deny_all(pid \\ __MODULE__) do
    GenServer.call(pid, :deny_all)
  end

  @doc """
  Sets the default action to `:ask`.
  """
  def ask_all(pid \\ __MODULE__) do
    GenServer.call(pid, :ask_all)
  end

  @doc """
  Sets the rule for a specific tool to `:allow`.
  """
  def allow_tool(pid \\ __MODULE__, name) do
    GenServer.call(pid, {:set_rule, name, :allow})
  end

  @doc """
  Sets the rule for a specific tool to `:deny`.
  """
  def deny_tool(pid \\ __MODULE__, name) do
    GenServer.call(pid, {:set_rule, name, :deny})
  end

  @doc """
  Sets the rule for a specific tool to `:ask`.
  """
  def ask_tool(pid \\ __MODULE__, name) do
    GenServer.call(pid, {:set_rule, name, :ask})
  end

  @doc """
  Checks if a tool is allowed.
  """
  def check(pid \\ __MODULE__, name) do
    GenServer.call(pid, {:check, name})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    default = Keyword.get(opts, :default, :ask)
    rules = Keyword.get(opts, :rules, %{})
    {:ok, %{default: default, rules: rules}}
  end

  @impl true
  def handle_call(:allow_all, _from, state) do
    {:reply, :ok, %{state | default: :allow}}
  end

  @impl true
  def handle_call(:deny_all, _from, state) do
    {:reply, :ok, %{state | default: :deny}}
  end

  @impl true
  def handle_call(:ask_all, _from, state) do
    {:reply, :ok, %{state | default: :ask}}
  end

  @impl true
  def handle_call({:set_rule, name, action}, _from, state) do
    {:reply, :ok, put_in(state.rules[name], action)}
  end

  @impl true
  def handle_call({:check, name}, _from, state) do
    result = Map.get(state.rules, name, state.default)
    {:reply, result, state}
  end
end
