defmodule Sigma.Tools.Store do
  @moduledoc """
  Session-scoped mutable state for first-party tools.

  The table is owned by the caller that creates it. In normal sessions that is
  `Sigma.Agent`, so state disappears with the agent process.
  """

  def new do
    :ets.new(__MODULE__, [:set, :public, read_concurrency: true, write_concurrency: true])
  end

  def from_opts(opts), do: Keyword.get(opts, :tool_state)

  @doc """
  Returns the session-scoped todo list state.

  Missing store yields an empty list with `next_id: 1` (not persisted).
  """
  def get_todo_state(nil), do: %{items: [], next_id: 1}

  def get_todo_state(store) do
    lookup(store, :todo_state, %{items: [], next_id: 1})
  end

  @doc """
  Replaces the session-scoped todo list state.

  Returns `:error` when no store is available.
  """
  def put_todo_state(nil, _state), do: :error

  def put_todo_state(store, %{items: items, next_id: next_id} = state)
      when is_list(items) and is_integer(next_id) and next_id >= 1 do
    :ets.insert(store, {:todo_state, state})
    :ok
  end

  defp lookup(store, key, default) do
    case :ets.lookup(store, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end
end
