defmodule Sigma.Web.SamgitaHost.Commands do
  @moduledoc """
  Bounded in-memory `command_id` idempotency table (FIFO eviction).

  `reserve/2` claims an id for a fingerprint (`{method, params}`); a repeat with
  the same fingerprint returns the stored result once `complete/2` ran.
  """
  use GenServer

  @max 1024

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.get(opts, :max, @max), name: name)
  end

  @spec reserve(GenServer.server(), String.t(), term()) :: :new | {:done, term()} | :conflict
  def reserve(server \\ __MODULE__, command_id, fingerprint),
    do: GenServer.call(server, {:reserve, command_id, fingerprint})

  @spec complete(GenServer.server(), String.t(), term()) :: :ok
  def complete(server \\ __MODULE__, command_id, result),
    do: GenServer.call(server, {:complete, command_id, result})

  @spec release(GenServer.server(), String.t()) :: :ok
  def release(server \\ __MODULE__, command_id),
    do: GenServer.call(server, {:release, command_id})

  @impl true
  def init(max), do: {:ok, %{max: max, entries: %{}, order: :queue.new()}}

  @impl true
  def handle_call({:reserve, id, fingerprint}, _from, state) do
    case state.entries do
      %{^id => {^fingerprint, {:done, result}}} -> {:reply, {:done, result}, state}
      %{^id => _} -> {:reply, :conflict, state}
      _ -> {:reply, :new, insert(state, id, fingerprint)}
    end
  end

  def handle_call({:complete, id, result}, _from, state) do
    entries =
      case state.entries do
        %{^id => {fingerprint, _}} = entries ->
          %{entries | id => {fingerprint, {:done, result}}}

        entries ->
          entries
      end

    {:reply, :ok, %{state | entries: entries}}
  end

  def handle_call({:release, id}, _from, state) do
    {:reply, :ok,
     %{
       state
       | entries: Map.delete(state.entries, id),
         order: :queue.filter(&(&1 != id), state.order)
     }}
  end

  defp insert(state, id, fingerprint) do
    state = %{
      state
      | entries: Map.put(state.entries, id, {fingerprint, :pending}),
        order: :queue.in(id, state.order)
    }

    if map_size(state.entries) > state.max do
      {{:value, oldest}, order} = :queue.out(state.order)
      %{state | entries: Map.delete(state.entries, oldest), order: order}
    else
      state
    end
  end
end
