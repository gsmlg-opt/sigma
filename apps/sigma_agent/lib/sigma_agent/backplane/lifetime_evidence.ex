defmodule Sigma.Agent.Backplane.LifetimeEvidence do
  @moduledoc """
  Observation-only lifetime reconciliation for future root and child admissions.

  Public Registry, Session and manager manifests remain independent of historical
  outcomes. Only actual executor/Provider exits and confirmed host component facts
  satisfy obligations. Explicit continuation preserves missing tool outcomes and
  requires independently acknowledged closure before admitting fresh root work.
  """

  alias Backplane.AgentRuntime.Codex.{MultiAgent, Reconciliation, ResourceRegistry, Session}
  alias Backplane.AgentRuntime.Codex.Reconciliation.{Continuation, Evidence}
  alias Backplane.AgentRuntime.Error
  alias Sigma.Agent.Backplane.{LifetimeRecovery, RunRecovery, Store}

  def capture_session(%{recovery: nil}), do: :ok
  def capture_session(%{binding: nil}), do: :ok

  def capture_session(%{recovery: %{writer: writer}, binding: binding}) do
    with :ok <- capture_registry(writer, binding),
         {:ok, manifest} <- Session.recovery_manifest(binding.session),
         {:ok, receipt} <- seal(writer, manifest, &observe(writer, manifest, &1)),
         {:ok, acknowledgement} <-
           Session.reconcile_close(binding.session, receipt["receipt_id"]),
         :ok <-
           LifetimeRecovery.put_evidence(
             writer,
             "session-ack:" <> receipt["receipt_digest"],
             acknowledgement
           ) do
      :ok
    end
  end

  @doc "Captures actual ownership closure while leaving missing tool results unresolved."
  def capture_for_continuation(%{recovery: %{writer: writer}, binding: binding})
      when is_map(binding) do
    with :ok <- capture_registry(writer, binding),
         {:ok, manifest} <- Session.recovery_manifest(binding.session),
         {:ok, {Store, store}} <- LifetimeRecovery.runtime_store(writer, "root"),
         {:ok, %{run: %{state: :unknown_outcome} = run}} <- Store.load(store, binding.run_id),
         {:ok, _receipts} <- continuation_subordinates(writer, manifest),
         {:ok, receipt} <- continuation_receipt(writer, manifest, run),
         true <- pending_lost_tools?(receipt, run) do
      :ok
    else
      {:error, _} = error -> error
      _ -> fail("continuation capture requires its exact unresolved root tool obligations")
    end
  end

  def capture_for_continuation(_context),
    do: fail("continuation capture requires the original root Session binding")

  defp capture_registry(writer, binding) do
    with {:ok, registry} <-
           ResourceRegistry.recovery_manifest(binding.resource_registry, binding.owner_id),
         {:ok, _} <-
           ResourceRegistry.recovery_closed(binding.resource_registry, binding.owner_id),
         {:ok, receipt} <-
           seal(writer, registry, fn _ -> {:ok, "closed", "public-registry-close"} end),
         {:ok, acknowledgement} <-
           ResourceRegistry.reconcile_owner(
             binding.resource_registry,
             binding.owner_id,
             receipt["receipt_id"]
           ),
         :ok <-
           LifetimeRecovery.put_evidence(
             writer,
             "registry_owner-ack:" <> receipt["receipt_digest"],
             acknowledgement
           ),
         do: :ok
  end

  def finalize(nil, _manager), do: :ok
  def finalize(_writer, nil), do: :ok

  def finalize(writer, manager) do
    with :ok <- LifetimeRecovery.ready(writer),
         {:ok, snapshot} <- MultiAgent.snapshot(manager),
         :ok <- collect_children(writer, manager, snapshot.agents),
         {:ok, manifest} <- MultiAgent.recovery_manifest(manager, :manager),
         {:ok, receipt} <- seal(writer, manifest, &observe(writer, manifest, &1)),
         {:ok, acknowledgement} <- MultiAgent.reconcile_close(manager, receipt["receipt_id"]),
         {:ok, _} <- MultiAgent.recovery_closed(manager),
         :ok <-
           LifetimeRecovery.put_evidence(
             writer,
             "manager-ack:" <> receipt["receipt_digest"],
             acknowledgement
           ),
         do: :ok
  end

  defp collect_children(writer, manager, children) do
    children
    |> Enum.sort_by(&String.length(&1.name), :desc)
    |> Enum.reduce_while(:ok, fn child, :ok ->
      with {:ok, manifest} <- MultiAgent.recovery_manifest(manager, child.name),
           {:ok, receipt} <- seal(writer, manifest, &observe(writer, manifest, &1)),
           {:ok, acknowledgement} <- MultiAgent.reconcile_child(manager, receipt["receipt_id"]),
           :ok <-
             LifetimeRecovery.put_evidence(
               writer,
               "child-ack:" <> receipt["receipt_digest"],
               acknowledgement
             ) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  def recover_child(nil, _store, _identity), do: :ok

  def recover_child(%{writer: writer}, store, identity) do
    with {:ok, snapshot} <- Store.load(store, identity.run_id),
         :ok <- RunRecovery.prepare_child_retirement(store, identity, snapshot),
         :ok <- LifetimeRecovery.retire_executor(writer, identity),
         {:ok, _} <- LifetimeRecovery.executor(writer, identity),
         {:ok, _} <- RunRecovery.reconcile_child(store, identity, snapshot),
         do: :ok
  end

  @doc "Prepares one explicit fresh root admission while preserving an unknown tool outcome."
  def prepare_continuation(transcript, identity, instruction_ref) when is_binary(transcript) do
    identity = Map.take(identity, [:thread_id, :run_id, :incarnation])

    with_writer(transcript, identity.thread_id, fn writer ->
      request_ref = "continuation-request:" <> Evidence.digest(identity)

      case continuation_request(writer, identity, request_ref) do
        {:ok, request} ->
          if request["instruction_ref"] == instruction_ref,
            do: Continuation.prepare(LifetimeRecovery.configuration(writer), request),
            else:
              {:error,
               Error.new(:resource_conflict, "another Continue instruction owns this run")}

        {:error, %Error{class: :not_found}} ->
          prepare_new_continuation(writer, identity, instruction_ref, request_ref)

        error ->
          error
      end
    end)
  end

  @doc "Reads an already accepted continuation without creating a decision or repeating work."
  def read_continuation(transcript, identity) when is_binary(transcript) do
    identity = Map.take(identity, [:thread_id, :run_id, :incarnation])

    with_writer(transcript, identity.thread_id, &read_continuation_writer(&1, identity))
  end

  def read_continuation(nil, _identity),
    do: {:error, Error.new(:not_found, "root continuation has no transcript")}

  defp read_continuation_writer(writer, identity) do
    request_ref = "continuation-request:" <> Evidence.digest(identity)

    with {:ok, request} <- continuation_request(writer, identity, request_ref),
         true <-
           request["source"] == %{
             "store_ref" => "root",
             "run_id" => identity.run_id,
             "original_incarnation" => identity.incarnation
           },
         true <- request["subject"]["scope_id"] == identity.thread_id,
         id =
           "continuation_" <>
             Evidence.digest(%{
               subject: request["subject"],
               source: Map.take(request["source"], ~w(run_id original_incarnation))
             }),
         {:ok, _decision} <- LifetimeRecovery.load_continuation(writer, id) do
      Continuation.prepare(LifetimeRecovery.configuration(writer), request)
    else
      {:error, _} = error -> error
      _ -> fail("stored continuation belongs to another original run")
    end
  end

  defp continuation_request(writer, identity, request_ref) do
    case LifetimeRecovery.load_evidence(writer, request_ref) do
      {:error, %Error{class: :not_found}} ->
        recover_historical_request(writer, identity)

      result ->
        result
    end
  end

  defp recover_historical_request(writer, identity) do
    with {:ok, {Store, store}} <- LifetimeRecovery.runtime_store(writer, "root"),
         {:ok, subject} <- historical_subject(store, identity),
         source = %{"run_id" => identity.run_id, "original_incarnation" => identity.incarnation},
         id = "continuation_" <> Evidence.digest(%{subject: subject, source: source}),
         {:ok, decision} <- LifetimeRecovery.load_continuation(writer, id),
         :ok <- Evidence.sealed(decision, "decision_digest"),
         :ok <- Evidence.identifier(decision["request_digest"]),
         {:ok, request} <-
           LifetimeRecovery.load_evidence(
             writer,
             "continuation-candidate:" <> decision["request_digest"]
           ),
         true <- Evidence.digest(request) == decision["request_digest"] do
      {:ok, request}
    else
      {:error, %Error{class: :unknown_outcome}} ->
        {:error, Error.new(:not_found, "root continuation request is unavailable")}

      {:error, _} = error ->
        error

      _ ->
        fail("accepted historical Continue request changed")
    end
  end

  defp prepare_new_continuation(writer, identity, instruction_ref, request_ref) do
    with {:ok, manifests} <- LifetimeRecovery.manifests(writer) do
      original_manifest? =
        Enum.any?(manifests, fn {_id, manifest} ->
          manifest["subject"]["kind"] == "session" and
            Enum.any?(manifest["run_refs"], &(&1["run_id"] == identity.run_id))
        end)

      if original_manifest?,
        do: prepare_manifest_continuation(writer, identity, instruction_ref, request_ref),
        else:
          prepare_historical_continuation(
            writer,
            identity,
            instruction_ref,
            request_ref,
            manifests
          )
    end
  end

  defp prepare_manifest_continuation(writer, identity, instruction_ref, request_ref) do
    source = %{
      "run_id" => identity.run_id,
      "original_incarnation" => identity.incarnation,
      "store_ref" => "root"
    }

    with :ok <- Evidence.identifier(instruction_ref),
         {:ok, admission} <-
           LifetimeRecovery.load_evidence(writer, "root-admission:" <> identity.run_id),
         true <-
           admission ==
             Map.put(Map.take(source, ~w(run_id store_ref)), "incarnation", identity.incarnation),
         {:ok, %{status: :stopped, reason: ":normal"} = executor} <-
           LifetimeRecovery.executor(writer, identity),
         {:ok, {Store, store}} <- LifetimeRecovery.runtime_store(writer, "root"),
         {:ok, %{run: %{state: :unknown_outcome} = run}} <- Store.load(store, identity.run_id),
         {:ok, manifests} <- LifetimeRecovery.manifests(writer),
         {:ok, manifest} <- root_manifest(manifests, source),
         {:ok, hosts} <- continuation_hosts(store, identity, manifest),
         {:ok, subordinate_receipts} <- continuation_subordinates(writer, manifest),
         {:ok, receipt} <- continuation_receipt(writer, manifest, run),
         true <- pending_lost_tools?(receipt, run),
         # A normal Conversation exit joins its complete Task supervisor. Native
         # Session and Registry acknowledgements cover registered backend and OS
         # workers, including Code Mode's exact process cleanup. Together these
         # observations establish cessation without inventing an effect result.
         {:ok, local_ref} <-
           continuation_fact(writer, "local-execution", %{
             "executor" => executor,
             "hosts" => hosts,
             "registry_receipts" => subordinate_receipts
           }),
         {:ok, hooks_ref} <-
           continuation_fact(
             writer,
             "async-hooks",
             Enum.map(hosts, &Map.take(&1, ~w(identity async_hooks)))
           ),
         {:ok, end_ref} <-
           continuation_fact(
             writer,
             "session-end",
             Enum.map(hosts, &Map.take(&1, ~w(identity session_end)))
           ),
         closure = %{
           "schema_version" => 1,
           "subject" => manifest["subject"],
           "source" => source,
           "receipt_digest" => receipt["receipt_digest"],
           "components" => %{
             "root_admission" => %{
               "status" => "admitted",
               "source_ref" => "root-admission:" <> identity.run_id
             },
             "local_execution" => %{"status" => "stopped", "source_ref" => local_ref},
             "async_hooks" => %{"status" => "closed", "source_ref" => hooks_ref},
             "session_end" => %{"status" => "closed", "source_ref" => end_ref}
           }
         },
         {:ok, closure_ref} <- continuation_fact(writer, "closure", closure),
         request = %{
           "schema_version" => 1,
           "subject" => manifest["subject"],
           "source" => source,
           "receipt_id" => receipt["receipt_id"],
           "closure_evidence_ref" => closure_ref,
           "instruction_ref" => instruction_ref
         },
         :ok <- LifetimeRecovery.put_evidence(writer, request_ref, request) do
      Continuation.prepare(LifetimeRecovery.configuration(writer), request)
    else
      {:error, _} = error ->
        error

      _ ->
        fail(
          "Continue requires the original execution, async-hook and SessionEnd shutdown acknowledgements"
        )
    end
  end

  defp prepare_historical_continuation(writer, identity, instruction_ref, request_ref, manifests) do
    source = %{
      "run_id" => identity.run_id,
      "original_incarnation" => identity.incarnation,
      "store_ref" => "root"
    }

    with :ok <- Evidence.identifier(instruction_ref),
         {:ok, {Store, store}} <- LifetimeRecovery.runtime_store(writer, "root"),
         {:ok, %{run: %{state: :unknown_outcome} = run} = snapshot} <-
           Store.load(store, identity.run_id),
         {:ok, subject} <- historical_subject(store, identity),
         true <- Enum.all?(manifests, fn {_id, manifest} -> manifest["subject"] != subject end),
         :ok <- historical_registry(writer, subject, manifests),
         {:ok, hosts} <- continuation_hosts(store, identity, %{"subject" => subject}),
         {:ok, managers, root_agent_id} <- historical_managers(writer, identity, manifests),
         {:ok, executor} <- LifetimeRecovery.executor(writer, identity),
         {:ok, executor_ref} <- continuation_fact(writer, "executor-down", executor),
         {:ok, provider_refs} <-
           collect(Enum.sort(run.provider_attempts), fn {_id, operation} ->
             with {:ok, fact} <- Store.provider_lifecycle(store, operation),
                  do: continuation_fact(writer, "provider-down", fact)
           end),
         {:ok, host_refs} <-
           collect(hosts, fn host ->
             host =
               Map.update!(host, "native", fn native ->
                 Enum.map(native, fn fact ->
                   {incarnation, fact} = Map.pop!(fact, "incarnation")
                   Map.put(fact, "session_incarnation", incarnation)
                 end)
               end)

             continuation_fact(writer, "source-host", host)
           end),
         {:ok, fences} <- Store.recovery_fences(store, identity.run_id),
         bundle = %{
           "schema_version" => 1,
           "subject" => subject,
           "source" => source,
           "root_agent_id" => root_agent_id,
           "authority" => %{
             "revision" => snapshot.revision,
             "incarnation" => snapshot.incarnation,
             "fences" => fences
           },
           "root_admission_ref" => "root-admission:" <> identity.run_id,
           "executor_ref" => executor_ref,
           "provider_refs" => provider_refs,
           "host_refs" => host_refs,
           "managers" => managers
         },
         {:ok, bundle_ref} <- continuation_fact(writer, "historical-source", bundle),
         request = %{
           "schema_version" => 1,
           "mode" => "historical_owner_loss",
           "subject" => subject,
           "source" => source,
           "root_agent_id" => root_agent_id,
           "evidence_ref" => bundle_ref,
           "instruction_ref" => instruction_ref
         },
         :ok <-
           LifetimeRecovery.put_evidence(
             writer,
             "continuation-candidate:" <> Evidence.digest(request),
             request
           ),
         {:ok, decision} <- Continuation.prepare(LifetimeRecovery.configuration(writer), request),
         :ok <- LifetimeRecovery.put_evidence(writer, request_ref, request) do
      {:ok, decision}
    else
      {:error, _} = error ->
        error

      _ ->
        fail(
          "historical Continue requires the exact stopped source and its original acknowledgements"
        )
    end
  end

  defp historical_subject(store, identity) do
    with {:ok, ledger} <- Store.host_retirement(store, :all) do
      bindings =
        for host <- Map.values(ledger.hosts),
            binding <- Map.values(host.bindings),
            binding.run_id == identity.run_id,
            do: binding

      subjects =
        Enum.map(bindings, fn binding ->
          %{
            "kind" => "session",
            "owner_id" => binding.native_owner_id,
            "incarnation" => binding.native_session_incarnation,
            "scope_id" => identity.thread_id
          }
        end)
        |> Enum.uniq()

      with [subject] <- subjects,
           true <- Enum.all?(bindings, &(&1.run_incarnation == identity.incarnation)) do
        {:ok, subject}
      else
        _ -> fail("historical Continue requires one exact original native Session binding")
      end
    end
  end

  defp historical_registry(writer, subject, manifests) do
    registry_subject = Map.put(subject, "kind", "registry_owner")

    manifests
    |> Map.values()
    |> Enum.filter(&(&1["subject"] == registry_subject))
    |> Enum.reduce_while(:ok, fn manifest, :ok ->
      case confirmed_tree(writer, manifest) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp historical_managers(writer, identity, manifests) do
    managers =
      manifests
      |> Map.values()
      |> Enum.filter(fn manifest ->
        manifest["subject"]["kind"] == "manager" and
          manifest["subject"]["scope_id"] == identity.thread_id
      end)
      |> Enum.sort_by(& &1["manifest_id"])

    roots = managers |> Enum.map(& &1["subject"]["root_agent_id"]) |> Enum.uniq()

    with [root_agent_id] <- roots,
         :ok <- Evidence.identifier(root_agent_id),
         {:ok, entries} <-
           collect(managers, fn manifest ->
             with :ok <- confirmed_tree(writer, manifest),
                  {:ok, receipt} <- current_receipt(writer, manifest) do
               {:ok,
                %{
                  "receipt_id" => receipt["receipt_id"],
                  "acknowledgement_ref" => "manager-ack:" <> receipt["receipt_digest"]
                }}
             end
           end) do
      {:ok, entries, root_agent_id}
    else
      {:error, _} = error -> error
      _ -> fail("historical Continue requires the original manager closure receipts")
    end
  end

  defp root_manifest(manifests, source) do
    matches =
      for {_id, manifest} <- manifests,
          manifest["subject"]["kind"] == "session" and source in manifest["run_refs"],
          do: manifest

    case matches do
      [manifest] -> {:ok, manifest}
      _ -> fail("Continue requires one exact original root Session manifest")
    end
  end

  defp continuation_hosts(store, identity, manifest) do
    with {:ok, ledger} <- Store.host_retirement(store, :all) do
      hosts =
        ledger.hosts
        |> Map.values()
        |> Enum.filter(fn host ->
          Enum.any?(host.bindings, fn {_id, binding} ->
            binding.run_id == identity.run_id and binding.run_incarnation == identity.incarnation
          end)
        end)

      subject = manifest["subject"]

      with true <- hosts != [] and Enum.all?(hosts, &source_host?(&1, identity, subject)),
           [] <- hosts |> Enum.flat_map(&missing_shutdown_acks/1) |> Enum.uniq() do
        hosts
        |> Enum.sort_by(& &1.identity.host_lifetime_id)
        |> Enum.map(fn host ->
          %{
            identity: host.identity,
            bindings: host.bindings |> Map.values() |> Enum.sort(),
            native:
              host.native
              |> Enum.map(fn {{owner, incarnation}, fact} ->
                Map.put(fact, :incarnation, incarnation) |> Map.put(:owner_id, owner)
              end)
              |> Enum.sort(),
            async_hooks: host.async_hooks,
            session_end: host.session_end
          }
        end)
        |> Evidence.public()
      else
        false ->
          fail("Continue could not verify the host binding for the previous run.")

        missing ->
          fail(
            "The previous tool result is unknown. Continue is blocked because the original run has no confirmed shutdown for #{Enum.join(missing, " and ")}."
          )
      end
    end
  end

  defp source_host?(host, identity, subject) do
    host.identity.root_header_id == identity.thread_id and
      host.identity.transcript_header_id == identity.thread_id and
      is_nil(host.identity.child_session_id) and subject["scope_id"] == identity.thread_id and
      Enum.any?(host.bindings, fn {_key, binding} ->
        binding.run_id == identity.run_id and binding.run_incarnation == identity.incarnation and
          binding.native_owner_id == subject["owner_id"] and
          binding.native_session_incarnation == subject["incarnation"]
      end)
  end

  defp missing_shutdown_acks(host) do
    native_closed? =
      Enum.all?(host.bindings, fn {_key, binding} ->
        host.native[{binding.native_owner_id, binding.native_session_incarnation}] ==
          %{status: :confirmed, owner_id: binding.native_owner_id}
      end)

    for {name, false} <- [
          {"native tools", native_closed?},
          {"async hooks", host.async_hooks == %{status: :confirmed}},
          {"SessionEnd", match?(%{status: :confirmed, dispatch: :completed}, host.session_end)}
        ],
        do: name
  end

  defp continuation_subordinates(writer, manifest) do
    owned = Enum.filter(manifest["obligations"], &(&1["kind"] in ~w(registry_owner manager)))
    registry = Enum.filter(owned, &(&1["kind"] == "registry_owner"))
    managers = Enum.filter(owned, &(&1["kind"] == "manager"))
    expected_registry = Map.put(manifest["subject"], "kind", "registry_owner")

    with [%{"identity" => %{"subject" => ^expected_registry}}] <- registry,
         [_ | _] <- managers,
         {:ok, manifests} <- LifetimeRecovery.manifests(writer) do
      collect(owned, fn obligation ->
        subject = obligation["identity"]["subject"]

        subordinate =
          Enum.find_value(manifests, fn {_id, item} ->
            if item["subject"] == subject and
                 item["manifest_digest"] == obligation["identity"]["manifest_digest"],
               do: item
          end)

        with true <-
               subject["kind"] == obligation["kind"] and
                 subject["scope_id"] == manifest["subject"]["scope_id"],
             true <- is_map(subordinate),
             :ok <- confirmed_tree(writer, subordinate),
             {:ok, receipt} <- current_receipt(writer, subordinate) do
          {:ok, receipt}
        else
          {:error, _} = error -> error
          _ -> fail("continuation subordinate ownership does not match its original root Session")
        end
      end)
    else
      {:error, _} = error -> error
      _ -> fail("Continue requires the original Registry and manager closure receipts")
    end
  end

  defp pending_lost_tools?(receipt, run) do
    lost = lost_tool_ids(run)
    obligations = receipt["pending"] ++ receipt["unresolved_effects"]

    obligations != [] and
      Enum.all?(obligations, fn obligation ->
        obligation["kind"] == "tool" and obligation["identity"]["run_id"] == run.run_id and
          obligation["identity"]["invocation_id"] in lost
      end)
  end

  defp lost_tool_ids(run) do
    for %{type: :tool, status: status, operation: operation} <- Map.values(run.execution_intents),
        status in [:started, :uncertain],
        not Map.has_key?(run.tool_results, operation.invocation_id),
        do: operation.invocation_id
  end

  defp continuation_receipt(writer, manifest, run) do
    lost = lost_tool_ids(run)

    result =
      seal(writer, manifest, fn obligation ->
        case observe(writer, manifest, obligation) do
          {:error, %Error{class: :unknown_outcome}} = error ->
            if obligation["kind"] == "tool" and obligation["identity"]["invocation_id"] in lost,
              do: :pending,
              else: error

          result ->
            result
        end
      end)

    case result do
      {:ok, receipt} ->
        {:ok, receipt}

      {:error, %Error{class: :unknown_outcome, details: %{receipt_id: id}}} ->
        LifetimeRecovery.load_receipt(writer, id)

      error ->
        error
    end
  end

  defp continuation_fact(writer, kind, fact) do
    with {:ok, fact} <- Evidence.public(fact),
         ref = "continuation-" <> kind <> ":" <> Evidence.digest(fact),
         :ok <- LifetimeRecovery.put_evidence(writer, ref, fact),
         do: {:ok, ref}
  end

  def allow_root(store, identity, snapshot, transcript) do
    with :ok <- RunRecovery.confirm_retired_terminal_root(store, identity, snapshot),
         do: allow_root_evidence(identity, transcript)
  end

  defp allow_root_evidence(identity, transcript) when is_binary(transcript) do
    with_writer(transcript, identity.thread_id, fn writer ->
      with :ok <- refresh_writer(writer),
           {:ok, %{"run_id" => run_id, "incarnation" => incarnation, "store_ref" => "root"}} <-
             LifetimeRecovery.load_evidence(writer, "root-admission:" <> identity.run_id),
           true <- run_id == identity.run_id and incarnation == identity.incarnation,
           {:ok, _} <- LifetimeRecovery.executor(writer, identity),
           {:ok, manifests} <- LifetimeRecovery.manifests(writer),
           manifest when is_map(manifest) <-
             Enum.find_value(manifests, fn {_id, item} ->
               if item["subject"]["kind"] == "session" and
                    Enum.any?(
                      item["run_refs"],
                      &(&1["store_ref"] == "root" and &1["run_id"] == identity.run_id and
                          &1["original_incarnation"] == identity.incarnation)
                    ),
                  do: item
             end),
           {:ok, receipt} <- current_receipt(writer, manifest),
           :ok <- confirmed_tree(writer, manifest),
           true <- receipt["retirement"] == "confirmed" do
        :ok
      else
        {:error, _} = error -> error
        _ -> fail("unknown root lifetime retirement is unconfirmed")
      end
    end)
  end

  defp allow_root_evidence(_identity, _transcript),
    do: fail("root lifetime evidence has no transcript")

  def allow_child(store, identity, snapshot, transcript) do
    with_writer(transcript, identity.root_thread_id, fn writer ->
      with :ok <- refresh_writer(writer),
           :ok <- RunRecovery.confirm_retired_terminal_child(store, identity, snapshot),
           {:ok, admissions} <- LifetimeRecovery.stored_children(writer),
           admission when is_map(admission) <-
             Enum.find(admissions, fn item ->
               item["child_identity"]["run_id"] == identity.run_id and
                 item["child_identity"]["run_incarnation"] == identity.incarnation
             end),
           true <- child_retired?(writer, admission["child_identity"]),
           do: :ok,
           else: (
             {:error, _} = error -> error
             _ -> fail("unknown child lifetime retirement is unconfirmed")
           )
    end)
  end

  def retired_roster?(transcript, header, roster) do
    acknowledged_roster?(transcript, header, roster, true)
  end

  # Native ownership must close before the root hook and SessionEnd facts can
  # be recorded. This check permits retirement, never admission of new work.
  def closed_roster?(transcript, header, roster) do
    acknowledged_roster?(transcript, header, roster, false)
  end

  defp acknowledged_roster?(transcript, header, roster, root_components?) do
    with_writer(transcript, header, fn writer ->
      with :ok <- refresh_writer(writer),
           {:ok, admissions} <- LifetimeRecovery.stored_children(writer),
           true <-
             Enum.all?(roster, fn row ->
               Enum.any?(admissions, fn admission ->
                 child = admission["child_identity"]

                 String.ends_with?(row.agent_id, ":" <> child["agent_id"]) and
                   String.ends_with?(row.run_id, ":" <> child["run_id"]) and
                   row.root_session_id == child["root_agent_id"] and
                   row.incarnation >= child["run_incarnation"] and
                   child_retired?(writer, child, root_components?)
               end)
             end),
           do: :ok,
           else: (_ -> fail("historical child lifetime evidence is incomplete"))
    end) == :ok
  end

  defp child_retired?(writer, child, root_components? \\ true) do
    with {:ok, manifests} <- LifetimeRecovery.manifests(writer),
         child_manifest when is_map(child_manifest) <-
           Enum.find_value(manifests, fn {_id, m} ->
             if m["subject"] == %{"kind" => "child", "identity" => child}, do: m
           end),
         :ok <- confirmed_ack(writer, child_manifest),
         manager when is_map(manager) <-
           Enum.find_value(manifests, fn {_id, m} ->
             if m["subject"]["kind"] == "manager" and
                  m["subject"]["manager_id"] == child["source_manager_id"] and
                  Enum.any?(
                    m["obligations"],
                    &(&1["identity"]["subject"] == child_manifest["subject"])
                  ),
                do: m
           end),
         :ok <- confirmed_ack(writer, manager),
         root when is_map(root) <-
           Enum.find_value(manifests, fn {_id, m} ->
             if m["subject"]["kind"] == "session" and
                  Enum.any?(
                    m["obligations"],
                    &(&1["kind"] == "manager" and &1["identity"]["subject"] == manager["subject"])
                  ),
                do: m
           end),
         :ok <- confirmed_tree(writer, root),
         :ok <- if(root_components?, do: root_components(writer, root), else: :ok) do
      true
    else
      _ -> false
    end
  end

  defp confirmed_ack(writer, manifest) do
    with {:ok, _} <- current_receipt(writer, manifest),
         do: LifetimeRecovery.acknowledged(writer, manifest)
  end

  defp confirmed_tree(writer, manifest) do
    with :ok <- confirmed_ack(writer, manifest),
         {:ok, manifests} <- LifetimeRecovery.manifests(writer) do
      manifest["obligations"]
      |> Enum.filter(&is_map(&1["identity"]["subject"]))
      |> Enum.reduce_while(:ok, fn obligation, :ok ->
        identity = obligation["identity"]

        child =
          Enum.find_value(manifests, fn {_id, m} ->
            if m["subject"] == identity["subject"] and
                 (is_nil(identity["manifest_digest"]) or
                    m["manifest_digest"] == identity["manifest_digest"]),
               do: m
          end)

        case child && confirmed_tree(writer, child) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
          _ -> {:halt, fail("owned public acknowledgement inventory is incomplete")}
        end
      end)
    end
  end

  defp root_components(writer, manifest) do
    Enum.reduce_while(manifest["run_refs"], :ok, fn ref, :ok ->
      with {:ok, {Store, store}} <- LifetimeRecovery.runtime_store(writer, ref["store_ref"]),
           :ok <-
             RunRecovery.confirm_root_components(store, %{
               thread_id: LifetimeRecovery.scope(writer),
               run_id: ref["run_id"],
               incarnation: ref["original_incarnation"]
             }),
           do: {:cont, :ok},
           else: (error -> {:halt, error})
    end)
  end

  def refresh(transcript, header) when is_binary(transcript),
    do: with_writer(transcript, header, &refresh_writer/1)

  def refresh(_transcript, _header), do: :ok

  defp refresh_writer(writer) do
    with {:ok, manifests} <- LifetimeRecovery.manifests(writer) do
      manifests
      |> Map.values()
      |> Enum.sort_by(&manifest_order/1)
      |> Enum.reduce_while(:ok, fn manifest, :ok ->
        result =
          case continued_manifest?(writer, manifest) do
            {:ok, true} -> {:ok, :retained_unknown_outcome}
            {:ok, false} -> seal(writer, manifest, &observe(writer, manifest, &1))
            error -> error
          end

        case result do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  # The explicit decision preserves its original partial receipt. Refreshing
  # other lifetimes still requires their full public retirement acknowledgements.
  defp continued_manifest?(writer, %{"subject" => %{"kind" => "session"}} = manifest) do
    manifest["run_refs"]
    |> Enum.filter(&(&1["store_ref"] == "root"))
    |> Enum.reduce_while({:ok, false}, fn source, _acc ->
      identity = %{
        thread_id: manifest["subject"]["scope_id"],
        run_id: source["run_id"],
        incarnation: source["original_incarnation"]
      }

      case read_continuation_writer(writer, identity) do
        {:ok, decision} ->
          {:halt, retained_continuation(writer, manifest, decision)}

        {:error, %Error{class: :not_found}} ->
          {:cont, {:ok, false}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp continued_manifest?(_writer, _manifest), do: {:ok, false}

  defp retained_continuation(writer, manifest, decision) do
    with true <- decision["subject"] == manifest["subject"],
         {:ok, receipt} <- LifetimeRecovery.load_receipt(writer, decision["receipt_id"]),
         {:ok, ^receipt} <- Evidence.validate_receipt(receipt),
         true <-
           receipt["manifest_digest"] == manifest["manifest_digest"] and
             receipt["receipt_digest"] == decision["receipt_digest"],
         source = decision["source"],
         {:ok, {Store, store}} <- LifetimeRecovery.runtime_store(writer, source["store_ref"]),
         {:ok, %{run: %{state: :unknown_outcome} = run}} <- Store.load(store, source["run_id"]),
         true <-
           Evidence.digest(run[:outcome]) == decision["historical_outcome"]["outcome_digest"] do
      {:ok, true}
    else
      {:error, _} = error -> error
      _ -> fail("accepted continuation source or partial lifetime receipt changed")
    end
  end

  defp manifest_order(manifest) do
    {rank, depth} =
      case manifest["subject"]["kind"] do
        "registry_owner" ->
          {0, 0}

        "session" ->
          {if(Enum.any?(manifest["obligations"], &(&1["kind"] == "manager")), do: 4, else: 1), 0}

        "child" ->
          {2, -length(String.split(manifest["subject"]["identity"]["name"], "/", trim: true))}

        "manager" ->
          {3, 0}
      end

    {rank, depth, manifest["manifest_id"]}
  end

  @doc false
  def with_writer(transcript, header, fun) do
    case LifetimeRecovery.locate(transcript) do
      pid when is_pid(pid) ->
        fun.(pid)

      nil ->
        case LifetimeRecovery.start_link(
               transcript: transcript,
               root_header_id: header,
               root_agent_id: nil
             ) do
          {:ok, writer} ->
            result = fun.(writer)

            case LifetimeRecovery.retire(writer) do
              :ok -> result
              {:error, _} = error -> error
            end

          {:error, {:already_started, writer}} ->
            fun.(writer)

          {:error, _} = error ->
            error
        end
    end
  end

  defp current_receipt(writer, manifest) do
    Reconciliation.load_confirmed(
      LifetimeRecovery.configuration(writer),
      "closure-receipt:" <> manifest["manifest_id"],
      manifest["subject"],
      manifest["manifest_digest"]
    )
  end

  defp seal(writer, manifest, observer) do
    id = "closure-receipt:" <> manifest["manifest_id"]

    case LifetimeRecovery.load_receipt(writer, id) do
      {:ok, %{"retirement" => "confirmed"} = previous} ->
        case current_receipt(writer, manifest) do
          {:ok, _} = result -> result
          {:error, _} -> seal(writer, manifest, observer, id, previous["revision"])
        end

      {:ok, previous} ->
        seal(writer, manifest, observer, id, previous["revision"])

      {:error, %Error{class: :not_found}} ->
        seal(writer, manifest, observer, id, 0)

      {:error, _} = error ->
        error
    end
  end

  defp seal(writer, manifest, observer, id, revision) do
    with :ok <- LifetimeRecovery.manifest(writer, manifest),
         {:ok, observations} <-
           collect(manifest["obligations"], fn obligation ->
             observation(writer, obligation, observer)
           end),
         observations = Enum.reject(observations, &is_nil/1),
         {:ok, fences} <- fences(writer, manifest),
         bundle = %{
           "schema_version" => 1,
           "manifest" => manifest,
           "admission_fence" => %{
             "reference" => manifest["admission_fence_ref"],
             "subject" => manifest["subject"],
             "manifest_digest" => manifest["manifest_digest"],
             "exclusive" => true,
             "revision" => 1,
             "producer_ref" => "sigma-child-host"
           },
           "inventory" => %{
             "manifest_digest" => manifest["manifest_digest"],
             "revision" => 1,
             "producer_ref" => "sigma-child-host",
             "complete" => true,
             "obligations" => manifest["obligations"]
           },
           "observations" => observations,
           "run_fences" => fences,
           "policy_records" => %{},
           "archives" => %{},
           "artifacts" => %{}
         },
         ref = "closure-evidence:" <> Evidence.digest(bundle),
         :ok <- LifetimeRecovery.put_evidence(writer, ref, bundle) do
      Reconciliation.reconcile(LifetimeRecovery.configuration(writer), %{
        "schema_version" => 1,
        "receipt_id" => id,
        "expected_revision" => revision,
        "subject" => manifest["subject"],
        "evidence_ref" => ref
      })
    end
  end

  defp observation(writer, obligation, observer) do
    reference = "observation:" <> obligation["obligation_id"]

    case LifetimeRecovery.load_evidence(writer, reference) do
      {:ok, observation} ->
        {:ok, observation}

      {:error, %Error{class: :not_found}} ->
        persist_observation(writer, reference, obligation, observer.(obligation))

      {:error, _} = error ->
        error
    end
  end

  defp persist_observation(_writer, _reference, _obligation, :pending), do: {:ok, nil}

  defp persist_observation(writer, reference, obligation, result) do
    with {:ok, result, source, metadata} <- observation_result(result),
         observation = %{
           "observation_id" => reference,
           "observation_revision" => 1,
           "obligation_id" => obligation["obligation_id"],
           "identity" => obligation["identity"],
           "result" => result,
           "source_ref" => source,
           "observed_at_unix_ms" => System.system_time(:millisecond)
         },
         observation = Map.merge(observation, metadata),
         :ok <- LifetimeRecovery.put_evidence(writer, reference, observation) do
      {:ok, observation}
    end
  end

  defp observation_result({:ok, result, source}), do: {:ok, result, source, %{}}
  defp observation_result({:ok, result, source, metadata}), do: {:ok, result, source, metadata}
  defp observation_result(error), do: error

  defp observe(writer, _manifest, %{"kind" => "executor", "identity" => identity}) do
    with {:ok, _} <- LifetimeRecovery.executor(writer, identity),
         do: {:ok, "stopped", "executor-down:" <> Evidence.digest(identity)}
  end

  defp observe(writer, manifest, %{"kind" => "provider", "identity" => identity}) do
    ref = Enum.find(manifest["run_refs"], &(&1["run_id"] == identity["run_id"]))

    with true <- is_map(ref),
         {:ok, {Store, store}} <- LifetimeRecovery.runtime_store(writer, ref["store_ref"]),
         {:ok, %{status: :stopped}} <-
           Store.provider_lifecycle(store, %{
             run_id: identity["run_id"],
             incarnation: identity["incarnation"],
             step_id: identity["step_id"],
             attempt_id: identity["attempt_id"]
           }) do
      {:ok, "stopped", "provider-down:" <> Evidence.digest(identity)}
    else
      {:error, _} = error -> error
      _ -> fail("provider shutdown observation is unavailable")
    end
  end

  defp observe(writer, _manifest, %{
         "kind" => "host_component",
         "identity" => %{"component" => "async_hooks", "store_ref" => ref, "host" => identity}
       }) do
    with {:ok, {Store, store}} <- LifetimeRecovery.runtime_store(writer, ref),
         {:ok, ledger} <- Store.host_retirement(store, :all),
         host when is_map(host) <-
           Enum.find_value(ledger.hosts, fn {_key, host} ->
             {:ok, actual} = Evidence.public(host.identity)
             if actual == identity, do: host
           end),
         %{status: :confirmed} <- host.async_hooks,
         true <-
           Enum.all?(host.bindings, fn {_key, binding} ->
             host.native[{binding.native_owner_id, binding.native_session_incarnation}] == %{
               status: :confirmed,
               owner_id: binding.native_owner_id
             }
           end) do
      {:ok, "closed", "async-hooks:" <> Evidence.digest(identity)}
    else
      {:error, _} = error -> error
      _ -> fail("child async-hook closure is unavailable")
    end
  end

  defp observe(writer, _manifest, %{"identity" => %{"subject" => subject} = identity}) do
    with {:ok, receipt} <- LifetimeRecovery.receipt_for(writer, subject),
         {:ok, _} <-
           Reconciliation.load_confirmed(
             LifetimeRecovery.configuration(writer),
             receipt["receipt_id"],
             subject,
             identity["manifest_digest"]
           ) do
      {:ok, "closed", receipt["receipt_id"]}
    end
  end

  defp observe(writer, manifest, %{"kind" => "tool", "identity" => identity}) do
    reference =
      Enum.find(manifest["run_refs"], fn reference ->
        reference["run_id"] == identity["run_id"] and
          reference["original_incarnation"] == identity["incarnation"]
      end)

    with true <- is_map(reference),
         {:ok, {Store, store}} <- LifetimeRecovery.runtime_store(writer, reference["store_ref"]),
         {:ok, %{run: run}} <- Store.load(store, identity["run_id"]),
         [proof] <-
           run
           |> get_in([:outcome, "cleanup", "evidence"])
           |> retirement_records()
           |> Enum.filter(fn proof ->
             is_map(proof["identity"]) and
               Enum.all?(identity, fn {key, value} -> proof["identity"][key] === value end)
           end)
           |> Enum.uniq(),
         {:ok, ^proof} <- Evidence.public(proof),
         ref = "effect-retirement:" <> Evidence.digest(proof),
         :ok <- LifetimeRecovery.put_evidence(writer, ref, proof) do
      # The public reconciler validates the typed proof against the original
      # invocation, Session generation and any enclosing Code Mode obligations.
      {:ok, "closed", ref, %{"effect_retirement_ref" => ref}}
    else
      {:error, _} = error -> error
      _ -> fail("lifetime has no exact tool retirement evidence")
    end
  end

  defp observe(_writer, _manifest, _obligation),
    do: fail("lifetime has an unobserved obligation")

  defp retirement_records(%{"record_type" => type} = record)
       when type in [
              "native_plugin_wait_retirement",
              "native_clock_wait_retirement",
              "resource_scope_retirement",
              "event_request_retirement",
              "code_mode_retirement"
            ],
       do: [record]

  defp retirement_records(map) when is_map(map),
    do: map |> Map.values() |> Enum.flat_map(&retirement_records/1)

  defp retirement_records(list) when is_list(list), do: Enum.flat_map(list, &retirement_records/1)
  defp retirement_records(_value), do: []

  defp fences(writer, manifest) do
    manifest["run_refs"]
    |> Enum.reduce_while({:ok, []}, fn reference, {:ok, all} ->
      with {:ok, {Store, store}} <-
             LifetimeRecovery.runtime_store(writer, reference["store_ref"]),
           {:ok, items} <- Store.recovery_fences(store, reference["run_id"]) do
        {:cont, {:ok, Enum.uniq(all ++ items)}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp collect(values, callback) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case callback.(value) do
        {:ok, item} -> {:cont, {:ok, acc ++ [item]}}
        error -> {:halt, error}
      end
    end)
  end

  defp fail(message), do: {:error, Error.new(:unknown_outcome, message)}
end
