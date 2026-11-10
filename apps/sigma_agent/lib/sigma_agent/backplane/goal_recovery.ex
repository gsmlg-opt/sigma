defmodule Sigma.Agent.Backplane.GoalRecovery do
  @moduledoc """
  Offline, user-confirmed recovery for a session whose Goal index names runs
  the Runtime Store never recorded.

  A Goal binding is indexed before Runtime admission, so a turn that fails in
  between (or a crash) leaves an index entry without a run snapshot. Ordinary
  recovery keeps that as `recovery_required` because a missing snapshot does not
  prove execution never started (see `GoalRuns`), and the Agent cannot start.

  This module never decides that on its own. It lists such entries for a
  stopped session and removes exactly the entries the user chose to discard,
  re-checking that the Runtime Store still has no record of each run. Effects
  of a run that did execute, if any, remain and are not reconciled.
  """

  alias Backplane.AgentRuntime.Error
  alias Sigma.Agent.Backplane.{GoalRuns, Store}

  @doc "Indexed Goal runs of a stopped session that have no Runtime snapshot."
  def unrecorded_runs(transcript_path) do
    with {:ok, thread_id} <- thread_id(transcript_path),
         {:ok, runs} <- GoalRuns.list(goal_root(transcript_path), thread_id) do
      with_store(transcript_path, fn store ->
        {:ok, Enum.filter(runs, &unrecorded?(store, &1))}
      end)
    end
  end

  @doc "Removes the chosen unrecorded runs from the Goal index; returns the removed ids."
  def discard_unrecorded(transcript_path, run_ids) when is_list(run_ids) do
    with {:ok, thread_id} <- thread_id(transcript_path),
         {:ok, runs} <- GoalRuns.list(goal_root(transcript_path), thread_id) do
      chosen = Enum.filter(runs, &(&1.run_id in run_ids))

      with_store(transcript_path, fn store ->
        Enum.reduce_while(chosen, {:ok, []}, fn run, {:ok, removed} ->
          if unrecorded?(store, run) do
            case GoalRuns.discard(
                   goal_root(transcript_path),
                   thread_id,
                   {run.run_id, run.incarnation}
                 ) do
              :ok -> {:cont, {:ok, removed ++ [run.run_id]}}
              error -> {:halt, error}
            end
          else
            {:halt,
             {:error, Error.new(:resource_conflict, "run #{run.run_id} has a Runtime record")}}
          end
        end)
      end)
    end
  end

  defp unrecorded?(store, run),
    do: match?({:error, %Error{class: :not_found}}, Store.load(store, run.run_id))

  defp with_store(transcript_path, fun) do
    case Store.open(path: transcript_path <> ".runtime") do
      {:ok, store} ->
        try do
          fun.(store)
        after
          Store.retire(store)
        end

      {:error, _} = error ->
        error
    end
  end

  defp goal_root(transcript_path), do: Path.join(transcript_path <> ".subagents", "goal")

  # The Goal thread is the transcript's durable session header id.
  defp thread_id(transcript_path) do
    with {:ok, file} <- File.open(transcript_path, [:read, :utf8]),
         line when is_binary(line) <- IO.read(file, :line),
         :ok <- File.close(file),
         {:ok, %{"type" => "session", "id" => id}} when is_binary(id) and id != "" <-
           Jason.decode(line) do
      {:ok, id}
    else
      _ -> {:error, Error.new(:not_found, "session header is unavailable")}
    end
  end
end
