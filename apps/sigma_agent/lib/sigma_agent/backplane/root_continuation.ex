defmodule Sigma.Agent.Backplane.RootContinuation do
  @moduledoc "Explicit root continuation through the public durable Runtime decision."

  alias Backplane.AgentRuntime.Error

  alias Sigma.Agent.Backplane.{
    GoalCoordinator,
    GoalIntegration,
    GoalRuns,
    LifetimeEvidence,
    RunRecovery,
    RootRetirement,
    Store
  }

  def prepare(state, source_run_id) do
    with {:ok, scope} <- GoalCoordinator.identity(state.goal_integration.coordinator),
         {:ok, identities} <- GoalRuns.list(scope.root, scope.thread_id) do
      identity = Enum.find(identities, &(&1.run_id == source_run_id))

      case identity && Store.load(state.backplane_store, source_run_id) do
        {:ok, %{run: %{state: :unknown_outcome} = run}} ->
          if RunRecovery.missing_tool_result?(run, identity),
            do: continue(state, identity),
            else: {:ok, nil}

        {:error, _} = error ->
          error

        _ ->
          {:ok, nil}
      end
    end
  end

  defp continue(state, identity) do
    case LifetimeEvidence.read_continuation(state.transcript_path, identity) do
      {:ok, decision} ->
        case close_source_host(state, identity) do
          {:ok, facts} -> admit(state, identity, decision, facts)
          error -> error
        end

      {:error, %Error{class: :not_found}} ->
        prepare_new(state, identity)

      error ->
        error
    end
  end

  defp prepare_new(state, identity) do
    case close_source_host(state, identity) do
      {:ok, facts} ->
        case LifetimeEvidence.prepare_continuation(
               state.transcript_path,
               identity,
               "sigma-continue:" <> identity.run_id
             ) do
          {:ok, decision} -> admit(state, identity, decision, facts)
          {:error, error} -> {:error, error, facts}
        end

      {:error, error, facts} ->
        {:error, error, facts}

      {:error, _} = error ->
        error
    end
  end

  defp close_source_host(state, identity) do
    with {:ok, ledger} <- Store.host_retirement(state.backplane_store, :all) do
      host = ledger.hosts[state.host_retirement.identity.host_lifetime_id]

      binding =
        host &&
          Enum.find(Map.values(host.bindings), fn binding ->
            binding.run_id == identity.run_id and binding.run_incarnation == identity.incarnation
          end)

      if binding do
        case Store.host_retirement(state.backplane_store, binding) do
          {:ok, %{status: :confirmed} = confirmation} ->
            {:ok,
             %{
               native: {:ok, confirmation},
               async_hooks: {:ok, host.async_hooks},
               session_end: {:ok, host.session_end},
               result: {:ok, confirmation}
             }}

          {:ok, %{status: :unconfirmed}} ->
            facts =
              RootRetirement.close(state, state.host_retirement_facts, :shutdown,
                continuation: true
              )

            case facts.result do
              {:ok, %{status: :confirmed}} -> {:ok, facts}
              {:error, error} -> {:error, error, facts}
            end

          {:error, _} = error ->
            error
        end
      else
        {:ok, nil}
      end
    end
  end

  defp admit(state, identity, decision, facts) do
    target = decision["target"]["run_id"]

    result =
      with {:error, %Error{class: :not_found}} <- Store.load(state.backplane_store, target),
           :ok <-
             Sigma.Agent.Subagents.release_continued_generation(
               state.subagents,
               identity,
               decision
             ),
           {:ok, %{status: :ready}} <- GoalIntegration.recover_retired(state.goal_integration),
           {:ok, context} <- fresh_host(state, facts) do
        {:ok, decision, facts, context}
      else
        {:ok, _} ->
          {:already_admitted, decision}

        {:error, _} = error ->
          error
      end

    case result do
      {:error, error} -> {:error, error, facts}
      success -> success
    end
  end

  defp fresh_host(_state, nil), do: {:ok, nil}
  defp fresh_host(state, _facts), do: RootRetirement.context(state)
end
