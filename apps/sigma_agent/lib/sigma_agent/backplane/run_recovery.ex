defmodule Sigma.Agent.Backplane.RunRecovery do
  @moduledoc """
  Reconciles stopped Runtime runs before future admission.

  Component receipts and exact worker termination are prerequisites, separate
  from Kernel settlement. This controller never resumes a Conversation, closes
  a live host, dispatches an effect, or changes original Goal attribution.
  Child settlement does not reconcile its manager or containing root Session.
  Live root continuation preserves interrupted tools as unknown before the
  original host captures its complete ownership closure.
  """

  alias Backplane.AgentRuntime.{Error, Kernel}
  alias Backplane.AgentRuntime.Store, as: RuntimeStore
  alias Sigma.Agent.Backplane.{LifetimeEvidence, LifetimeRecovery, ProviderLifecycle, Store}

  @active [:queued, :running, :waiting_approval, :waiting_result, :cancelling]

  def reconcile_root(store, identity, %{run: run} = snapshot) do
    if interrupted_tool_intent?(run, identity) do
      {:error,
       Error.new(:resource_conflict, "A tool from the previous turn has no recorded result.",
         details: %{run_id: identity.run_id, reason: :interrupted_tool_intent}
       )}
    else
      reconcile(store, identity, snapshot, run, fn -> retired_root(store, identity) end)
    end
  end

  def reconcile_child(store, identity, %{run: run} = snapshot) do
    reconcile(store, identity, snapshot, run, fn -> retired_child(store, identity) end)
  end

  def confirm_root_components(store, identity), do: retired_root(store, identity)

  @doc "Retains a stopped root's interrupted tool outcome before preparing its continuation."
  def prepare_root_continuation(store, identity, snapshot, transcript) do
    LifetimeEvidence.with_writer(transcript, identity.thread_id, fn writer ->
      prepare_root_continuation_writer(store, identity, snapshot, writer)
    end)
  end

  defp prepare_root_continuation_writer(store, identity, %{run: run} = snapshot, writer) do
    with :ok <- interrupted_root_work(identity, snapshot),
         :ok <- original_recovery_fence(store, identity, snapshot),
         {:ok, %{status: :stopped, reason: ":normal"} = executor} <-
           LifetimeRecovery.executor(writer, identity),
         :ok <- stopped_providers(store, run),
         {:ok, snapshot} <- fence(store, identity, snapshot),
         {:ok, snapshot} <- cancel(store, snapshot),
         {:ok, _} <-
           RuntimeStore.store(Store, store, snapshot.run, %{
             command:
               {:cleanup_settled, now(),
                %{
                  certainty: :uncertain,
                  evidence: %{
                    reason: "Root executor stopped with an unresolved tool intent",
                    executor: executor
                  }
                }}
           }) do
      Store.load(store, identity.run_id)
    else
      {:error, _} = error -> error
      _ -> conflict(identity, "root continuation requires its exact stopped executor")
    end
  end

  defp interrupted_root_work(identity, %{run: run} = snapshot) do
    work = Kernel.cleanup_requirements(run)
    attempts = run[:provider_attempts]

    original_tools? =
      Enum.all?(Map.values(run.active_tools), fn operation ->
        original_operation?(operation, identity) and
          match?(
            %{type: :tool, status: :started},
            run.execution_intents["tool:#{operation.invocation_id}"]
          ) and
          not Map.has_key?(run.tool_results, operation.invocation_id)
      end)

    original_intents? =
      Enum.all?(Map.values(run.execution_intents), fn intent ->
        original_operation?(intent.operation, identity) and
          (intent.status in [:consumed, :cancelled] or
             (intent.type == :tool and intent.status == :started and
                Map.has_key?(run.active_tools, intent.operation.invocation_id)))
      end)

    if interrupted_tool_intent?(run, identity) and
         work.provider == nil and work.children == [] and work.dependencies == [] and
         is_nil(run[:active_wait]) and snapshot.effects == [] and
         original_tools? and original_intents? and
         Enum.all?(snapshot.outbox, fn intent ->
           intent.type == :tool and intent.status == :started and
             run.execution_intents["tool:#{intent.operation.invocation_id}"] === intent
         end) and
         is_map(attempts) and map_size(attempts) > 0 and
         Enum.all?(Map.values(attempts), &original_operation?(&1, identity)),
       do: :ok,
       else:
         conflict(identity, "live root continuation requires only its original interrupted tools")
  end

  defp original_operation?(%{run_id: run, incarnation: incarnation}, identity),
    do: run == identity.run_id and incarnation == identity.incarnation

  defp original_operation?(_operation, _identity), do: false

  defp original_recovery_fence(_store, identity, %{run: run})
       when run.incarnation == identity.incarnation,
       do: :ok

  defp original_recovery_fence(store, identity, %{run: run} = snapshot)
       when run.incarnation == identity.incarnation + 1 do
    expected_revisions =
      if run.state == :cancelling,
        do: [snapshot.revision, snapshot.revision - 1],
        else: [snapshot.revision]

    with {:ok, fences} <- Store.recovery_fences(store, identity.run_id) do
      if Enum.any?(fences, fn fence ->
           fence["from_incarnation"] == identity.incarnation and
             fence["to_incarnation"] == run.incarnation and
             fence["to_revision"] in expected_revisions
         end),
         do: :ok,
         else:
           conflict(
             identity,
             "live root continuation requires its exact persisted recovery fence"
           )
    end
  end

  defp original_recovery_fence(_store, identity, _snapshot),
    do: conflict(identity, "live root continuation source incarnation changed")

  def prepare_child_retirement(store, identity, %{run: run} = snapshot) do
    cond do
      run.state == :unknown_outcome ->
        confirm_retired_terminal_child(store, identity, snapshot)

      Kernel.terminal?(run.state) ->
        :ok

      true ->
        with :ok <- provider_only(identity, snapshot),
             :ok <- retired_child(store, identity),
             :ok <- stopped_providers(store, run),
             do: :ok
    end
  end

  @doc "Validates independent provider-only retirement without rewriting a terminal unknown outcome."
  def confirm_retired_terminal_root(store, identity, snapshot),
    do:
      confirm_terminal(:root, store, identity, snapshot, fn -> retired_root(store, identity) end)

  def confirm_retired_terminal_child(store, identity, snapshot),
    do:
      confirm_terminal(:child, store, identity, snapshot, fn -> retired_child(store, identity) end)

  defp confirm_terminal(
         scope,
         store,
         identity,
         %{run: %{state: :unknown_outcome} = run} = snapshot,
         retirement
       ) do
    work = Kernel.cleanup_requirements(run)
    provider = work.provider
    intents = Map.get(run, :execution_intents, %{})

    with true <- run.run_id == identity.run_id and run.incarnation >= identity.incarnation,
         true <-
           is_map(provider) and provider.run_id == identity.run_id and
             provider.incarnation == identity.incarnation,
         :ok <- ProviderLifecycle.validate_identity(provider),
         true <-
           work.tools == [] and work.children == [] and work.dependencies == [] and
             is_nil(run[:active_wait]) and snapshot.effects == [],
         true <- provider_intents?(intents, provider, snapshot.outbox, [:started, :uncertain]),
         :ok <- retirement.(),
         :ok <- stopped_providers(store, run) do
      :ok
    else
      {:error, _} = error ->
        error

      _ ->
        if scope == :root and missing_tool_result?(run, identity) do
          {:error,
           Error.new(
             :resource_conflict,
             "A tool from the previous turn has no recorded result. Use Continue to check whether a new turn can start.",
             details: %{run_id: identity.run_id, reason: :missing_tool_result}
           )}
        else
          conflict(identity, "terminal unknown root lacks complete provider-only retirement")
        end
    end
  end

  defp confirm_terminal(_scope, _store, identity, _snapshot, _retirement),
    do: conflict(identity, "run is not a terminal unknown outcome")

  def missing_tool_result?(%{state: :unknown_outcome} = run, identity),
    do: unresolved_tool_intent?(run, identity)

  def missing_tool_result?(_run, _identity), do: false

  def interrupted_tool_intent?(%{state: state} = run, identity)
      when state in [:running, :cancelling],
      do: unresolved_tool_intent?(run, identity)

  def interrupted_tool_intent?(_run, _identity), do: false

  defp unresolved_tool_intent?(
         %{run_id: id, execution_intents: intents, tool_results: results},
         %{run_id: id, incarnation: incarnation}
       )
       when is_map(intents) and is_map(results) do
    Enum.any?(intents, fn
      {_,
       %{
         type: :tool,
         status: status,
         operation: %{run_id: ^id, incarnation: ^incarnation, invocation_id: invocation}
       }}
      when status in [:started, :uncertain] ->
        not Map.has_key?(results, invocation)

      _ ->
        false
    end)
  end

  defp unresolved_tool_intent?(_run, _identity), do: false

  defp reconcile(store, identity, snapshot, run, retirement) do
    if Kernel.terminal?(run.state) do
      {:ok, snapshot}
    else
      with :ok <- provider_only(identity, snapshot),
           :ok <- retirement.(),
           :ok <- stopped_providers(store, run),
           {:ok, snapshot} <- fence(store, identity, snapshot),
           {:ok, snapshot} <- cancel(store, snapshot),
           :ok <- settle(store, snapshot) do
        Store.load(store, identity.run_id)
      end
    end
  end

  defp provider_only(identity, %{run: run} = snapshot) do
    work = Kernel.cleanup_requirements(run)
    provider = work.provider
    intents = Map.get(run, :execution_intents, %{})

    cond do
      run.run_id != identity.run_id or not is_integer(run.incarnation) or
          run.incarnation < identity.incarnation ->
        conflict(identity, "provider-only recovery run identity changed")

      run.state in [:running, :cancelling] and is_nil(provider) ->
        quiescent(identity, snapshot, work, intents)

      run.state not in @active or not is_map(provider) or
        ProviderLifecycle.validate_identity(provider) != :ok or
        provider.run_id != identity.run_id or provider.incarnation != identity.incarnation ->
        conflict(
          identity,
          "provider-only recovery requires its original active Provider identity"
        )

      work.tools != [] or work.children != [] or work.dependencies != [] or
        not is_nil(run[:active_wait]) or snapshot.effects != [] ->
        conflict(identity, "provider-only recovery has work beyond its Provider")

      not provider_intents?(intents, provider, snapshot.outbox) ->
        conflict(identity, "provider-only recovery has unreconciled execution intents")

      true ->
        :ok
    end
  end

  defp quiescent(identity, snapshot, work, intents) do
    attempts = snapshot.run[:provider_attempts]

    if work == %{provider: nil, tools: [], children: [], dependencies: []} and
         is_nil(snapshot.run[:active_wait]) and snapshot.effects == [] and snapshot.outbox == [] and
         is_map(intents) and
         Enum.all?(intents, fn
           {_key, %{status: status}} -> status in [:consumed, :cancelled]
           _ -> false
         end) and is_map(attempts) and map_size(attempts) > 0 and
         Enum.all?(attempts, fn {attempt_id, provider} ->
           ProviderLifecycle.validate_identity(provider) == :ok and
             provider.attempt_id == attempt_id and provider.run_id == identity.run_id and
             provider.incarnation == identity.incarnation
         end),
       do: :ok,
       else: conflict(identity, "quiescent recovery requires only settled original work")
  end

  defp provider_intents?(intents, provider, outbox, statuses \\ [:started])

  defp provider_intents?(intents, provider, outbox, statuses) when is_map(intents) do
    key = "provider:#{provider.attempt_id}"
    active = intents[key]

    exact_provider_intent?(active, provider, key, statuses) and
      Enum.all?(intents, fn
        {^key, ^active} -> true
        {_key, %{status: status}} when status in [:consumed, :cancelled] -> true
        _ -> false
      end) and (outbox == [] or outbox == [active])
  end

  defp provider_intents?(_intents, _provider, _outbox, _statuses), do: false

  defp exact_provider_intent?(
         %{type: :provider, status: status, operation: operation, reservation: reservation},
         provider,
         key,
         statuses
       )
       when is_map(operation) and is_map(reservation),
       do:
         status in statuses and ProviderLifecycle.identity(operation) == provider and
           reservation[:reservation_id] == key

  defp exact_provider_intent?(_intent, _provider, _key, _statuses), do: false

  defp retired_root(store, identity) do
    # TODO(upstream): gsmlg-opt/backplane#199 — provider-only recovery after
    # host loss needs a Runtime decision when the original receipts are absent.
    with {:ok, ledger} <- Store.host_retirement(store, :all) do
      hosts =
        ledger.hosts
        |> Map.values()
        |> Enum.filter(fn host ->
          Enum.any?(host.bindings, fn {_key, binding} -> binding.run_id == identity.run_id end)
        end)

      if hosts != [] and
           Enum.all?(hosts, fn host ->
             host.identity.root_header_id == identity.thread_id and
               host.identity.transcript_header_id == identity.thread_id and
               is_nil(host.identity.child_session_id) and
               host.async_hooks == %{status: :confirmed} and
               match?(%{status: :confirmed, dispatch: :completed}, host.session_end) and
               Enum.all?(host.bindings, fn {_key, binding} ->
                 (binding.run_id != identity.run_id or
                    binding.run_incarnation == identity.incarnation) and
                   host.native[{binding.native_owner_id, binding.native_session_incarnation}] ==
                     %{status: :confirmed, owner_id: binding.native_owner_id}
               end)
           end),
         do: :ok,
         else: conflict(identity, "root recovery requires all host retirement receipts")
    end
  end

  defp retired_child(store, identity) do
    with {:ok, ledger} <- Store.host_retirement(store, :all) do
      hosts =
        ledger.hosts
        |> Map.values()
        |> Enum.filter(fn host ->
          Enum.any?(host.bindings, fn {_key, binding} -> binding.run_id == identity.run_id end)
        end)

      if hosts != [] and
           Enum.all?(hosts, fn host ->
             host.identity.root_header_id == identity.root_thread_id and
               host.identity.transcript_header_id == identity.child_header_id and
               host.identity.child_session_id == identity.child_session_id and
               host.async_hooks == %{status: :confirmed} and
               Enum.all?(host.bindings, fn {_key, binding} ->
                 (binding.run_id != identity.run_id or
                    binding.run_incarnation == identity.incarnation) and
                   host.native[{binding.native_owner_id, binding.native_session_incarnation}] ==
                     %{status: :confirmed, owner_id: binding.native_owner_id}
               end)
           end),
         do: :ok,
         else: conflict(identity, "child recovery requires all host retirement receipts")
    end
  end

  defp stopped_providers(store, run) do
    attempts = run[:provider_attempts]

    if is_map(attempts) and map_size(attempts) > 0 and
         (is_nil(run.active_provider) or
            attempts[run.active_provider.attempt_id] == run.active_provider) do
      Enum.reduce_while(attempts, :ok, fn {attempt_id, provider}, :ok ->
        with :ok <- ProviderLifecycle.validate_identity(provider),
             true <- attempt_id == provider.attempt_id and provider.run_id == run.run_id,
             {:ok, %{identity: ^provider, status: :stopped}} <-
               Store.provider_lifecycle(store, provider) do
          {:cont, :ok}
        else
          {:error, _} = error ->
            {:halt, error}

          _ ->
            {:halt, conflict(run, "provider-only recovery requires exact Provider termination")}
        end
      end)
    else
      conflict(run, "provider-only recovery Provider attempts are incomplete")
    end
  end

  defp fence(store, identity, %{run: run} = snapshot) do
    if run.incarnation > identity.incarnation do
      {:ok, snapshot}
    else
      with {:ok, fenced} <-
             RuntimeStore.fence(
               Store,
               store,
               run.run_id,
               snapshot.revision,
               run.incarnation,
               run.incarnation + 1
             ),
           do: load_revision(store, run.run_id, fenced.revision)
    end
  end

  defp cancel(_store, %{run: %{state: :cancelling}} = snapshot), do: {:ok, snapshot}

  defp cancel(store, %{run: run}) do
    with {:ok, committed} <-
           RuntimeStore.store(Store, store, run, %{command: {:cancel, now()}}),
         do: load_revision(store, run.run_id, committed.revision)
  end

  defp settle(store, %{run: run}) do
    case RuntimeStore.store(Store, store, run, %{
           command:
             {:cleanup_settled, now(),
              %{certainty: :confirmed, settled: Kernel.cleanup_requirements(run)}}
         }) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp load_revision(store, run_id, revision) do
    with {:ok, snapshot} <- Store.load(store, run_id) do
      if snapshot.revision == revision,
        do: {:ok, snapshot},
        else: conflict(snapshot.run, "provider-only recovery revision changed")
    end
  end

  defp now, do: System.system_time(:millisecond)

  defp conflict(identity, message),
    do: {:error, Error.new(:resource_conflict, message, details: %{run_id: identity.run_id})}
end
