defmodule Sigma.Agent.Backplane.ChildStore do
  @moduledoc """
  Commits a child's runtime sidecar before projecting its canonical transcript.

  These are separate stores. A projection failure reports the acknowledged
  sidecar revision; it never claims to roll that commit back.
  """

  @behaviour Backplane.AgentRuntime.Store

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Store, as: RuntimeStore
  alias Sigma.Agent.Backplane.ChildIO
  alias Sigma.Agent.Backplane.Store, as: Sidecar

  @impl true
  defdelegate mode(), to: Sidecar
  @impl true
  defdelegate capabilities(), to: Sidecar
  @impl true
  defdelegate new(incarnation), to: Sidecar

  @impl true
  def load(%{store: store}, run_id, opts \\ []), do: Sidecar.load(store, run_id, opts)

  @impl true
  def store(context, record, meta) do
    with {:ok, %{stage: stage}} <- RuntimeStore.stage(__MODULE__, context, record, meta),
         {:ok, result} <- acknowledge_commit(context, stage, meta) do
      {:ok, Map.put(result, :outbox, stage.outbox)}
    end
  end

  @impl true
  def acknowledge_commit(%{store: store, io: io, key: key}, stage, meta) do
    with :ok <- ChildIO.validate(io, key),
         :ok <- matching_run(stage.run, key),
         {:ok, result} <- Sidecar.acknowledge_commit(store, stage, meta) do
      messages = get_in(stage, [:run, :context, :conversation, :messages]) || []

      case project(io, key, messages) do
        :ok -> {:ok, result}
        {:error, reason} -> projection_failure(stage, reason)
      end
    end
  catch
    :exit, reason ->
      {:error, Error.new(:execution_failure, "child store process unavailable", cause: reason)}
  end

  @impl true
  def fence(%{store: store}, run_id, revision, current, next),
    do: Sidecar.fence(store, run_id, revision, current, next)

  defp project(io, key, messages) do
    ChildIO.project(io, key, messages)
  catch
    :exit, reason -> {:error, {:child_io_unavailable, reason}}
  end

  defp matching_run(%{run_id: run_id, incarnation: incarnation}, {run_id, incarnation}), do: :ok

  defp matching_run(_run, _key),
    do: {:error, Error.new(:resource_conflict, "stale child runtime commit")}

  defp projection_failure(stage, reason) do
    {:error,
     Error.new(:execution_failure, "child transcript projection failed after runtime commit",
       details: %{
         kind: :child_transcript_projection_failed,
         runtime_committed: true,
         run_id: stage.run.run_id,
         revision: stage.revision
       },
       cause: reason
     )}
  end
end
