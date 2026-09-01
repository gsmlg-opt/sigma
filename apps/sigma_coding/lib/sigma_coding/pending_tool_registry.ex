defmodule Sigma.Coding.PendingToolRegistry do
  @moduledoc false

  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, %{}, Keyword.put(opts, :name, __MODULE__))

  def track(pid, metadata) when is_pid(pid) do
    GenServer.call(__MODULE__, {:track, pid, metadata})
  end

  def compatible?(metadata) do
    GenServer.call(__MODULE__, {:compatible, metadata})
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:track, pid, metadata}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, Map.put(state, ref, metadata)}
  end

  def handle_call({:compatible, metadata}, _from, state) do
    compatible? = Enum.all?(state, fn {_ref, pending} -> compatible_metadata?(metadata, pending) end)
    {:reply, compatible?, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, Map.delete(state, ref)}

  defp compatible_metadata?(%{concurrency: :shared} = candidate, %{concurrency: :shared} = pending) do
    MapSet.disjoint?(MapSet.new(candidate.resource_keys), MapSet.new(pending.resource_keys))
  end

  defp compatible_metadata?(_candidate, _pending), do: false
end
