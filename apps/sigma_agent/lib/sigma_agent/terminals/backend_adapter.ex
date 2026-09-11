defmodule Sigma.Agent.Terminals.BackendAdapter do
  @moduledoc false

  defstruct [:module, :kind, :value, opts: []]

  def new(module, opts) do
    {:module, ^module} = Code.ensure_loaded(module)

    if function_exported?(module, :new, 1) do
      %__MODULE__{module: module, kind: :fixture, value: module.new(opts)}
    else
      %__MODULE__{module: module, kind: :process, opts: opts}
    end
  end

  def start(%{kind: :fixture} = adapter, run, attrs) do
    case adapter.module.start(adapter.value, run, attrs) do
      {:ok, value} -> {:ok, %{adapter | value: value}}
      {:pending, ref, value} -> {:pending, ref, %{adapter | value: value}}
      {:error, reason, value} -> {:error, reason, %{adapter | value: value}}
    end
  end

  def start(%{kind: :process} = adapter, _run, attrs) do
    opts =
      adapter.opts
      |> Keyword.merge(runtime_opts(attrs))
      |> Keyword.put(:owner, self())

    case adapter.module.start_link(opts) do
      {:ok, pid} -> {:pending, 1, %{adapter | value: pid}}
      {:error, reason} -> {:error, reason, adapter}
    end
  end

  def complete_start(%{kind: :fixture} = adapter, ref, resource) do
    case adapter.module.complete_start(adapter.value, ref, resource) do
      {:ok, value} -> {:ok, %{adapter | value: value}}
      {:error, reason} -> {:error, reason}
    end
  end

  def complete_start(%{kind: :process}, _ref, _resource), do: {:error, :unsupported}

  def input(%{kind: :fixture} = adapter, run, bytes),
    do: fixture_result(adapter, :input, [adapter.value, run, bytes])

  def input(%{kind: :process} = adapter, _run, bytes),
    do: process_result(adapter, :input, [adapter.value, bytes])

  def resize(%{kind: :fixture} = adapter, run, columns, rows, limits),
    do: fixture_result(adapter, :resize, [adapter.value, run, columns, rows, limits])

  def resize(%{kind: :process} = adapter, _run, columns, rows, _limits),
    do: process_result(adapter, :resize, [adapter.value, columns, rows])

  def checkpoint(%{kind: :process} = adapter, request_id),
    do: apply(adapter.module, :checkpoint, [adapter.value, request_id])

  def checkpoint(%{kind: :fixture}, _request_id), do: {:error, :unsupported}

  def device_response(%{kind: :fixture} = adapter, run, bytes),
    do: fixture_result(adapter, :device_response, [adapter.value, run, bytes])

  def device_response(%{kind: :process} = adapter, run, bytes), do: input(adapter, run, bytes)

  def cleanup(%{kind: :fixture} = adapter, run) do
    {result, value} = adapter.module.cleanup(adapter.value, run)
    {result, %{adapter | value: value}}
  end

  def cleanup(%{kind: :process} = adapter, _run) do
    {adapter.module.close(adapter.value), adapter}
  end

  def events(%{kind: :fixture} = adapter), do: adapter.module.events(adapter.value)
  def events(%{kind: :process}), do: []

  def process?(%{kind: :process}), do: true
  def process?(_adapter), do: false

  def process_pid(%{kind: :process, value: pid}), do: pid

  defp fixture_result(adapter, function, args) do
    case apply(adapter.module, function, args) do
      {:ok, value} -> {:ok, %{adapter | value: value}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp process_result(adapter, function, args) do
    case apply(adapter.module, function, args) do
      :ok -> {:ok, adapter}
      {:error, reason} -> {:error, reason}
    end
  end

  defp runtime_opts(attrs) when is_map(attrs) do
    [:cwd, :columns, :rows, :command, :shell, :helper_path]
    |> Enum.flat_map(fn key ->
      case Map.fetch(attrs, key) do
        {:ok, value} -> [{key, value}]
        :error -> []
      end
    end)
  end
end
