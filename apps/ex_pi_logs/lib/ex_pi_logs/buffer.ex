defmodule PiLogs.Buffer do
  use GenServer

  @cap 500

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, session_id, name: via(session_id))
  end

  def push(session_id, entry) do
    GenServer.cast(via(session_id), {:push, entry})
  end

  def all(session_id) do
    case GenServer.whereis(via(session_id)) do
      nil -> []
      pid -> GenServer.call(pid, :all)
    end
  end

  def search(session_id, opts \\ []) do
    all(session_id)
    |> filter_category(Keyword.get(opts, :category))
    |> filter_text(Keyword.get(opts, :text))
  end

  # Server

  @impl true
  def init(_session_id) do
    table = :ets.new(:pi_logs_buffer, [:ordered_set, :private])
    {:ok, %{table: table, count: 0}}
  end

  @impl true
  def handle_cast({:push, entry}, %{table: table, count: count} = state) do
    :ets.insert(table, {entry.id, entry})

    state =
      if count >= @cap do
        oldest_key = :ets.first(table)
        if oldest_key != :"$end_of_table", do: :ets.delete(table, oldest_key)
        %{state | count: @cap}
      else
        %{state | count: count + 1}
      end

    {:noreply, state}
  end

  @impl true
  def handle_call(:all, _from, %{table: table} = state) do
    entries =
      :ets.tab2list(table)
      |> Enum.sort_by(fn {id, _} -> id end, :desc)
      |> Enum.map(fn {_, entry} -> entry end)

    {:reply, entries, state}
  end

  defp via(session_id), do: {:via, Registry, {PiLogs.Registry, session_id}}

  defp filter_category(entries, nil), do: entries
  defp filter_category(entries, cat), do: Enum.filter(entries, &(&1.category == cat))

  defp filter_text(entries, nil), do: entries
  defp filter_text(entries, ""), do: entries

  defp filter_text(entries, text) do
    lower = String.downcase(text)

    Enum.filter(entries, fn entry ->
      entry.metadata
      |> inspect()
      |> String.downcase()
      |> String.contains?(lower)
    end)
  end
end
