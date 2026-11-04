defmodule Sigma.Agent.Backplane.LifetimeEvidence do
  @moduledoc """
  Observation-only lifetime reconciliation for future root and child admissions.

  Public Registry, Session and manager manifests remain independent of historical
  outcomes. Only actual executor/Provider exits and confirmed host component facts
  satisfy obligations. No archive is exported, imported or continued.
  """

  alias Backplane.AgentRuntime.Codex.{MultiAgent, Reconciliation, ResourceRegistry, Session}
  alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence
  alias Backplane.AgentRuntime.Error
  alias Sigma.Agent.Backplane.{LifetimeRecovery, RunRecovery, Store}

  def capture_session(%{recovery: nil}), do: :ok
  def capture_session(%{binding: nil}), do: :ok

  def capture_session(%{recovery: %{writer: writer}, binding: binding}) do
    with {:ok, registry} <-
           ResourceRegistry.recovery_manifest(binding.resource_registry, binding.owner_id),
         {:ok, _} <-
           ResourceRegistry.recovery_closed(binding.resource_registry, binding.owner_id),
         {:ok, registry_receipt} <-
           seal(writer, registry, fn _ -> {:ok, "closed", "public-registry-close"} end),
         {:ok, registry_ack} <-
           ResourceRegistry.reconcile_owner(
             binding.resource_registry,
             binding.owner_id,
             registry_receipt["receipt_id"]
           ),
         :ok <-
           LifetimeRecovery.put_evidence(
             writer,
             "registry_owner-ack:" <> registry_receipt["receipt_digest"],
             registry_ack
           ),
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
        case seal(writer, manifest, &observe(writer, manifest, &1)) do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
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

  defp with_writer(transcript, header, fun) do
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
        with {:ok, result, source, metadata} <- observation_result(observer.(obligation)),
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

      {:error, _} = error ->
        error
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
