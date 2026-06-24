defmodule Sigma.Tools.Store do
  @moduledoc """
  Session-scoped mutable state for first-party tools.

  The table is owned by the caller that creates it. In normal sessions that is
  `Sigma.Agent`, so state disappears with the agent process.
  """

  alias Sigma.Tools.Hashline

  @max_versions_per_path 4
  @noop_hard_limit 3

  def new do
    :ets.new(__MODULE__, [:set, :public, read_concurrency: true, write_concurrency: true])
  end

  def from_opts(opts), do: Keyword.get(opts, :tool_state)

  def record_snapshot(store, path, text) do
    hash = Hashline.compute_file_hash(text)

    if store do
      key = {:snapshots, path}
      history = lookup(store, key, [])

      next_history =
        case Enum.find(history, &(&1.hash == hash)) do
          nil ->
            [%{path: path, text: text, hash: hash, recorded_at: System.system_time(:millisecond)} | history]
            |> Enum.take(@max_versions_per_path)

          existing ->
            existing = %{existing | recorded_at: System.system_time(:millisecond)}
            [existing | Enum.reject(history, &(&1.hash == hash))]
        end

      :ets.insert(store, {key, next_history})
    end

    hash
  end

  def by_hash(nil, _path, _hash), do: nil

  def by_hash(store, path, hash) do
    store
    |> lookup({:snapshots, path}, [])
    |> Enum.find(&(&1.hash == hash))
  end

  def record_noop(nil, _path, _input_hash), do: %{count: 1, escalate: false}

  def record_noop(store, path, input_hash) do
    key = {:noop, path}

    entry =
      case lookup(store, key, nil) do
        %{hash: ^input_hash, count: count} -> %{hash: input_hash, count: count + 1}
        _ -> %{hash: input_hash, count: 1}
      end

    :ets.insert(store, {key, entry})
    %{count: entry.count, escalate: entry.count >= @noop_hard_limit}
  end

  def reset_noop(nil, _path), do: :ok
  def reset_noop(store, path), do: :ets.delete(store, {:noop, path})

  def hash_patch_input(input) do
    :erlang.phash2(input, 4_294_967_296)
    |> Integer.to_string(16)
  end

  def canonical_path(absolute_path), do: Path.expand(absolute_path)

  defp lookup(store, key, default) do
    case :ets.lookup(store, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end
end
