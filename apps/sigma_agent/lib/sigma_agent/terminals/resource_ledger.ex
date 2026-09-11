defmodule Sigma.Agent.Terminals.ResourceLedger do
  @moduledoc """
  Node-wide terminal capacity and cleanup-evidence ledger.

  The ledger serializes reservations but never starts or owns a shell. Occupied
  state is persisted across ledger-process crashes; recovery with any recorded
  occupancy is deliberately untrusted until an explicit reconciliation.
  """

  use GenServer

  alias Sigma.Agent.Terminals.{Error, Identity, Limits}

  defstruct entries: %{}, owners: %{}, trustworthy?: true, persistence_key: nil

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  def reserve_new(server \\ __MODULE__, %Identity.Run{} = run, operation_id, %Limits{} = limits) do
    GenServer.call(server, {:reserve_new, run, operation_id, limits})
  end

  def reserve_restart(
        server \\ __MODULE__,
        %Identity.Run{} = old_run,
        %Identity.Run{} = new_run,
        operation_id,
        %Limits{} = limits
      ) do
    GenServer.call(server, {:reserve_restart, old_run, new_run, operation_id, limits})
  end

  def mark_managed(server \\ __MODULE__, %Identity.Run{} = run),
    do: GenServer.call(server, {:mark, run, :managed})

  def mark_released(server \\ __MODULE__, %Identity.Run{} = run),
    do: GenServer.call(server, {:mark, run, :released})

  def mark_unconfirmed(server \\ __MODULE__, %Identity.Run{} = run),
    do: GenServer.call(server, {:mark, run, :unconfirmed})

  def observe_owner(server \\ __MODULE__, %Identity.Run{} = run, owner) when is_pid(owner),
    do: GenServer.call(server, {:observe_owner, run, owner})

  def remove(server \\ __MODULE__, %Identity.Run{} = run),
    do: GenServer.call(server, {:remove, run})

  def summary(server \\ __MODULE__, %Identity.Session{} = session),
    do: GenServer.call(server, {:summary, session})

  def summary_scope(server \\ __MODULE__, repository_id, session_id),
    do: GenServer.call(server, {:summary_scope, repository_id, session_id})

  def mark_untrustworthy(server \\ __MODULE__), do: GenServer.call(server, :mark_untrustworthy)
  def reconcile(server \\ __MODULE__, entries), do: GenServer.call(server, {:reconcile, entries})

  @impl true
  def init(opts) do
    persistence_key = Keyword.get(opts, :persistence_key, {__MODULE__, :state})

    state =
      case :persistent_term.get(persistence_key, :missing) do
        :missing ->
          %__MODULE__{persistence_key: persistence_key}

        %{entries: entries} ->
          %__MODULE__{
            entries: entries,
            trustworthy?: false,
            persistence_key: persistence_key
          }
      end

    {:ok, persist(state)}
  end

  @impl true
  def handle_call({:reserve_new, run, operation_id, limits}, _from, state) do
    cond do
      not state.trustworthy? ->
        {:reply, {:error, Error.new(:session_unavailable, %{reason: :ledger_untrusted})}, state}

      Map.has_key?(state.entries, run) ->
        {:reply, :ok, state}

      retained_count(state) >= limits.max_retained_records_per_node ->
        {:reply, {:error, Error.new(:capacity_exhausted, %{resource: :retained_records})}, state}

      managed_count(state) >= limits.max_managed_runs_per_node ->
        {:reply, {:error, Error.new(:capacity_exhausted, %{resource: :managed_runs})}, state}

      true ->
        entry = %{operation_id: operation_id, resource_state: :reserved, retained?: true}
        state = put_entry(state, run, entry)
        {:reply, :ok, state}
    end
  end

  def handle_call({:reserve_restart, old_run, new_run, operation_id, limits}, _from, state) do
    old_entry = state.entries[old_run]

    cond do
      not state.trustworthy? ->
        {:reply, {:error, Error.new(:session_unavailable, %{reason: :ledger_untrusted})}, state}

      old_entry == nil ->
        {:reply, {:error, Error.new(:terminal_not_found)}, state}

      old_entry.resource_state != :released ->
        {:reply,
         {:error, Error.new(:invalid_transition, %{resource_state: old_entry.resource_state})},
         state}

      managed_count(state) >= limits.max_managed_runs_per_node ->
        {:reply, {:error, Error.new(:capacity_exhausted, %{resource: :managed_runs})}, state}

      true ->
        new_entry = %{operation_id: operation_id, resource_state: :reserved, retained?: true}

        state = %{
          state
          | entries: state.entries |> Map.delete(old_run) |> Map.put(new_run, new_entry)
        }

        {:reply, :ok, persist(state)}
    end
  end

  def handle_call({:mark, run, resource_state}, _from, state)
      when resource_state in [:managed, :released, :unconfirmed] do
    case state.entries[run] do
      nil ->
        {:reply, {:error, Error.new(:terminal_not_found)}, state}

      entry ->
        state = put_entry(state, run, %{entry | resource_state: resource_state})
        state = if resource_state == :released, do: drop_owner(state, run), else: state
        {:reply, :ok, state}
    end
  end

  def handle_call({:observe_owner, run, owner}, _from, state) do
    case state.entries[run] do
      nil ->
        {:reply, {:error, Error.new(:terminal_not_found)}, state}

      _entry ->
        state = drop_owner(state, run)
        ref = Process.monitor(owner)
        {:reply, :ok, %{state | owners: Map.put(state.owners, ref, run)}}
    end
  end

  def handle_call({:remove, run}, _from, state) do
    case state.entries[run] do
      %{resource_state: :released} ->
        state =
          state
          |> drop_owner(run)
          |> then(&%{&1 | entries: Map.delete(&1.entries, run)})
          |> persist()

        {:reply, :ok, state}

      nil ->
        {:reply, {:error, Error.new(:terminal_not_found)}, state}

      %{resource_state: resource_state} ->
        {:reply, {:error, Error.new(:invalid_transition, %{resource_state: resource_state})},
         state}
    end
  end

  def handle_call({:summary, session}, _from, state) do
    entries = for {run, entry} <- state.entries, run.terminal.session == session, do: {run, entry}

    {:reply, summarize(entries, state.trustworthy?), state}
  end

  def handle_call({:summary_scope, repository_id, session_id}, _from, state) do
    entries =
      for {run, entry} <- state.entries,
          run.terminal.session.repository_id == repository_id,
          run.terminal.session.session_id == session_id,
          do: {run, entry}

    {:reply, summarize(entries, state.trustworthy?), state}
  end

  def handle_call(:mark_untrustworthy, _from, state) do
    state = %{state | trustworthy?: false} |> persist()
    {:reply, :ok, state}
  end

  def handle_call({:reconcile, entries}, _from, state) when is_map(entries) do
    Enum.each(Map.keys(state.owners), &Process.demonitor(&1, [:flush]))
    state = %{state | entries: entries, owners: %{}, trustworthy?: true} |> persist()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.owners, ref) do
      {nil, _owners} ->
        {:noreply, state}

      {run, owners} ->
        state = %{state | owners: owners}

        state =
          case state.entries[run] do
            nil -> state
            entry -> put_entry(state, run, %{entry | resource_state: :unconfirmed})
          end

        {:noreply, state}
    end
  end

  @impl true
  def terminate(reason, %{entries: entries, persistence_key: key})
      when reason in [:normal, :shutdown] and map_size(entries) == 0 do
    :persistent_term.erase(key)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp summarize(entries, trustworthy?) do
    %{
      trustworthy?: trustworthy?,
      retained_count: length(entries),
      managed_run_count:
        Enum.count(entries, fn {_run, entry} ->
          entry.resource_state in [:reserved, :managed, :unconfirmed]
        end),
      resource_pin?:
        Enum.any?(entries, fn {_run, entry} ->
          entry.resource_state in [:reserved, :managed, :unconfirmed]
        end),
      entries: entries
    }
  end

  defp managed_count(state) do
    Enum.count(state.entries, fn {_run, entry} ->
      entry.resource_state in [:reserved, :managed, :unconfirmed]
    end)
  end

  defp retained_count(state), do: Enum.count(state.entries, &elem(&1, 1).retained?)

  defp put_entry(state, run, entry) do
    %{state | entries: Map.put(state.entries, run, entry)} |> persist()
  end

  defp drop_owner(state, run) do
    case Enum.find(state.owners, fn {_ref, owner_run} -> owner_run == run end) do
      nil ->
        state

      {ref, _run} ->
        Process.demonitor(ref, [:flush])
        %{state | owners: Map.delete(state.owners, ref)}
    end
  end

  defp persist(%__MODULE__{persistence_key: key} = state) do
    :persistent_term.put(key, %{entries: state.entries})
    state
  end
end
