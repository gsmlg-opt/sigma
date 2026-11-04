defmodule Sigma.Agent.Backplane.ChildArchiveEvidence do
  @moduledoc "Public export and restore of eligible, fully retired child executions."

  alias Backplane.AgentRuntime.Codex.MultiAgent
  alias Backplane.AgentRuntime.Error
  alias Sigma.Agent.Backplane.{ChildArchives, LifetimeEvidence, LifetimeRecovery}

  @eligible ~w(completed failed cancelled timed_out)

  def finalize(nil, _manager), do: :ok
  def finalize(_writer, nil), do: :ok

  def finalize(writer, manager) do
    with :ok <- LifetimeEvidence.finalize(writer, manager),
         {:ok, snapshot} <- MultiAgent.snapshot(manager) do
      snapshot.agents
      |> Enum.reject(& &1.archived)
      |> Enum.filter(&(&1.historical_outcome in @eligible))
      |> Enum.sort_by(&String.length(&1.name), :desc)
      |> Enum.reduce_while(:ok, fn child, :ok ->
        with {:ok, manifest} <- MultiAgent.recovery_manifest(manager, child.name),
             {:ok, receipt} <- LifetimeRecovery.receipt_for(writer, manifest["subject"]),
             {:ok, archive} <-
               MultiAgent.export_child(manager, child.name, receipt["receipt_id"]),
             :ok <- ChildArchives.put_archive(writer, archive) do
          {:cont, :ok}
        else
          error -> {:halt, error}
        end
      end)
    end
  end

  @doc "Seals unarchived children before manager shutdown; this is not a completed archive."
  def stage(nil, _manager), do: :ok
  def stage(_writer, nil), do: :ok

  def stage(writer, manager) do
    with :ok <- LifetimeEvidence.finalize(writer, manager),
         {:ok, snapshot} <- MultiAgent.snapshot(manager) do
      snapshot.agents
      |> Enum.reject(& &1.archived)
      |> Enum.filter(&(&1.historical_outcome in @eligible))
      |> Enum.sort_by(&String.length(&1.name), :desc)
      |> Enum.reduce_while(:ok, fn child, :ok ->
        with {:ok, manifest} <- MultiAgent.recovery_manifest(manager, child.name),
             :ok <- stage_child(writer, manager, child.name, manifest["subject"]["identity"]) do
          {:cont, :ok}
        else
          error -> {:halt, error}
        end
      end)
    end
  end

  defp stage_child(writer, manager, name, identity) do
    case ChildArchives.stage(writer, identity) do
      {:ok, _stage} ->
        :ok

      {:error, %Error{class: :not_found}} ->
        with {:ok, stage} <- MultiAgent.stage_child_export(manager, name),
             do: ChildArchives.put_stage(writer, stage)

      error ->
        error
    end
  end

  def restore(writer, manager, rows) do
    with :ok <- ChildArchives.complete_staged(writer, rows),
         {:ok, archives} <- ChildArchives.archives(writer, rows) do
      archives
      |> Enum.sort_by(fn {name, _} -> String.length(name) end)
      |> Enum.reduce_while({:ok, archives}, fn {_name, archive}, result ->
        case MultiAgent.restore_child(manager, archive) do
          {:ok, _} -> {:cont, result}
          error -> {:halt, error}
        end
      end)
    end
  end
end
