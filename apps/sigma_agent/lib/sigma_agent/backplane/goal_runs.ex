defmodule Sigma.Agent.Backplane.GoalRuns do
  @moduledoc """
  Durable pre-admission index for one thread's Goal-bound run identities.

  The unique Goal coordinator serializes writes. This index records trusted
  identities before Conversation admission, never live bindings or authority.
  The supplied root must already be opened by GoalStore. File-data sync and
  atomic rename have the same boundary as the runtime Store; no directory sync
  or cross-node writer exclusion is claimed.

  A missing runtime snapshot for an indexed identity is ambiguous after a
  crash. It does not prove that execution never started.
  """

  alias Backplane.AgentRuntime.Error
  alias Sigma.Agent.Backplane.Store.FileSystem

  @keys ~w(thread_id run_id incarnation mode goal_id usage_authoritative)a

  def list(root, thread_id, opts \\ []) do
    with :ok <- identity(root, thread_id),
         {:ok, index} <- read(root, thread_id, opts),
         do: {:ok, index.runs |> Map.values() |> Enum.sort_by(&{&1.run_id, &1.incarnation})}
  end

  def record(root, thread_id, binding, opts \\ []) do
    with :ok <- identity(root, thread_id),
         :ok <- validate_binding(binding, thread_id),
         {:ok, index} <- read(root, thread_id, opts) do
      key = {binding.run_id, binding.incarnation}

      case Map.get(index.runs, key) do
        ^binding -> :ok
        nil -> write(root, thread_id, %{index | runs: Map.put(index.runs, key, binding)}, opts)
        _ -> error(:resource_conflict, "goal run identity conflicts with its durable index")
      end
    end
  end

  @doc """
  Removes one indexed identity. Only `GoalRecovery.discard_unrecorded/2` calls
  this, after the user explicitly accepts that the run's outcome is unknown.
  """
  def discard(root, thread_id, {run_id, incarnation} = key, opts \\ [])
      when is_binary(run_id) and is_integer(incarnation) do
    with :ok <- identity(root, thread_id),
         {:ok, index} <- read(root, thread_id, opts) do
      if Map.has_key?(index.runs, key),
        do: write(root, thread_id, %{index | runs: Map.delete(index.runs, key)}, opts),
        else: error(:not_found, "goal run identity is not indexed")
    end
  end

  defp read(root, thread_id, opts) do
    case fs(opts, :read, [path(root, thread_id)]) do
      {:ok, bytes} -> decode(bytes, thread_id)
      {:error, :enoent} -> {:ok, %{version: 1, thread_id: thread_id, runs: %{}}}
      {:error, reason} -> storage_error("goal run index read failed", reason)
    end
  end

  defp decode(bytes, thread_id) do
    case :erlang.binary_to_term(bytes, [:safe]) do
      %{version: 1, thread_id: ^thread_id, runs: runs} = index when is_map(runs) ->
        if Enum.sort(Map.keys(index)) == [:runs, :thread_id, :version] and
             Enum.all?(runs, fn
               {{run, incarnation}, %{run_id: run, incarnation: incarnation} = binding} ->
                 validate_binding(binding, thread_id) == :ok

               _ ->
                 false
             end),
           do: {:ok, index},
           else: error(:malformed_result, "malformed goal run index")

      _ ->
        error(:malformed_result, "malformed goal run index")
    end
  rescue
    ArgumentError -> error(:malformed_result, "malformed goal run index")
  end

  defp write(root, thread_id, index, opts) do
    case fs(opts, :write_atomic, [
           path(root, thread_id),
           :erlang.term_to_binary(index, compressed: 6)
         ]) do
      :ok -> :ok
      {:error, reason} -> storage_error("goal run index commit failed", reason)
    end
  end

  defp validate_binding(
         %{
           thread_id: thread_id,
           run_id: run,
           incarnation: incarnation,
           mode: mode,
           goal_id: goal_id,
           usage_authoritative: authoritative
         } = binding,
         thread_id
       ) do
    if Enum.sort(Map.keys(binding)) == Enum.sort(@keys) and is_binary(run) and run != "" and
         is_integer(incarnation) and incarnation >= 0 and mode in [:execution, :plan] and
         (is_nil(goal_id) or (is_binary(goal_id) and goal_id != "")) and
         is_boolean(authoritative),
       do: :ok,
       else: error(:validation, "invalid goal run identity")
  end

  defp validate_binding(_binding, _thread_id), do: error(:validation, "invalid goal run identity")

  defp identity(root, thread_id)
       when is_binary(root) and is_binary(thread_id) and thread_id != "" do
    if Path.type(root) == :absolute,
      do: :ok,
      else: error(:validation, "goal run root must be absolute")
  end

  defp identity(_root, _thread_id),
    do: error(:validation, "goal run root and thread are required")

  defp path(root, thread_id) do
    name = :crypto.hash(:sha256, thread_id) |> Base.url_encode64(padding: false)
    Path.join(root, name <> ".goal-runs")
  end

  defp fs(opts, function, args) do
    {module, context} = Keyword.get(opts, :filesystem, {FileSystem, nil})
    apply(module, function, [context | args])
  end

  defp error(class, message), do: {:error, Error.new(class, message)}

  defp storage_error(message, reason),
    do: {:error, Error.new(:execution_failure, message, cause: reason)}
end
