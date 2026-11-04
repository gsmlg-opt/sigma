defmodule Sigma.Agent.Backplane.ChildArchives do
  @moduledoc """
  Exact public child archives stored by the transcript's lifetime evidence writer.

  An archive is immutable for its original child admission. Restoring a roster
  selects only the archive for that row's exact public run, so an earlier success
  cannot replace a later failed or unfinished run. No history is reconstructed.
  """

  alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence
  alias Backplane.AgentRuntime.Codex.MultiAgent
  alias Backplane.AgentRuntime.Error
  alias Sigma.Agent.Backplane.LifetimeRecovery

  def put_archive(writer, %{"child_identity" => identity} = archive) when is_map(identity),
    do: LifetimeRecovery.put_evidence(writer, reference(identity), archive)

  def put_stage(writer, %{"child_identity" => identity} = stage) when is_map(identity),
    do: LifetimeRecovery.put_evidence(writer, stage_reference(identity), stage)

  def stage(writer, identity),
    do: LifetimeRecovery.load_evidence(writer, stage_reference(identity))

  @doc "Completes only selected durable stages after actual Goal ACK and receipt refresh."
  def complete_staged(nil, _rows), do: :ok

  def complete_staged(writer, rows) do
    with {:ok, admissions} <- LifetimeRecovery.stored_children(writer) do
      Enum.reduce_while(admissions, :ok, fn admission, :ok ->
        case complete_selected_stage(writer, admission["child_identity"], rows) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp complete_selected_stage(writer, identity, rows) do
    case stage(writer, identity) do
      {:ok, stage} ->
        if selected?(stage, rows), do: complete_archive(writer, identity, stage), else: :ok

      {:error, %Error{class: :not_found}} ->
        :ok

      error ->
        error
    end
  end

  defp complete_archive(writer, identity, stage) do
    case LifetimeRecovery.load_evidence(writer, reference(identity)) do
      {:ok, _archive} ->
        :ok

      {:error, %Error{class: :not_found}} ->
        with {:ok, receipt} <- LifetimeRecovery.receipt_for(writer, stage["manifest"]["subject"]),
             {:ok, archive} <-
               MultiAgent.complete_child_export(
                 LifetimeRecovery.configuration(writer),
                 stage_reference(identity),
                 receipt["receipt_id"]
               ) do
          put_archive(writer, archive)
        end

      error ->
        error
    end
  end

  def archives(nil, _rows), do: {:ok, %{}}

  def archives(writer, rows) do
    with {:ok, admissions} <- LifetimeRecovery.stored_children(writer) do
      Enum.reduce_while(admissions, {:ok, %{}}, fn admission, {:ok, archives} ->
        case LifetimeRecovery.load_evidence(writer, reference(admission["child_identity"])) do
          {:ok, archive} ->
            if selected?(archive, rows) do
              name = archive["child_identity"]["name"]

              case Map.fetch(archives, name) do
                :error -> {:cont, {:ok, Map.put(archives, name, archive)}}
                {:ok, ^archive} -> {:cont, {:ok, archives}}
                {:ok, _} -> {:halt, failure("multiple archives identify the selected child run")}
              end
            else
              {:cont, {:ok, archives}}
            end

          {:error, %Error{class: :not_found}} ->
            {:cont, {:ok, archives}}

          error ->
            {:halt, error}
        end
      end)
    end
  end

  defp selected?(archive, rows) do
    original = get_in(archive, ["host_metadata", "sigma_identity"])

    is_map(original) and is_binary(original["agent_id"]) and
      is_binary(original["public_run_id"]) and
      Enum.any?(rows, fn row ->
        row.agent_id == original["agent_id"] and row.run_id == original["public_run_id"]
      end)
  end

  defp reference(identity), do: "child-archive:" <> Evidence.digest(identity)
  defp stage_reference(identity), do: "child-export-stage:" <> Evidence.digest(identity)
  defp failure(message), do: {:error, Error.new(:unknown_outcome, message)}
end
