defmodule Sigma.Agent.Backplane.GoalIntegration do
  @moduledoc """
  Session-owner entry points for the durable native Goal host.

  Open with the actual Writer and ordinary Runtime Store before admitting a
  turn. Reopening reconciles terminal receipt outboxes before returning a ready
  handle. Bind only after the real Codex Session has issued the run binding.
  The resulting context is shared by Conversation and the native profile;
  public MultiAgent delegation owns descendant accounting.

  The Agent owns the host callbacks and their ordinary admission slot. Its
  reserve callback is effect-free; release submits that exact slot only after
  Goal's public idle call returns. A definitive cancellation or supersession
  must fence release before returning its no-submission acknowledgement.
  """

  alias Backplane.AgentRuntime.Error
  alias Sigma.Agent.Backplane.{GoalCoordinator, GoalUsage}

  def open(opts) do
    with {:ok, coordinator} <- GoalCoordinator.start_link(opts) do
      case ready_context(coordinator) do
        {:ok, context} ->
          {:ok, Map.put(context, :coordinator, coordinator)}

        {:error, _} = error ->
          close(%{coordinator: coordinator})
          error
      end
    end
  end

  def bind(handle, authority, opts) do
    with %{run_id: run, run_incarnation: incarnation} <- opts[:session_binding],
         true <- authority.run_id == run,
         {:ok, context} <-
           GoalCoordinator.bind(
             handle.coordinator,
             %{
               run_id: run,
               incarnation: incarnation,
               authority: authority,
               mode: Keyword.get(opts, :mode, :execution),
               usage_authoritative:
                 GoalUsage.capability(Keyword.get(opts, :provider)).usage_authoritative
             }
             |> with_admission(Keyword.get(opts, :admission))
           ) do
      {:ok, context}
    else
      {:error, _} = error ->
        error

      _ ->
        {:error, Error.new(:resource_conflict, "Goal requires the current Session run binding")}
    end
  end

  defp with_admission(attrs, nil), do: attrs
  defp with_admission(attrs, admission), do: Map.put(attrs, :admission, admission)

  def conversation_options(nil), do: []

  def conversation_options(context),
    do: context |> Map.take([:goal, :goal_binding, :thread_id]) |> Map.to_list()

  def native_context(context, nil), do: context

  def native_context(context, binding),
    do: Map.merge(context, Map.take(binding, [:goal, :goal_binding, :thread_id]))

  def get(handle), do: GoalCoordinator.get(handle.coordinator)

  def prepare_admission(handle), do: GoalCoordinator.prepare_admission(handle.coordinator)

  def set(handle, mutation, instruction) do
    with {:ok, %{status: :ready}} <- prepare_admission(handle),
         do: GoalCoordinator.set(handle.coordinator, mutation, instruction)
  end

  def clear(handle, instruction) do
    with {:ok, %{status: :ready}} <- prepare_admission(handle),
         do: GoalCoordinator.clear(handle.coordinator, instruction)
  end

  def idle(handle, generation), do: GoalCoordinator.idle(handle.coordinator, generation)

  def stop_host_executor(handle, admission, terminal),
    do: GoalCoordinator.stop_host_executor(handle.coordinator, admission, terminal)

  def open_host_hooks(handle, admission, runtime),
    do: GoalCoordinator.open_host_hooks(handle.coordinator, admission, runtime)

  def start_runtime(handle, admission),
    do: GoalCoordinator.start_runtime(handle.coordinator, admission)

  @doc "Runs pure preparation under the exact executor monitor before opening any effect boundary."
  def execute_admission(handle, admission, prepare, execute) do
    coordinator = handle.coordinator
    monitor = Process.monitor(coordinator)

    try do
      receive do
        {:goal_executor_release, ^coordinator, ^admission} ->
          case prepare.() do
            {:ok, _prepared} ->
              case GoalCoordinator.start_executor(coordinator, admission) do
                :ok -> execute.()
                {:error, error} -> {:goal_unstarted, error}
              end

            {:error, error} ->
              with :ok <-
                     GoalCoordinator.fail_executor(coordinator, admission, :preparation_failed),
                   do: {:goal_unstarted, error}

            {:not_submitted, reason} when reason in [:cancelled, :superseded] ->
              with :ok <- GoalCoordinator.fail_executor(coordinator, admission, reason),
                   do: {:goal_unstarted, Error.new(:cancelled, "Goal continuation #{reason}")}
          end

        {:DOWN, ^monitor, :process, ^coordinator, reason} ->
          {:error, Error.new(:execution_failure, "Goal executor owner exited", cause: reason)}
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  def recover_retired(handle), do: GoalCoordinator.recover_retired(handle.coordinator)

  def withdraw_admission(handle, admission, reason),
    do: GoalCoordinator.withdraw_admission(handle.coordinator, admission, reason)

  def unbind(handle, %{goal_binding: binding}),
    do: GoalCoordinator.unbind(handle.coordinator, binding)

  @doc "Copies Goal state to the new Writer's actual header without starting work."
  def fork(handle, target_writer, cwd, target_transcript) do
    with {:ok, %{status: :ready}} <- prepare_admission(handle),
         do: GoalCoordinator.fork(handle.coordinator, target_writer, cwd, target_transcript)
  end

  @doc "Retires the owner before moving, adopting or deleting the owning session files."
  def close(nil), do: :ok

  def close(%{coordinator: coordinator}) do
    if Process.alive?(coordinator), do: GenServer.stop(coordinator, :normal, 5_000), else: :ok
  catch
    :exit, reason ->
      {:error, Error.new(:execution_failure, "Goal owner retirement failed", cause: reason)}
  end

  defp ready_context(coordinator) do
    with {:ok, %{status: :ready}} <- GoalCoordinator.recover(coordinator),
         {:ok, context} <- GoalCoordinator.runtime_context(coordinator),
         do: {:ok, context}
  end
end
