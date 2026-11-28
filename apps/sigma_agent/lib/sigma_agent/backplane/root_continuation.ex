defmodule Sigma.Agent.Backplane.RootContinuation do
  @moduledoc "Root continuation through the public durable Runtime decision."

  alias Backplane.AgentRuntime.Error
  alias Sigma.Agent.Incidents

  alias Sigma.Agent.Backplane.{
    GoalCoordinator,
    GoalIntegration,
    GoalRuns,
    LifetimeEvidence,
    RunRecovery,
    RootRetirement,
    Store
  }

  def prepare(state, source_run_id, on_started \\ fn _ -> :ok end) do
    with {:ok, scope} <- GoalCoordinator.identity(state.goal_integration.coordinator),
         {:ok, identities} <- GoalRuns.list(scope.root, scope.thread_id) do
      identity = Enum.find(identities, &(&1.run_id == source_run_id))

      case identity && Store.load(state.backplane_store, source_run_id) do
        {:ok, %{run: run} = snapshot} ->
          if RunRecovery.missing_tool_result?(run, identity) or
               RunRecovery.interrupted_tool_intent?(run, identity) do
            record_started(state, identity, run)
            on_started.(%{source_run_id: source_run_id})

            with {:ok, _} <- prepare_source(state, identity, snapshot),
                 do: continue(state, identity)
          else
            {:ok, nil}
          end

        {:error, _} = error ->
          error

        _ ->
          {:ok, nil}
      end
    end
  end

  defp prepare_source(_state, _identity, %{run: %{state: :unknown_outcome}} = snapshot),
    do: {:ok, snapshot}

  defp prepare_source(state, identity, snapshot) do
    with {:ok, ledger} <- Store.host_retirement(state.backplane_store, :all) do
      host = ledger.hosts[state.host_retirement.identity.host_lifetime_id]

      current_host? =
        host &&
          Enum.any?(host.bindings, fn {_key, binding} ->
            binding.run_id == identity.run_id and binding.run_incarnation == identity.incarnation
          end)

      with :ok <- prepare_source_host(state, identity, current_host?),
           do:
             RunRecovery.prepare_root_continuation(
               state.backplane_store,
               identity,
               snapshot,
               state.transcript_path
             )
    end
  end

  defp prepare_source_host(state, identity, current_host?) when current_host? in [false, nil],
    do: RunRecovery.confirm_root_components(state.backplane_store, identity)

  defp prepare_source_host(state, _identity, true) do
    with {:ok, sources} <- Sigma.Agent.Subagents.archive_sources(state.subagents),
         true <-
           sources.root.host_lifetime_id == state.host_retirement.identity.host_lifetime_id do
      :ok
    else
      {:error, _} = error ->
        error

      _ ->
        {:error,
         Error.new(:resource_conflict, "continuation requires the original live root host")}
    end
  end

  defp record_started(state, identity, run) do
    references =
      for {_, %{type: :tool, status: status, operation: operation}} <- run.execution_intents,
          status in [:started, :uncertain],
          operation.run_id == identity.run_id,
          operation.incarnation == identity.incarnation,
          not Map.has_key?(run.tool_results, operation.invocation_id) do
        Map.take(operation, [:run_id, :invocation_id, :tool_call_id])
      end

    Incidents.record(state.incident_context, %{
      kind: :recovery_started,
      stage: :root_continuation,
      recovery_state: :preparing,
      run_id: identity.run_id,
      source_run_id: identity.run_id,
      incarnation: identity.incarnation,
      evidence_refs: references
    })
  end

  defp continue(state, identity) do
    case LifetimeEvidence.read_continuation(state.transcript_path, identity) do
      {:ok, decision} ->
        case close_source_host(state, identity, true) do
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

  defp close_source_host(state, identity, captured? \\ false) do
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
            capture =
              if captured?,
                do: {:ok, %{status: :confirmed}},
                else: Sigma.Agent.Subagents.close_for_continuation(state.subagents)

            with {:ok, %{status: :confirmed}} <- capture do
              {:ok,
               %{
                 native: {:ok, confirmation},
                 async_hooks: {:ok, host.async_hooks},
                 session_end: {:ok, host.session_end},
                 result: {:ok, confirmation}
               }}
            end

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
