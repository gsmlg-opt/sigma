defmodule Sigma.Agent.Backplane.Store do
  @moduledoc """
  Durable, file-backed sidecar for Backplane runtime snapshots.

  Each acknowledged transition is written as one trusted external-term record.
  A store process serializes compare-and-set operations for one absolute directory
  and is registered locally in `Sigma.Agent.RepositoryRegistry`. This provides a
  single-writer boundary on one BEAM node; it is not a distributed lock.

  Writes use a temporary file in the same directory, sync that file, and rename
  it over the committed record. The acknowledgement therefore follows file-data
  sync and atomic same-filesystem rename. The directory itself is not synced, so
  this module does not claim survival of every rename across sudden power loss.

  Runtime records are separate from Sigma JSONL transcripts. Recovery loads the
  last acknowledged snapshot and never dispatches or replays an outbox mutation.

  Before reading external terms, the writer loads the fixed deployed protocol
  and host modules so safe decoding also works in a fresh BEAM. This loads code,
  not applications, and never derives module names or atoms from stored records.
  """

  use GenServer
  require Logger

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Store, as: RuntimeStore
  alias Sigma.Agent.Backplane.{HostRetirement, ProviderLifecycle, RecoveryJournal}

  @behaviour RuntimeStore

  @record_keys [:run, :revision, :transition, :effects, :outbox, :incarnation]
  @record_applications [
    :backplane_agent_runtime,
    :backplane_ai_protocol,
    :backplane_mcp_protocol,
    :backplane_skill_protocol,
    :backplane_plugin_protocol,
    :sigma_agent,
    :sigma_ai,
    :sigma_coding,
    :sigma_protocol
  ]

  defmodule FileSystem do
    @moduledoc false

    def ensure_dir(path), do: ensure_dir(nil, path)

    def ensure_dir(_context, path) do
      with :ok <- File.mkdir_p(path),
           :ok <- File.chmod(path, 0o700) do
        :ok
      end
    end

    def read(path), do: read(nil, path)
    def read(_context, path), do: File.read(path)

    def write_atomic(path, bytes), do: write_atomic(nil, path, bytes)

    def write_atomic(_context, path, bytes) when is_binary(bytes) do
      temporary =
        path <>
          ".tmp-#{System.unique_integer([:positive, :monotonic])}-#{inspect(make_ref())}"

      result =
        with {:ok, file} <-
               :file.open(String.to_charlist(temporary), [:write, :binary, :raw, :exclusive]),
             :ok <- protect_temporary(file, temporary),
             :ok <- write_sync_close(file, bytes),
             :ok <- File.rename(temporary, path) do
          :ok
        end

      if result != :ok, do: File.rm(temporary)
      result
    end

    defp protect_temporary(file, path) do
      case File.chmod(path, 0o600) do
        :ok ->
          :ok

        {:error, _} = error ->
          :file.close(file)
          error
      end
    end

    defp write_sync_close(file, bytes) do
      result =
        with :ok <- :file.write(file, bytes),
             :ok <- :file.sync(file) do
          :ok
        end

      close_result = :file.close(file)

      case {result, close_result} do
        {:ok, :ok} -> :ok
        {{:error, _} = error, _} -> error
        {:ok, {:error, _} = error} -> error
      end
    end
  end

  @impl RuntimeStore
  def mode, do: :durable

  @impl RuntimeStore
  def capabilities do
    %{
      expected_revision: true,
      transition_events: true,
      outbox_intents: true,
      recovery_records: true,
      artifact_references: true,
      atomic_transition_outbox: true,
      incarnation_fencing: true
    }
  end

  @impl RuntimeStore
  def new(_incarnation) do
    {:error, Error.new(:validation, "durable runtime store requires open(path: absolute_path)")}
  end

  @spec open(keyword()) :: GenServer.on_start() | {:error, Error.t()}
  def open(opts) when is_list(opts) do
    case start_link(opts) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      result -> result
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start() | {:error, Error.t()}
  def start_link(opts) when is_list(opts) do
    with {:ok, path} <- absolute_path(opts),
         {:ok, filesystem} <- filesystem(opts),
         :ok <- prepare_directory(filesystem, path) do
      GenServer.start_link(__MODULE__, {path, filesystem}, name: via(path))
    end
  end

  @doc "Revalidates the directory; records are read from disk on every operation."
  @spec reload(GenServer.server()) :: {:ok, pid()} | {:error, Error.t()}
  def reload(context), do: GenServer.call(context, :reload, :infinity)

  @doc "Records an exact host/native Session binding before admitting its run."
  def register_host_binding(context, binding),
    do: GenServer.call(context, {:register_host_binding, binding}, :infinity)

  @doc "Persists one actual confirmed host component without changing Runtime snapshots."
  def record_host_retirement(context, identity, component, confirmation),
    do: GenServer.call(context, {:host_retirement, identity, component, confirmation}, :infinity)

  @doc "Reads exact binding retirement, or the private versioned ledger with :all."
  def host_retirement(context, binding),
    do: GenServer.call(context, {:host_retirement, binding}, :infinity)

  @doc "Registers this actual provider worker before the Provider adapter starts its request."
  def observe_provider(context, identity),
    do: GenServer.call(context, {:observe_provider, identity}, :infinity)

  @doc "Reads observed worker lifecycle facts, independently of Runtime settlement."
  def provider_lifecycle(context, identity),
    do: GenServer.call(context, {:provider_lifecycle, identity}, :infinity)

  @doc "Retries only persistence of already observed provider termination facts."
  def flush_provider_lifecycle(context),
    do: GenServer.call(context, :flush_provider_lifecycle, :infinity)

  @doc "Requires durable termination observations before retiring their live host."
  def confirm_provider_shutdown(context),
    do: GenServer.call(context, :confirm_provider_shutdown, :infinity)

  @doc "Reads prospective public Store fence provenance without changing the run."
  def recovery_fences(context, run_id),
    do: GenServer.call(context, {:recovery_fences, run_id}, :infinity)

  @doc "Reads the exact atomically committed command journal, without replaying it."
  def recovery_journal(context, run_id),
    do: GenServer.call(context, {:recovery_journal, run_id}, :infinity)

  @doc "Drains accepted commits and confirms normal retirement before moving runtime files."
  def retire(context) do
    monitor = Process.monitor(context)

    result =
      try do
        GenServer.call(context, :retire, :infinity)
      catch
        :exit, reason -> {:exit, reason}
      end

    case result do
      {:error, _} = error ->
        Process.demonitor(monitor, [:flush])
        error

      _ ->
        receive do
          {:DOWN, ^monitor, :process, ^context, reason} ->
            case {result, reason} do
              {:ok, :normal} -> :ok
              {{:exit, {:normal, _}}, :normal} -> :ok
              {{:exit, {:noproc, _}}, :noproc} -> :ok
              {{:exit, cause}, _} -> {:error, retirement_error(cause)}
              {_, cause} -> {:error, retirement_error(cause)}
            end
        end
    end
  end

  defp retirement_error(cause),
    do: Error.new(:unknown_outcome, "runtime writer retirement is unconfirmed", cause: cause)

  @impl RuntimeStore
  def load(context, run_id, opts \\ []) when is_list(opts) do
    GenServer.call(context, {:load, run_id}, :infinity)
  end

  @impl RuntimeStore
  def store(context, record, meta) when is_map(record) and is_map(meta) do
    with {:ok, %{stage: stage}} <- RuntimeStore.stage(__MODULE__, context, record, meta),
         {:ok, result} <- commit(context, Map.put(stage, :recovery_command, meta[:command])) do
      {:ok, Map.put(result, :outbox, stage.outbox)}
    end
  end

  @impl RuntimeStore
  def acknowledge_commit(context, stage, meta) when is_map(stage) do
    commit(context, Map.put(stage, :recovery_command, meta[:command]))
  end

  @impl RuntimeStore
  def fence(context, run_id, expected_revision, current_incarnation, next_incarnation)
      when is_integer(expected_revision) and expected_revision >= 0 and
             is_integer(current_incarnation) and current_incarnation >= 0 and
             is_integer(next_incarnation) and next_incarnation > current_incarnation do
    GenServer.call(
      context,
      {:fence, run_id, expected_revision, current_incarnation, next_incarnation},
      :infinity
    )
  end

  def fence(_context, _run_id, _expected_revision, _current_incarnation, _next_incarnation) do
    {:error, Error.new(:validation, "invalid runtime incarnation fence")}
  end

  @impl GenServer
  def init({path, filesystem}) do
    with :ok <- load_record_schema() do
      {:ok,
       %{
         path: path,
         filesystem: filesystem,
         provider_observer:
           "provider-observer-" <> Base.url_encode64(:crypto.strong_rand_bytes(18)),
         provider_monitors: %{},
         provider_pending: %{}
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp load_record_schema do
    with {:ok, modules} <- record_modules(),
         :ok <- Code.ensure_all_loaded(Enum.uniq(modules)) do
      :ok
    else
      {:error, reason} -> {:error, {:runtime_store_schema_unavailable, reason}}
    end
  end

  defp record_modules do
    Enum.reduce_while(@record_applications, {:ok, []}, fn app, {:ok, modules} ->
      case Application.load(app) do
        result when result == :ok or result == {:error, {:already_loaded, app}} ->
          case Application.spec(app, :modules) do
            [_ | _] = declared -> {:cont, {:ok, declared ++ modules}}
            _ -> {:halt, {:error, {:missing_application_modules, app}}}
          end

        {:error, reason} ->
          {:halt, {:error, {:application_load_failed, app, reason}}}
      end
    end)
  end

  defp prepare_directory(filesystem, path) do
    case fs(filesystem, :ensure_dir, [path]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:runtime_store_open_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call(:retire, _from, state) do
    {result, state} = state |> drain_provider_downs() |> flush_provider_pending()

    cond do
      result != :ok ->
        {:reply, result, state}

      map_size(state.provider_monitors) > 0 ->
        {:reply, {:error, retirement_error(:provider_workers_still_observed)}, state}

      true ->
        {:stop, :normal, :ok, state}
    end
  end

  def handle_call(:reload, _from, state) do
    case fs(state.filesystem, :ensure_dir, [state.path]) do
      :ok -> {:reply, {:ok, self()}, state}
      {:error, reason} -> {:reply, storage_error("runtime store reload failed", reason), state}
    end
  end

  def handle_call({:load, run_id}, _from, state) do
    {:reply, read_snapshot(state, run_id), state}
  end

  def handle_call({:recovery_journal, run_id}, _from, state) do
    result =
      with {:ok, record, journal} <- read_record(state, run_id),
           do: RecoveryJournal.read(journal, record)

    {:reply, result, state}
  end

  def handle_call({:register_host_binding, binding}, _from, state) do
    result = update_host_retirement(state, &HostRetirement.register(&1, binding))
    {:reply, result, state}
  end

  def handle_call({:host_retirement, identity, component, confirmation}, _from, state) do
    result =
      update_host_retirement(state, &HostRetirement.record(&1, identity, component, confirmation))

    {:reply, result, state}
  end

  def handle_call({:host_retirement, binding}, _from, state) do
    result =
      with {:ok, ledger} <- read_host_retirement(state),
           do: HostRetirement.lookup(ledger, binding)

    {:reply, result, state}
  end

  def handle_call({:observe_provider, identity}, {worker, _tag}, state) do
    state = drain_provider_downs(state)

    case Enum.find(state.provider_monitors, fn {_ref, item} ->
           item.identity == identity and item.worker == worker
         end) do
      {_ref, _item} ->
        {:reply, :ok, state}

      nil ->
        result =
          with :ok <- ProviderLifecycle.validate_identity(identity),
               {:ok, %{run: run}} <- read_snapshot(state, identity.run_id),
               true <-
                 run.incarnation == identity.incarnation and run.active_provider == identity,
               do:
                 update_provider_lifecycle(
                   state,
                   &ProviderLifecycle.observe(&1, identity, state.provider_observer)
                 )

        case result do
          :ok ->
            ref = Process.monitor(worker)
            item = %{identity: identity, worker: worker}

            {:reply, :ok,
             %{state | provider_monitors: Map.put(state.provider_monitors, ref, item)}}

          false ->
            {:reply, conflict("provider observation does not match its active Runtime attempt"),
             state}

          error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:provider_lifecycle, identity}, _from, state) do
    state = drain_provider_downs(state)

    result =
      with :ok <- provider_pending_result(state, identity),
           {:ok, ledger} <- read_provider_lifecycle(state),
           do: ProviderLifecycle.lookup(ledger, identity)

    {:reply, result, state}
  end

  def handle_call(:flush_provider_lifecycle, _from, state) do
    {result, state} = state |> drain_provider_downs() |> flush_provider_pending()
    {:reply, result, state}
  end

  def handle_call(:confirm_provider_shutdown, _from, state) do
    {flushed, state} = state |> drain_provider_downs() |> flush_provider_pending()

    result =
      with :ok <- flushed,
           {:ok, ledger} <- read_provider_lifecycle(state) do
        if map_size(state.provider_monitors) == 0 and
             Enum.all?(ledger.attempts, fn {_identity, entry} -> entry.status == :stopped end),
           do: :ok,
           else: {:error, retirement_error(:provider_termination_unconfirmed)}
      end

    {:reply, result, state}
  end

  def handle_call({:recovery_fences, run_id}, _from, state) do
    result =
      with {:ok, snapshot} <- read_snapshot(state, run_id),
           {:ok, fences} <- read_recovery_fences(state),
           do:
             {:ok,
              Enum.filter(
                fences,
                &(&1["run_id"] == run_id and &1["to_incarnation"] <= snapshot.run.incarnation)
              )}

    {:reply, result, state}
  end

  def handle_call({:commit, stage}, _from, state) do
    {:reply, persist_stage(state, stage), state}
  end

  def handle_call(
        {:fence, run_id, expected_revision, current_incarnation, next_incarnation},
        _from,
        state
      ) do
    result =
      with {:ok, snapshot, journal} <- read_record(state, run_id),
           :ok <- compare_fence(snapshot, expected_revision, current_incarnation) do
        revision = expected_revision + 1

        run =
          snapshot.run
          |> Map.put(:incarnation, next_incarnation)
          |> Map.put(:expected_revision, revision)

        fenced = %{snapshot | run: run, revision: revision, incarnation: next_incarnation}

        # Persist the exact CAS source first. A source alone is not a completed
        # fence: recovery exposes it only if the authoritative snapshot reached
        # its target. Ordinary commits cannot advance incarnations. This keeps
        # evidence recoverable if the final snapshot acknowledgement is lost.
        with :ok <-
               prepare_recovery_fence(
                 state,
                 run_id,
                 expected_revision,
                 current_incarnation,
                 next_incarnation
               ),
             {:ok, journal} <-
               RecoveryJournal.append(journal, snapshot, fenced, :fence),
             :ok <- write_snapshot(state, run_id, fenced, journal) do
          {:ok, %{revision: revision, run: run}}
        end
      end

    {:reply, result, state}
  end

  defp read_recovery_fences(state) do
    case fs(state.filesystem, :read, [Path.join(state.path, "recovery-fences.etf")]) do
      {:ok, bytes} ->
        case :erlang.binary_to_term(bytes, [:safe]) do
          %{version: 1, fences: fences} when is_list(fences) -> {:ok, fences}
          _ -> malformed_record()
        end

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        storage_error("recovery fence read failed", reason)
    end
  rescue
    ArgumentError -> malformed_record()
  end

  defp prepare_recovery_fence(state, run_id, revision, current, next) do
    fence = %{
      "run_id" => run_id,
      "from_incarnation" => current,
      "to_incarnation" => next,
      "from_revision" => revision,
      "to_revision" => revision + 1,
      "source_ref" =>
        "sigma-store-fence:" <>
          Base.url_encode64(
            :crypto.hash(:sha256, :erlang.term_to_binary({run_id, revision, current, next})),
            padding: false
          )
    }

    with {:ok, fences} <- read_recovery_fences(state) do
      if fence in fences do
        :ok
      else
        case fs(state.filesystem, :write_atomic, [
               Path.join(state.path, "recovery-fences.etf"),
               :erlang.term_to_binary(%{version: 1, fences: fences ++ [fence]})
             ]) do
          :ok -> :ok
          {:error, reason} -> storage_error("recovery fence source commit failed", reason)
        end
      end
    end
  end

  defp commit(context, stage), do: GenServer.call(context, {:commit, stage}, :infinity)

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _worker, reason}, state) do
    {:noreply, provider_down(state, ref, reason)}
  end

  @impl GenServer
  def terminate(_reason, state) do
    {result, _state} = state |> drain_provider_downs() |> flush_provider_pending()

    if result != :ok,
      do: Logger.error("Provider lifecycle receipt persistence failed: #{inspect(result)}")

    :ok
  end

  defp drain_provider_downs(state) do
    monitors = state.provider_monitors

    receive do
      {:DOWN, ref, :process, _worker, reason} when is_map_key(monitors, ref) ->
        state |> provider_down(ref, reason) |> drain_provider_downs()
    after
      0 -> state
    end
  end

  defp provider_down(state, ref, reason) do
    case Map.pop(state.provider_monitors, ref) do
      {nil, _} ->
        state

      {%{identity: identity}, monitors} ->
        state = %{state | provider_monitors: monitors}
        fact = %{identity: identity, exit_kind: provider_exit_kind(reason)}
        key = ProviderLifecycle.key(identity)

        case persist_provider_down(state, fact) do
          :ok ->
            state

          error ->
            %{state | provider_pending: Map.put(state.provider_pending, key, {fact, error})}
        end
    end
  end

  defp provider_exit_kind(:normal), do: :normal
  defp provider_exit_kind(:shutdown), do: :shutdown
  defp provider_exit_kind({:shutdown, _}), do: :shutdown
  defp provider_exit_kind(:killed), do: :killed
  defp provider_exit_kind(_), do: :other

  defp persist_provider_down(state, fact) do
    update_provider_lifecycle(
      state,
      &ProviderLifecycle.stopped(
        &1,
        fact.identity,
        state.provider_observer,
        fact.exit_kind
      )
    )
  end

  defp provider_pending_result(%{provider_pending: pending}, identity) do
    case if(identity == :all, do: Enum.at(pending, 0), else: Map.get(pending, identity)) do
      nil -> :ok
      {_key, {_fact, error}} when identity == :all -> error
      {_fact, error} -> error
    end
  end

  defp flush_provider_pending(state) do
    Enum.reduce_while(state.provider_pending, {:ok, state}, fn {key, {fact, _error}},
                                                               {:ok, state} ->
      case persist_provider_down(state, fact) do
        :ok ->
          {:cont, {:ok, %{state | provider_pending: Map.delete(state.provider_pending, key)}}}

        error ->
          {:halt,
           {error,
            %{state | provider_pending: Map.put(state.provider_pending, key, {fact, error})}}}
      end
    end)
  end

  defp read_provider_lifecycle(state) do
    case fs(state.filesystem, :read, [provider_lifecycle_path(state)]) do
      {:ok, bytes} -> ProviderLifecycle.decode(bytes)
      {:error, :enoent} -> {:ok, ProviderLifecycle.new()}
      {:error, cause} -> storage_error("provider lifecycle read failed", cause)
    end
  end

  defp update_provider_lifecycle(state, update) do
    with {:ok, ledger} <- read_provider_lifecycle(state),
         {:ok, next, changed} <- update.(ledger) do
      case changed do
        :unchanged ->
          :ok

        :changed ->
          case fs(state.filesystem, :write_atomic, [
                 provider_lifecycle_path(state),
                 :erlang.term_to_binary(next, compressed: 6)
               ]) do
            :ok -> :ok
            {:error, cause} -> storage_error("provider lifecycle commit failed", cause)
          end
      end
    end
  end

  defp provider_lifecycle_path(state), do: Path.join(state.path, "provider-lifecycle.etf")

  defp persist_stage(state, stage) do
    with :ok <- validate_stage(stage),
         {:ok, current, journal} <- current_record(state, stage.run.run_id),
         :ok <- compare_stage(current, stage),
         snapshot = Map.take(stage, @record_keys),
         :ok <- validate_serializable(snapshot),
         {:ok, journal} <-
           RecoveryJournal.append(journal, current, snapshot, stage[:recovery_command]),
         :ok <- write_snapshot(state, stage.run.run_id, snapshot, journal) do
      {:ok, %{revision: stage.revision}}
    end
  end

  defp current_record(state, run_id) do
    case read_record(state, run_id) do
      {:ok, snapshot, journal} -> {:ok, snapshot, journal}
      {:error, %Error{class: :not_found}} -> {:ok, nil, nil}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp compare_stage(nil, %{revision: 1}), do: :ok

  defp compare_stage(
         %{revision: revision, run: %{incarnation: incarnation}},
         %{revision: next_revision, run: %{incarnation: incarnation}}
       )
       when next_revision == revision + 1,
       do: :ok

  defp compare_stage(_current, _stage),
    do: conflict("runtime revision or incarnation conflict")

  defp compare_fence(
         %{revision: expected_revision, run: %{incarnation: current_incarnation}},
         expected_revision,
         current_incarnation
       ),
       do: :ok

  defp compare_fence(_snapshot, _expected_revision, _current_incarnation),
    do: conflict("runtime incarnation fence conflict")

  defp validate_stage(%{
         run: %{run_id: run_id, expected_revision: revision, incarnation: incarnation},
         revision: revision,
         transition: transition,
         effects: effects,
         outbox: outbox,
         incarnation: incarnation
       })
       when not is_nil(run_id) and is_integer(revision) and revision > 0 and
              is_integer(incarnation) and incarnation >= 0 and is_map(transition) and
              is_list(effects) and is_list(outbox),
       do: :ok

  defp validate_stage(_stage),
    do: {:error, Error.new(:validation, "invalid runtime stage")}

  defp read_snapshot(state, run_id) do
    with {:ok, snapshot, _journal} <- read_record(state, run_id), do: {:ok, snapshot}
  end

  defp read_record(state, run_id) do
    case fs(state.filesystem, :read, [record_path(state.path, run_id)]) do
      {:ok, bytes} ->
        with {:ok, raw} <- decode_snapshot(bytes, run_id),
             journal = Map.get(raw, :recovery_journal),
             snapshot = Map.delete(raw, :recovery_journal),
             {:ok, snapshot} <- validate_snapshot(snapshot, run_id),
             do: {:ok, snapshot, journal}

      {:error, :enoent} ->
        {:error, Error.new(:not_found, "runtime run not found")}

      {:error, reason} ->
        storage_error("runtime record read failed", reason)
    end
  end

  defp decode_snapshot(bytes, _run_id) do
    try do
      case :erlang.binary_to_term(bytes, [:safe]) do
        snapshot when is_map(snapshot) ->
          if Map.keys(snapshot) -- (@record_keys ++ [:recovery_journal]) == [],
            do: {:ok, snapshot},
            else: malformed_record()

        _other ->
          malformed_record()
      end
    rescue
      ArgumentError -> malformed_record()
    end
  end

  defp validate_snapshot(
         %{
           run: %{run_id: run_id, expected_revision: revision, incarnation: incarnation},
           revision: revision,
           transition: transition,
           effects: effects,
           outbox: outbox,
           incarnation: incarnation
         } = snapshot,
         run_id
       )
       when is_integer(revision) and revision > 0 and is_integer(incarnation) and
              incarnation >= 0 and is_map(transition) and is_list(effects) and
              is_list(outbox) do
    if Map.keys(snapshot) |> Enum.sort() == Enum.sort(@record_keys) do
      {:ok, snapshot}
    else
      malformed_record()
    end
  end

  defp validate_snapshot(_snapshot, _run_id), do: malformed_record()

  defp validate_serializable(snapshot) do
    if serializable?(snapshot) do
      :ok
    else
      {:error, Error.new(:validation, "runtime record is not serializable")}
    end
  end

  defp serializable?(term) when is_pid(term) or is_port(term) or is_reference(term), do: false
  defp serializable?(term) when is_function(term), do: false

  defp serializable?(term) when is_map(term) do
    term
    |> Map.to_list()
    |> Enum.all?(fn {key, value} -> serializable?(key) and serializable?(value) end)
  end

  defp serializable?([]), do: true
  defp serializable?([head | tail]), do: serializable?(head) and serializable?(tail)

  defp serializable?(term) when is_tuple(term) do
    term |> Tuple.to_list() |> Enum.all?(&serializable?/1)
  end

  defp serializable?(_term), do: true

  defp write_snapshot(state, run_id, snapshot, journal) do
    snapshot = if journal, do: Map.put(snapshot, :recovery_journal, journal), else: snapshot

    with :ok <- validate_serializable(snapshot) do
      bytes = :erlang.term_to_binary(snapshot, compressed: 6)

      case fs(state.filesystem, :write_atomic, [record_path(state.path, run_id), bytes]) do
        :ok -> :ok
        {:error, reason} -> storage_error("runtime record commit failed", reason)
      end
    end
  end

  defp read_host_retirement(state) do
    case fs(state.filesystem, :read, [host_retirement_path(state)]) do
      {:ok, bytes} -> HostRetirement.decode(bytes)
      {:error, :enoent} -> {:ok, HostRetirement.new()}
      {:error, cause} -> storage_error("host retirement read failed", cause)
    end
  end

  defp update_host_retirement(state, update) do
    with {:ok, ledger} <- read_host_retirement(state),
         {:ok, next, changed} <- update.(ledger) do
      case changed do
        :unchanged ->
          :ok

        :changed ->
          bytes = :erlang.term_to_binary(next, compressed: 6)

          case fs(state.filesystem, :write_atomic, [host_retirement_path(state), bytes]) do
            :ok -> :ok
            {:error, cause} -> storage_error("host retirement commit failed", cause)
          end
      end
    end
  end

  defp host_retirement_path(state), do: Path.join(state.path, "host-retirement.etf")

  defp record_path(path, run_id) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(run_id))
    name = Base.url_encode64(digest, padding: false)
    Path.join(path, name <> ".runtime")
  end

  defp absolute_path(opts) do
    case Keyword.get(opts, :path) do
      path when is_binary(path) ->
        if Path.type(path) == :absolute do
          {:ok, Path.expand(path)}
        else
          {:error, Error.new(:validation, "runtime store path must be absolute")}
        end

      _other ->
        {:error, Error.new(:validation, "runtime store path must be absolute")}
    end
  end

  defp filesystem(opts) do
    case Keyword.get(opts, :filesystem, {FileSystem, nil}) do
      {module, context} when is_atom(module) -> {:ok, {module, context}}
      _other -> {:error, Error.new(:validation, "invalid runtime store filesystem")}
    end
  end

  defp fs({module, context}, operation, args), do: apply(module, operation, [context | args])

  defp via(path) do
    {:via, Registry, {Sigma.Agent.RepositoryRegistry, {:backplane_runtime_store, path}}}
  end

  defp conflict(message), do: {:error, Error.new(:resource_conflict, message)}

  defp malformed_record do
    {:error, Error.new(:malformed_result, "malformed runtime record")}
  end

  defp storage_error(message, reason) do
    {:error, Error.new(:execution_failure, message, cause: reason)}
  end
end
