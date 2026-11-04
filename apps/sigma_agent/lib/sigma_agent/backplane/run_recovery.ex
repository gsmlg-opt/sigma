defmodule Sigma.Agent.Backplane.RunRecovery do
  @moduledoc """
  Reconciles retired provider-only runs before Goal receipt recovery.

  Component receipts and exact worker termination are prerequisites, separate
  from Kernel settlement. This controller never resumes a Conversation, closes
  a live host, dispatches an effect, or changes original Goal attribution.
  Child settlement does not reconcile its manager or containing root Session.
  """

  alias Backplane.AgentRuntime.{Error, Kernel}
  alias Backplane.AgentRuntime.Store, as: RuntimeStore
  alias Sigma.Agent.Backplane.{ProviderLifecycle, Store}

  @active [:queued, :running, :waiting_approval, :waiting_result, :cancelling]

  def reconcile_root(store, identity, %{run: run} = snapshot) do
    reconcile(store, identity, snapshot, run, fn -> retired_root(store, identity) end)
  end

  def reconcile_child(store, identity, %{run: run} = snapshot) do
    reconcile(store, identity, snapshot, run, fn -> retired_child(store, identity) end)
  end

  def confirm_root_components(store, identity), do: retired_root(store, identity)

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
    do: confirm_terminal(store, identity, snapshot, fn -> retired_root(store, identity) end)

  def confirm_retired_terminal_child(store, identity, snapshot),
    do: confirm_terminal(store, identity, snapshot, fn -> retired_child(store, identity) end)

  defp confirm_terminal(
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
      {:error, _} = error -> error
      _ -> conflict(identity, "terminal unknown root lacks complete provider-only retirement")
    end
  end

  defp confirm_terminal(_store, identity, _snapshot, _retirement),
    do: conflict(identity, "run is not a terminal unknown outcome")

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

    if is_map(attempts) and attempts[run.active_provider.attempt_id] == run.active_provider do
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
