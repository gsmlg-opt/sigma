defmodule Sigma.Agent.Backplane.GoalStore do
  @moduledoc """
  Durable local adapter for public Backplane thread Goal records.

  The caller supplies an absolute repository Goal directory and the immutable
  JSONL header ID as thread identity. File names are digests of that identity;
  renameable session names and model arguments never select a file path.

  Symbolic links in roots or ancestors are refused before directory creation,
  so lexical aliases cannot create separate CAS writers for the same directory.
  One registered process serializes CAS for each directory on this BEAM node.
  Records include the complete private snapshot and tombstone revision. Writes
  reuse `Sigma.Agent.Backplane.Store.FileSystem`: file data is synced before
  atomic rename; the parent directory is not synced. This is not a distributed
  lock or a guarantee against every power-loss scenario.

  This adapter neither creates Goals nor schedules their continuation. Session
  owners must reconcile runtime receipt outboxes before admitting fresh work.
  Pre-1.10.45 records acquire the two admission-ledger defaults only in memory;
  reads never rewrite their stored bytes or replace existing ledger values.
  """

  use GenServer, restart: :transient

  alias Backplane.AgentRuntime.{Error, Usage}
  alias Backplane.AgentRuntime.Goal.{State, Store}
  alias Sigma.Agent.Backplane.Store.FileSystem

  @behaviour Store

  @admission_fields ~w(runtime_receipt_counts admission_settlements)a
  @map_fields ~w(receipts invocations deliveries usage baselines usage_baselines usage_snapshots turns event_revisions)a ++
                @admission_fields

  def open(opts) do
    case start_link(opts) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      result -> result
    end
  end

  def start_link(opts) when is_list(opts) do
    with {:ok, path} <- absolute_path(opts),
         {:ok, filesystem} <- filesystem(opts) do
      GenServer.start_link(__MODULE__, {path, filesystem}, name: via(path))
    end
  end

  @impl Store
  def load(context, thread_id),
    do: GenServer.call(context, {:load, thread_id}, :infinity)

  @impl Store
  def compare_and_swap(context, thread_id, revision, goal_id, next),
    do: GenServer.call(context, {:cas, thread_id, revision, goal_id, next}, :infinity)

  @doc "Reads durable host hook gates independently of public Goal records and Runtime indexes."
  def host_admissions(context, thread_id),
    do: GenServer.call(context, {:host_admissions, thread_id}, :infinity)

  @doc "Commits one immutable admission gate or its forward-only host lifecycle observation."
  def put_host_admission(context, thread_id, entry),
    do: GenServer.call(context, {:put_host_admission, thread_id, entry}, :infinity)

  @doc "Imports the public fork snapshot into a fresh destination without changing its fields."
  def import_fork(context, thread_id, snapshot),
    do: GenServer.call(context, {:import_fork, thread_id, snapshot}, :infinity)

  @doc "Drains accepted operations and confirms normal writer retirement before file operations."
  def retire(path) do
    with {:ok, root} <- absolute_path(path: path) do
      case Registry.lookup(Sigma.Agent.RepositoryRegistry, {:backplane_goal_store, root}) do
        [] -> :ok
        [{pid, _}] -> retire_writer(pid)
      end
    end
  end

  defp retire_writer(pid) do
    monitor = Process.monitor(pid)

    result =
      try do
        GenServer.call(pid, :retire, :infinity)
      catch
        :exit, reason -> {:exit, reason}
      end

    receive do
      {:DOWN, ^monitor, :process, ^pid, reason} ->
        case {result, reason} do
          {:ok, :normal} -> :ok
          {{:exit, {:normal, _}}, :normal} -> :ok
          {{:exit, {:noproc, _}}, :noproc} -> :ok
          {{:exit, cause}, _} -> {:error, retirement_error(cause)}
          {_, cause} -> {:error, retirement_error(cause)}
        end
    end
  end

  defp retirement_error(cause),
    do: Error.new(:unknown_outcome, "Goal writer retirement is unconfirmed", cause: cause)

  @impl GenServer
  def init({path, filesystem}) do
    # Decode against deployed, fixed schemas even when this writer is the first
    # owner opened in a fresh BEAM. Never derive atoms/modules from stored bytes.
    with :ok <- Code.ensure_all_loaded([State, Backplane.AgentRuntime.Goal.Settlement, Usage]),
         :ok <- fs(filesystem, :ensure_dir, [path]) do
      {:ok, %{path: path, filesystem: filesystem}}
    else
      {:error, reason} -> {:stop, storage_error("goal store open failed", reason)}
    end
  end

  @impl GenServer
  def handle_call(:retire, _from, state), do: {:stop, :normal, :ok, state}

  def handle_call({:import_fork, thread_id, snapshot}, _from, state) do
    result =
      with :ok <- validate_thread(thread_id),
           :ok <- validate_record(snapshot, thread_id, :validation),
           {:ok, current} <- read_record(state, thread_id) do
        cond do
          current == snapshot ->
            {:ok, current}

          current.revision == 0 and current.goal == nil ->
            with :ok <- write_record(state, thread_id, snapshot), do: {:ok, snapshot}

          true ->
            error(:resource_conflict, "fork destination Goal already exists")
        end
      end

    {:reply, result, state}
  end

  def handle_call({:load, thread_id}, _from, state) do
    result = with :ok <- validate_thread(thread_id), do: read_record(state, thread_id)
    {:reply, result, state}
  end

  def handle_call({:host_admissions, thread_id}, _from, state),
    do: {:reply, read_host_admissions(state, thread_id), state}

  def handle_call({:put_host_admission, thread_id, entry}, _from, state) do
    result =
      with :ok <- validate_thread(thread_id),
           true <- valid_host_admission?(entry) or error(:validation, "invalid host admission"),
           {:ok, entries} <- read_host_admissions(state, thread_id) do
        token = entry.admission.reservation_token

        cond do
          entries[token] === entry ->
            :ok

          host_admission_transition?(entries[token], entry) ->
            ledger = %{
              version: 1,
              thread_id: thread_id,
              admissions: Map.put(entries, token, entry)
            }

            bytes = :erlang.term_to_binary(ledger, compressed: 6)

            case fs(state.filesystem, :write_atomic, [
                   host_admissions_path(state.path, thread_id),
                   bytes
                 ]) do
              :ok -> :ok
              {:error, cause} -> {:error, storage_error("host admission commit failed", cause)}
            end

          true ->
            error(:resource_conflict, "host admission observation conflicts")
        end
      end

    {:reply, result, state}
  end

  def handle_call({:cas, thread_id, revision, goal_id, next}, _from, state) do
    result =
      with :ok <- validate_thread(thread_id),
           :ok <- validate_cas(revision, goal_id, next),
           :ok <- validate_record(next, thread_id, :validation),
           {:ok, current} <- read_record(state, thread_id),
           :ok <- compare(current, revision, goal_id),
           committed = %{next | revision: revision + 1},
           :ok <- write_record(state, thread_id, committed) do
        {:ok, committed}
      end

    {:reply, result, state}
  end

  defp validate_cas(revision, goal_id, %{revision: revision})
       when is_integer(revision) and revision >= 0 and
              (is_nil(goal_id) or (is_binary(goal_id) and goal_id != "")),
       do: :ok

  defp validate_cas(_revision, _goal_id, _next),
    do: error(:validation, "invalid goal CAS revision or identity")

  defp compare(%{revision: revision, goal: goal}, revision, goal_id) do
    current_goal_id = if goal, do: goal.goal_id

    if current_goal_id == goal_id,
      do: :ok,
      else: error(:resource_conflict, "goal identity conflict")
  end

  defp compare(_current, _revision, _goal_id),
    do: error(:resource_conflict, "goal revision conflict")

  defp read_record(state, thread_id) do
    case fs(state.filesystem, :read, [record_path(state.path, thread_id)]) do
      {:ok, bytes} -> decode(bytes, thread_id)
      {:error, :enoent} -> State.new(thread_id, [])
      {:error, reason} -> {:error, storage_error("goal record read failed", reason)}
    end
  end

  defp read_host_admissions(state, thread_id) do
    with :ok <- validate_thread(thread_id) do
      case fs(state.filesystem, :read, [host_admissions_path(state.path, thread_id)]) do
        {:error, :enoent} ->
          {:ok, %{}}

        {:error, cause} ->
          {:error, storage_error("host admission read failed", cause)}

        {:ok, bytes} ->
          case :erlang.binary_to_term(bytes, [:safe]) do
            %{version: 1, thread_id: ^thread_id, admissions: entries} = ledger
            when is_map(entries) ->
              if Enum.sort(Map.keys(ledger)) == [:admissions, :thread_id, :version] and
                   Enum.all?(entries, fn {token, entry} ->
                     valid_host_admission?(entry) and entry.admission.reservation_token == token
                   end),
                 do: {:ok, entries},
                 else: error(:malformed_result, "malformed host admission ledger")

            _ ->
              error(:malformed_result, "malformed host admission ledger")
          end
      end
    end
  rescue
    ArgumentError -> error(:malformed_result, "malformed host admission ledger")
  end

  defp valid_host_admission?(
         %{admission: admission, stage: stage, settlement: settlement} = entry
       )
       when is_map(admission) do
    Enum.sort(Map.keys(entry)) == [:admission, :settlement, :stage] and
      Enum.sort(Map.keys(admission)) ==
        Enum.sort(~w(run_id turn_id incarnation host_generation reservation_token)a) and
      Enum.all?(
        [:run_id, :turn_id, :reservation_token],
        &(is_binary(admission[&1]) and admission[&1] != "")
      ) and
      is_integer(admission[:incarnation]) and admission.incarnation > 0 and serializable?(entry) and
      ((stage in [:hooks_pending, :runtime_released, :runtime_bound] and is_nil(settlement)) or
         (stage == :sealed and is_map(settlement) and
            Enum.sort(Map.keys(settlement)) == [:attestation, :reason]))
  end

  defp valid_host_admission?(_), do: false

  defp host_admission_transition?(nil, %{stage: :hooks_pending}), do: true

  defp host_admission_transition?(%{admission: admission, stage: previous}, %{
         admission: admission,
         stage: next
       }) do
    {previous, next} in [
      hooks_pending: :runtime_released,
      hooks_pending: :sealed,
      runtime_released: :runtime_bound
    ]
  end

  defp host_admission_transition?(_, _), do: false

  defp host_admissions_path(path, thread_id),
    do: record_path(path, thread_id) <> ".host-admissions"

  defp decode(bytes, thread_id) do
    record = bytes |> :erlang.binary_to_term([:safe]) |> legacy_defaults(thread_id)

    with :ok <- validate_record(record, thread_id, :malformed_result),
         do: {:ok, record}
  rescue
    ArgumentError -> error(:malformed_result, "malformed goal record")
  end

  defp legacy_defaults(record, thread_id) when is_map(record) do
    {:ok, defaults} = State.new(thread_id, [])
    legacy_keys = defaults |> Map.drop(@admission_fields) |> Map.keys() |> Enum.sort()

    if Enum.sort(Map.keys(record)) == legacy_keys,
      do: Map.merge(Map.take(defaults, @admission_fields), record),
      else: record
  end

  defp legacy_defaults(record, _thread_id), do: record

  defp validate_record(
         %{thread_id: thread_id, revision: revision, goal: goal} = record,
         thread_id,
         class
       )
       when is_integer(revision) and revision >= 0 do
    {:ok, defaults} = State.new(thread_id, [])

    valid? = Enum.sort(Map.keys(record)) == Enum.sort(Map.keys(defaults))

    if valid? and Enum.all?(@map_fields, &is_map(record[&1])) and
         valid_scalars?(record) and valid_goal?(goal, thread_id) and
         valid_usage?(record.usage) and serializable?(record),
       do: :ok,
       else: error(class, "malformed goal record or live capabilities")
  end

  defp validate_record(_record, _thread_id, class),
    do: error(class, "malformed goal record or thread identity")

  defp valid_goal?(nil, _thread_id), do: true

  defp valid_goal?(
         %{
           thread_id: thread_id,
           goal_id: id,
           objective: objective,
           status: status,
           token_budget: budget,
           tokens_used: tokens,
           time_used_seconds: seconds,
           created_at_ms: created,
           updated_at_ms: updated
         },
         thread_id
       ) do
    is_binary(id) and id != "" and is_binary(objective) and String.trim(objective) != "" and
      status in [:active, :complete, :paused, :blocked, :budget_limited, :usage_limited] and
      valid_budget?(budget) and
      Enum.all?([tokens, seconds, created, updated], &(is_integer(&1) and &1 >= 0))
  end

  defp valid_goal?(_goal, _thread_id), do: false

  defp valid_scalars?(record) do
    is_boolean(record.accounting_uncertain) and is_boolean(record.budget_steering_sent) and
      Enum.all?([record.failure_turns, record.empty_turns], &(is_integer(&1) and &1 >= 0)) and
      valid_budget?(record.max_goal_token_budget) and
      (is_nil(record.continuation_deferral) or is_map(record.continuation_deferral)) and
      valid_interrupted_turn?(record.interrupted_turn)
  end

  defp valid_budget?(nil), do: true
  defp valid_budget?(value), do: is_integer(value) and value > 0

  # Goal.State keys turn accounting by {run_id, incarnation, turn_id}.
  defp valid_interrupted_turn?(nil), do: true

  defp valid_interrupted_turn?({run, incarnation, turn}),
    do:
      is_binary(run) and run != "" and is_integer(incarnation) and incarnation >= 0 and
        is_binary(turn) and turn != ""

  defp valid_interrupted_turn?(_turn), do: false

  defp valid_usage?(%{reports: reports, totals: totals, occupancy: occupancy} = usage)
       when is_map(reports) and is_map(totals) and is_map(occupancy) do
    {:ok, defaults} = Usage.new()

    Enum.all?(Map.keys(defaults.totals), &valid_metric?(Map.get(totals, &1, :missing))) and
      Enum.all?(reports, fn
        {id, %{digest: digest}} -> is_binary(id) and id != "" and is_binary(digest)
        _ -> false
      end) and
      Enum.all?(Map.values(occupancy), &valid_metric?/1) and
      (not Map.has_key?(usage, :reported) or is_map(usage.reported))
  end

  defp valid_usage?(_usage), do: false
  defp valid_metric?(:unknown), do: true
  defp valid_metric?(value), do: is_integer(value) and value >= 0

  defp serializable?(term)
       when is_pid(term) or is_port(term) or is_reference(term) or is_function(term),
       do: false

  defp serializable?(term) when is_map(term),
    do: term |> Map.to_list() |> Enum.all?(fn {k, v} -> serializable?(k) and serializable?(v) end)

  defp serializable?([]), do: true
  defp serializable?([head | tail]), do: serializable?(head) and serializable?(tail)

  defp serializable?(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.all?(&serializable?/1)

  defp serializable?(_term), do: true

  defp write_record(state, thread_id, record) do
    bytes = :erlang.term_to_binary(record, compressed: 6)

    case fs(state.filesystem, :write_atomic, [record_path(state.path, thread_id), bytes]) do
      :ok -> :ok
      {:error, reason} -> {:error, storage_error("goal record commit failed", reason)}
    end
  end

  defp record_path(path, thread_id) do
    name = :crypto.hash(:sha256, thread_id) |> Base.url_encode64(padding: false)
    Path.join(path, name <> ".goal")
  end

  defp validate_thread(thread_id) when is_binary(thread_id) and thread_id != "", do: :ok
  defp validate_thread(_thread_id), do: error(:validation, "goal thread_id is required")

  defp absolute_path(opts) do
    case Keyword.get(opts, :path) do
      path when is_binary(path) ->
        if Path.type(path) == :absolute do
          expanded = Path.expand(path)

          with :ok <- reject_symlinks(path),
               :ok <- reject_symlinks(expanded),
               do: {:ok, expanded}
        else
          error(:validation, "goal store path must be absolute")
        end

      _ ->
        error(:validation, "goal store path must be absolute")
    end
  end

  defp reject_symlinks(path) do
    [root | parts] = Path.split(path)

    parts
    |> Enum.reduce_while(root, fn part, parent ->
      current = Path.join(parent, part)

      case File.lstat(current) do
        {:ok, %{type: :symlink}} ->
          {:halt, error(:validation, "goal store path must not contain symbolic links")}

        {:ok, _stat} ->
          {:cont, current}

        {:error, :enoent} ->
          {:cont, current}

        {:error, reason} ->
          {:halt, {:error, storage_error("goal store path unavailable", reason)}}
      end
    end)
    |> case do
      {:error, _} = error -> error
      _path -> :ok
    end
  end

  defp filesystem(opts) do
    case Keyword.get(opts, :filesystem, {FileSystem, nil}) do
      {module, context} when is_atom(module) -> {:ok, {module, context}}
      _ -> error(:validation, "invalid goal store filesystem")
    end
  end

  defp fs({module, context}, function, args), do: apply(module, function, [context | args])

  defp via(path),
    do: {:via, Registry, {Sigma.Agent.RepositoryRegistry, {:backplane_goal_store, path}}}

  defp error(class, message), do: {:error, Error.new(class, message)}
  defp storage_error(message, reason), do: Error.new(:execution_failure, message, cause: reason)
end
