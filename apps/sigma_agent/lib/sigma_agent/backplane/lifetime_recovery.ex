defmodule Sigma.Agent.Backplane.LifetimeRecovery do
  @moduledoc """
  Transcript-owned immutable evidence and public lifetime retirement receipts.

  The owning Subagents host closes admission and joins actual executors before
  sealing a generation. One writer serializes immutable facts and receipt CAS;
  file data is synced before atomic rename by the existing Store filesystem.
  Directory fsync and cross-node exclusion are not supplied. Missing historical
  observations remain missing after restart. No callback performs tool effects.
  """
  use GenServer
  require Logger

  @behaviour Backplane.AgentRuntime.Codex.Reconciliation.Adapter

  alias Backplane.AgentRuntime.{Conversation, Error}
  alias Backplane.AgentRuntime.Codex.Reconciliation.Evidence
  alias Sigma.Agent.Backplane.Store
  alias Sigma.Agent.Backplane.Store.FileSystem

  def start_link(opts) do
    path = Path.expand(Keyword.fetch!(opts, :transcript))
    name = {:via, Registry, {Sigma.Agent.RepositoryRegistry, {:lifetime_recovery, path}}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def locate(transcript),
    do:
      GenServer.whereis(
        {:via, Registry,
         {Sigma.Agent.RepositoryRegistry, {:lifetime_recovery, Path.expand(transcript)}}}
      )

  def register_root(pid, run_id, incarnation),
    do: GenServer.call(pid, {:root, run_id, incarnation}, :infinity)

  def manifest(pid, manifest), do: GenServer.call(pid, {:manifest, manifest}, :infinity)
  def manifests(pid), do: GenServer.call(pid, :manifests, :infinity)
  def stored_children(pid), do: GenServer.call(pid, :stored_children, :infinity)

  def store_ref(path, transcript) do
    if path == transcript <> ".runtime",
      do: "root",
      else: Path.relative_to(path, transcript <> ".subagents")
  end

  def configuration(pid), do: {__MODULE__, pid}
  def scope(pid), do: GenServer.call(pid, :scope)
  def ready(pid), do: GenServer.call(pid, :ready)

  @doc "Transfers an exact recovered Store to its linked child host for retirement."
  def handoff_store(pid, path, store) do
    # Link the new owner before the recovery writer releases its link. A failed
    # transfer leaves retirement with the original owner.
    Process.link(store)

    case GenServer.call(pid, {:handoff_store, Path.expand(path), store}, :infinity) do
      :ok ->
        {:ok, store}

      {:error, _} = error ->
        Process.unlink(store)
        error
    end
  catch
    :exit, cause ->
      # The writer may already have released ownership. Keep the caller's link
      # until its failed initialization exits rather than orphaning the Store.
      {:error,
       Error.new(:execution_failure, "recovered child Store handoff failed", cause: cause)}
  end

  @doc "Drains accepted writes and owned readers before the root transcript moves."
  def retire(pid) do
    monitor = Process.monitor(pid)

    result =
      try do
        GenServer.call(pid, :retire, :infinity)
      catch
        :exit, reason ->
          {:error, error("lifetime recovery retirement was not acknowledged: #{inspect(reason)}")}
      end

    case result do
      :ok ->
        receive do
          {:DOWN, ^monitor, :process, ^pid, :normal} ->
            :ok

          {:DOWN, ^monitor, :process, ^pid, reason} ->
            {:error, error("lifetime recovery retirement was abnormal: #{inspect(reason)}")}
        end

      {:error, _} = failure ->
        Process.demonitor(monitor, [:flush])
        failure
    end
  end

  def admit(pid, identity, request, options, metadata, configuration),
    do:
      GenServer.call(
        pid,
        {:admit, identity, request, options, metadata, configuration},
        :infinity
      )

  def observe_executor(pid, identity, name),
    do: GenServer.call(pid, {:observe, identity, name}, :infinity)

  def executor(pid, identity), do: GenServer.call(pid, {:executor, identity}, :infinity)

  def acknowledged(pid, manifest), do: GenServer.call(pid, {:acknowledged, manifest}, :infinity)

  def retire_executor(pid, identity) do
    with {:ok, process} <- GenServer.call(pid, {:executor_process, identity}, :infinity) do
      case process do
        :stopped ->
          :ok

        process when is_pid(process) ->
          case Conversation.status(process) do
            %{phase: phase, run: %{run_id: run, incarnation: incarnation}}
            when phase in [:terminal, :storage_failed, :recovery_required] ->
              if run == identity.run_id and incarnation == identity.incarnation,
                do: GenServer.stop(process, :normal),
                else: {:error, error("executor retirement identity differs")}

            _ ->
              {:error, error("executor has not stopped accepting work")}
          end
      end
    end
  catch
    :exit, cause ->
      {:error,
       Error.new(:unknown_outcome, "executor retirement was not acknowledged", cause: cause)}
  end

  def put_evidence(pid, reference, value),
    do: GenServer.call(pid, {:evidence, reference, value}, :infinity)

  def receipt_for(pid, subject), do: GenServer.call(pid, {:receipt_for, subject}, :infinity)

  @impl true
  def mode, do: :durable
  @impl true
  def load_evidence(pid, reference), do: GenServer.call(pid, {:evidence, reference}, :infinity)
  @impl true
  def runtime_store(pid, reference), do: GenServer.call(pid, {:store, reference}, :infinity)
  @impl true
  def load_recovery_journal(pid, reference) do
    with {:ok, {Store, store}} <- runtime_store(pid, reference["store_ref"]),
         do: Store.recovery_journal(store, reference["run_id"])
  end

  @impl true
  def load_receipt(pid, reference), do: GenServer.call(pid, {:receipt, reference}, :infinity)
  @impl true
  def compare_and_swap_receipt(pid, reference, revision, next),
    do: GenServer.call(pid, {:cas, reference, revision, next}, :infinity)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    path = Path.join(Keyword.fetch!(opts, :transcript) <> ".subagents", "lifetime-recovery.etf")
    header = Keyword.fetch!(opts, :root_header_id)
    root = Keyword.get(opts, :root_agent_id) || header

    empty = %{
      version: 1,
      root_header_id: header,
      root_agent_id: root,
      evidence: %{},
      receipts: %{},
      manifests: %{},
      stores: %{},
      executors: %{}
    }

    with {:ok, data} <- read(path, empty),
         true <-
           valid_data?(data) and data.root_header_id == header and
             (is_nil(opts[:root_agent_id]) or data.root_agent_id == root) do
      {:ok,
       %{
         path: path,
         data: data,
         stores: %{},
         monitors: %{},
         waiters: %{},
         pending_downs: %{},
         executor_processes: %{}
       }}
    else
      false -> {:stop, error("lifetime recovery root Writer identity differs")}
      {:error, cause} -> {:stop, cause}
    end
  end

  @impl true
  def handle_call(:scope, _from, state), do: {:reply, state.data.root_header_id, state}

  def handle_call(:manifests, _from, state), do: {:reply, {:ok, state.data.manifests}, state}

  def handle_call(:stored_children, _from, state) do
    children =
      for {_ref, %{"record_type" => "child_admission"} = item} <- state.data.evidence, do: item

    {:reply, {:ok, children}, state}
  end

  def handle_call({:manifest, manifest}, _from, state) do
    id = manifest["manifest_id"]

    case state.data.manifests[id] do
      nil ->
        reply_persist(
          state,
          %{state.data | manifests: Map.put(state.data.manifests, id, manifest)},
          :ok
        )

      ^manifest ->
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, error("sealed lifetime manifest changed")}, state}
    end
  end

  def handle_call({:root, run, incarnation}, _from, state) do
    reference = "root-admission:" <> run
    record = %{"run_id" => run, "incarnation" => incarnation, "store_ref" => "root"}

    case state.data.evidence[reference] do
      nil ->
        data = %{
          state.data
          | evidence: Map.put(state.data.evidence, reference, record),
            stores: Map.put(state.data.stores, "root", "root")
        }

        reply_persist(state, data, :ok)

      ^record ->
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, error("root admission changed")}, state}
    end
  end

  def handle_call(:ready, _from, state) do
    {result, state} = state |> drain_downs() |> flush_downs()
    {:reply, result, state}
  end

  def handle_call(:retire, _from, state) do
    {result, state} = state |> drain_downs() |> flush_downs()

    cond do
      result != :ok ->
        {:reply, result, state}

      map_size(state.monitors) > 0 ->
        {:reply, {:error, error("lifetime recovery still observes active executors")}, state}

      true ->
        case retire_stores(state) do
          {:ok, state} -> {:stop, :normal, :ok, state}
          {failure, state} -> {:reply, failure, state}
        end
    end
  end

  def handle_call({:admit, identity, request, options, metadata, configuration}, _from, state) do
    with {:ok, identity} <- Evidence.public(identity),
         {:ok, request} <- Evidence.public(request),
         {:ok, configuration} <- Evidence.public(configuration),
         {:ok, ceiling} <-
           Evidence.public(
             Keyword.get(options, :authority, %{})
             |> Map.take([:grants, :tool_revisions, :tool_bindings, :tool_revision])
           ),
         {:ok, host} <- Evidence.public(metadata.host_retirement),
         true <- is_map(host) do
      reference = "admission:" <> identity["attempt_id"]
      store_ref = Path.relative_to(metadata.backplane_store_path, Path.dirname(state.path))
      config_ref = "configuration:" <> Evidence.digest(configuration)
      ceiling_ref = "ceiling:" <> Evidence.digest(ceiling)
      inventory_ref = "inventory:" <> identity["attempt_id"]

      obligation =
        Evidence.obligation(
          "host_component",
          %{"component" => "async_hooks", "store_ref" => store_ref, "host" => host},
          inventory_ref
        )

      inventory = %{
        "schema_version" => 1,
        "record_type" => "child_inventory",
        "child_identity" => identity,
        "complete" => true,
        "producer_ref" => inventory_ref,
        "obligations" => [obligation]
      }

      admission = %{
        "schema_version" => 1,
        "record_type" => "child_admission",
        "child_identity" => identity,
        "store_ref" => store_ref,
        "config_ref" => config_ref,
        "authority_ceiling_ref" => ceiling_ref,
        "tool_profile" => Atom.to_string(request_profile(request)),
        "admission_receipt_ref" => "admission-receipt:" <> identity["attempt_id"],
        "child_request" => request,
        "configuration" => configuration,
        "authority_ceiling" => ceiling,
        "artifact_refs" => [],
        "inventory_ref" => inventory_ref
      }

      additions = %{
        reference => admission,
        config_ref => configuration,
        ceiling_ref => ceiling,
        inventory_ref => inventory
      }

      stores = %{
        store_ref => Path.relative_to(metadata.backplane_store_path, Path.dirname(state.path))
      }

      if immutable_additions?(state.data.evidence, additions) and
           immutable_additions?(state.data.stores, stores) do
        data = %{
          state.data
          | evidence: Map.merge(state.data.evidence, additions),
            stores: Map.merge(state.data.stores, stores)
        }

        case persist(state, data) do
          {:ok, next} -> {:reply, {:ok, reference}, next}
          {:error, cause} -> {:reply, {:error, cause}, state}
        end
      else
        {:reply, {:error, error("immutable child admission evidence changed")}, state}
      end
    else
      false ->
        {:reply, {:error, error("lifetime recovery requires its actual host Writer")}, state}

      {:error, cause} ->
        {:reply, {:error, cause}, state}
    end
  end

  def handle_call({:observe, identity, name}, _from, state) do
    key = executor_key(identity)

    case GenServer.whereis(name) do
      pid when is_pid(pid) ->
        if Map.has_key?(state.data.executors, key) do
          if Enum.any?(state.monitors, fn {_ref, item} -> item == key end),
            do: {:reply, :ok, state},
            else: {:reply, {:error, error("executor already has a lifecycle observation")}, state}
        else
          entry = %{
            status: :observing,
            run_id: identity.run_id,
            incarnation: identity.incarnation
          }

          case persist(state, %{state.data | executors: Map.put(state.data.executors, key, entry)}) do
            {:ok, next} ->
              ref = Process.monitor(pid)

              {:reply, :ok,
               %{
                 next
                 | monitors: Map.put(next.monitors, ref, key),
                   executor_processes: Map.put(next.executor_processes, key, pid)
               }}

            {:error, cause} ->
              {:reply, {:error, cause}, state}
          end
        end

      _ ->
        {:reply, {:error, error("actual child executor is unavailable")}, state}
    end
  end

  def handle_call({:executor_process, identity}, _from, state) do
    state = drain_downs(state)
    key = executor_key(identity)

    result =
      case {state.data.executors[key], state.executor_processes[key]} do
        {%{status: :stopped}, _} -> {:ok, :stopped}
        {%{status: :observing}, pid} when is_pid(pid) -> {:ok, pid}
        _ -> {:error, error("executor observation was lost or is missing")}
      end

    {:reply, result, state}
  end

  def handle_call({:acknowledged, manifest}, _from, state) do
    result =
      if actual_ack?(state.data.evidence, manifest),
        do: :ok,
        else: {:error, error("public lifetime acknowledgement is missing")}

    {:reply, result, state}
  end

  def handle_call({:executor, identity}, from, state) do
    key = executor_key(identity)
    {flushed, state} = state |> drain_downs() |> flush_downs()

    case {flushed, state.data.executors[key]} do
      {{:error, cause}, _} ->
        {:reply, {:error, cause}, state}

      {:ok, %{status: :stopped} = fact} ->
        {:reply, {:ok, fact}, state}

      {:ok, %{status: :observing}} ->
        if Enum.any?(state.monitors, fn {_ref, observed} -> observed == key end) do
          token = make_ref()
          Process.send_after(self(), {:executor_timeout, token}, 4_000)
          {:noreply, %{state | waiters: Map.put(state.waiters, token, {key, from})}}
        else
          {:reply, {:error, error("executor observation was lost before shutdown")}, state}
        end

      _ ->
        {:reply, {:error, error("executor shutdown observation is missing")}, state}
    end
  end

  def handle_call({:evidence, ref}, _from, state),
    do: {:reply, fetch(state.data.evidence, ref), state}

  def handle_call({:receipt, ref}, _from, state),
    do: {:reply, fetch(state.data.receipts, ref), state}

  def handle_call({:receipt_for, subject}, _from, state) do
    receipt = state.data.receipts |> Map.values() |> Enum.find(&(&1["subject"] == subject))
    {:reply, if(receipt, do: {:ok, receipt}, else: missing()), state}
  end

  def handle_call({:evidence, reference, value}, _from, state) do
    case Evidence.public(value) do
      {:ok, value} -> put_public_evidence(state, reference, value)
      error -> {:reply, error, state}
    end
  end

  def handle_call({:cas, ref, revision, next}, _from, state) do
    current = state.data.receipts[ref]

    if if(current, do: current["revision"], else: 0) == revision do
      reply_persist(
        state,
        %{
          state.data
          | receipts: Map.put(state.data.receipts, ref, next),
            evidence:
              Map.put(state.data.evidence, "receipt-version:" <> next["receipt_digest"], next)
        },
        {:ok, next}
      )
    else
      {:reply, {:error, Error.new(:resource_conflict, "child receipt revision differs")}, state}
    end
  end

  def handle_call({:store, ref}, _from, state) do
    case state.stores[ref] do
      %{pid: pid} ->
        if Process.alive?(pid),
          do: {:reply, {:ok, {Store, pid}}, state},
          else: open_store(state, ref)

      _ ->
        open_store(state, ref)
    end
  end

  def handle_call({:handoff_store, path, store}, _from, state) do
    reference = Path.relative_to(path, Path.dirname(state.path))

    case {state.data.stores[reference], state.stores[reference]} do
      {^reference, %{pid: ^store, owned?: true} = entry} ->
        if Process.alive?(store) do
          Process.unlink(store)
          entry = %{entry | owned?: false}
          {:reply, :ok, %{state | stores: Map.put(state.stores, reference, entry)}}
        else
          {:reply, {:error, error("recovered child Store exited before handoff")}, state}
        end

      _ ->
        {:reply, {:error, error("recovery writer does not own this child Store")}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state),
    do: {:noreply, executor_down(state, ref, reason)}

  def handle_info({:executor_timeout, token}, state) do
    case Map.pop(state.waiters, token) do
      {nil, _} ->
        {:noreply, state}

      {{_, from}, waiters} ->
        GenServer.reply(from, {:error, error("executor shutdown is unconfirmed")})
        {:noreply, %{state | waiters: waiters}}
    end
  end

  def handle_info({:EXIT, _pid, _cause}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    {flushed, state} = state |> drain_downs() |> flush_downs()

    if flushed != :ok,
      do:
        Logger.error(
          "Lifetime executor observation persistence is unconfirmed: #{inspect(flushed)}"
        )

    case retire_stores(state) do
      {:ok, _} ->
        :ok

      {{:error, cause}, _} ->
        Logger.error("Lifetime recovery reader retirement is unconfirmed: #{inspect(cause)}")
    end

    :ok
  end

  defp actual_ack?(evidence, manifest) do
    Enum.any?(evidence, fn
      {"receipt-version:" <> digest, receipt} ->
        receipt["receipt_digest"] == digest and receipt["subject"] == manifest["subject"] and
          receipt["manifest_digest"] == manifest["manifest_digest"] and
          receipt["retirement"] == "confirmed" and
          match?({:ok, _}, Evidence.validate_receipt(receipt)) and
          matching_ack?(evidence, receipt, digest)

      _ ->
        false
    end)
  end

  defp matching_ack?(evidence, receipt, digest) do
    subject = receipt["subject"]

    case {subject["kind"], evidence[subject["kind"] <> "-ack:" <> digest]} do
      {"session", ack} when is_map(ack) ->
        ack["status"] == "confirmed" and ack["owner_id"] == subject["owner_id"] and
          ack["receipt_ref"] == receipt["receipt_id"] and
          ack["receipt_revision"] == receipt["revision"]

      {kind, ack} when kind in ["child", "manager", "registry_owner"] and is_map(ack) ->
        identity =
          case kind do
            "child" -> ack["agent_id"] == subject["identity"]["agent_id"]
            "manager" -> ack["manager_id"] == subject["manager_id"]
            "registry_owner" -> ack["owner_id"] == subject["owner_id"]
          end

        id = ack["receipt_id"] || ack["receipt_ref"]
        revision = ack["revision"] || ack["receipt_revision"]

        ack["status"] == "confirmed" and identity and id == receipt["receipt_id"] and
          revision == receipt["revision"] and
          (is_nil(ack["receipt_digest"]) or ack["receipt_digest"] == digest)

      _ ->
        false
    end
  end

  defp put_public_evidence(state, reference, value) do
    case state.data.evidence[reference] do
      ^value ->
        {:reply, :ok, state}

      nil ->
        reply_persist(
          state,
          %{state.data | evidence: Map.put(state.data.evidence, reference, value)},
          :ok
        )

      _ ->
        {:reply, {:error, error("immutable child evidence changed")}, state}
    end
  end

  defp executor_down(state, ref, reason) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        state

      {key, monitors} ->
        state = %{state | executor_processes: Map.delete(state.executor_processes, key)}
        fact = Map.merge(state.data.executors[key], %{status: :stopped, reason: inspect(reason)})

        case persist(state, %{state.data | executors: Map.put(state.data.executors, key, fact)}) do
          {:ok, next} ->
            {ready, pending} =
              Enum.split_with(next.waiters, fn {_token, {item, _}} -> item == key end)

            Enum.each(ready, fn {_, {_, from}} -> GenServer.reply(from, {:ok, fact}) end)
            %{next | monitors: monitors, waiters: Map.new(pending)}

          {:error, cause} ->
            {ready, pending} =
              Enum.split_with(state.waiters, fn {_token, {item, _}} -> item == key end)

            Enum.each(ready, fn {_, {_, from}} -> GenServer.reply(from, {:error, cause}) end)

            %{
              state
              | monitors: monitors,
                waiters: Map.new(pending),
                pending_downs: Map.put(state.pending_downs, key, {fact, cause})
            }
        end
    end
  end

  defp open_store(state, ref) do
    case state.data.stores[ref] do
      nil ->
        {:reply, missing(), state}

      relative ->
        path =
          if relative == "root",
            do: String.replace_suffix(Path.dirname(state.path), ".subagents", ".runtime"),
            else: Path.join(Path.dirname(state.path), relative)

        if Path.type(relative) == :absolute do
          {:reply,
           {:error, error("lifetime recovery contains an unresolved legacy Store address")},
           state}
        else
          case Store.start_link(path: path) do
            {:ok, pid} ->
              {:reply, {:ok, {Store, pid}},
               %{state | stores: Map.put(state.stores, ref, %{pid: pid, owned?: true})}}

            {:error, {:already_started, pid}} ->
              {:reply, {:ok, {Store, pid}},
               %{state | stores: Map.put(state.stores, ref, %{pid: pid, owned?: false})}}

            {:error, cause} ->
              {:reply, {:error, cause}, state}
          end
        end
    end
  end

  defp reply_persist(state, data, response) do
    case persist(state, data) do
      {:ok, next} -> {:reply, response, next}
      {:error, cause} -> {:reply, {:error, cause}, state}
    end
  end

  defp persist(state, data) do
    if state.data == data do
      {:ok, state}
    else
      with :ok <- FileSystem.ensure_dir(Path.dirname(state.path)),
           :ok <- FileSystem.write_atomic(state.path, :erlang.term_to_binary(data)) do
        {:ok, %{state | data: data}}
      else
        {:error, cause} ->
          {:error, Error.new(:execution_failure, "lifetime recovery write failed", cause: cause)}
      end
    end
  end

  defp flush_downs(state) do
    Enum.reduce_while(state.pending_downs, {:ok, state}, fn {key, {fact, _original}},
                                                            {:ok, current} ->
      case persist(current, %{
             current.data
             | executors: Map.put(current.data.executors, key, fact)
           }) do
        {:ok, next} ->
          {:cont, {:ok, %{next | pending_downs: Map.delete(next.pending_downs, key)}}}

        {:error, cause} ->
          {:halt, {{:error, cause}, current}}
      end
    end)
  end

  defp drain_downs(state) do
    monitors = state.monitors

    receive do
      {:DOWN, ref, :process, _pid, reason} when is_map_key(monitors, ref) ->
        state |> executor_down(ref, reason) |> drain_downs()
    after
      0 -> state
    end
  end

  defp retire_stores(state) do
    Enum.reduce_while(state.stores, {:ok, state}, fn {ref, entry}, {:ok, current} ->
      result =
        if entry.owned? and Process.alive?(entry.pid),
          do: retire_store(entry.pid),
          else: :ok

      case result do
        :ok -> {:cont, {:ok, %{current | stores: Map.delete(current.stores, ref)}}}
        {:error, _} = failure -> {:halt, {failure, current}}
      end
    end)
  end

  defp retire_store(pid) do
    Store.retire(pid)
  catch
    :exit, cause ->
      {:error,
       Error.new(:unknown_outcome, "lifetime recovery Store retirement is unconfirmed",
         cause: cause
       )}
  end

  defp immutable_additions?(existing, additions) do
    Enum.all?(additions, fn {key, value} ->
      case Map.fetch(existing, key) do
        :error -> true
        {:ok, ^value} -> true
        _ -> false
      end
    end)
  end

  defp valid_data?(
         %{
           version: 1,
           root_header_id: header,
           root_agent_id: root,
           evidence: evidence,
           receipts: receipts,
           manifests: manifests,
           stores: stores,
           executors: executors
         } = data
       ) do
    map_size(data) == 8 and is_binary(header) and is_binary(root) and
      Enum.all?([evidence, receipts, manifests, stores, executors], &is_map/1)
  end

  defp valid_data?(_), do: false

  defp read(path, empty) do
    case File.read(path) do
      {:ok, bytes} ->
        {:ok, :erlang.binary_to_term(bytes, [:safe])}

      {:error, :enoent} ->
        {:ok, empty}

      {:error, cause} ->
        {:error, Error.new(:execution_failure, "lifetime recovery read failed", cause: cause)}
    end
  rescue
    ArgumentError -> {:error, error("lifetime recovery storage is malformed")}
  end

  defp request_profile(%{"profile" => "v1"}), do: :v1
  defp request_profile(_), do: :v2
  defp executor_key(%{run_id: run, incarnation: incarnation}), do: {run, incarnation}
  defp executor_key(%{"run_id" => run, "incarnation" => incarnation}), do: {run, incarnation}

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> missing()
    end
  end

  defp missing, do: {:error, Error.new(:not_found, "lifetime recovery evidence is unavailable")}
  defp error(message), do: Error.new(:unknown_outcome, message)
end
