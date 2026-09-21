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
  """

  use GenServer

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Store, as: RuntimeStore

  @behaviour RuntimeStore

  @record_keys [:run, :revision, :transition, :effects, :outbox, :incarnation]

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

  @impl RuntimeStore
  def load(context, run_id, opts \\ []) when is_list(opts) do
    GenServer.call(context, {:load, run_id}, :infinity)
  end

  @impl RuntimeStore
  def store(context, record, meta) when is_map(record) and is_map(meta) do
    with {:ok, %{stage: stage}} <- RuntimeStore.stage(__MODULE__, context, record, meta),
         {:ok, result} <- commit(context, stage) do
      {:ok, Map.put(result, :outbox, stage.outbox)}
    end
  end

  @impl RuntimeStore
  def acknowledge_commit(context, stage, _meta) when is_map(stage) do
    commit(context, stage)
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
  def init({path, filesystem}), do: {:ok, %{path: path, filesystem: filesystem}}

  defp prepare_directory(filesystem, path) do
    case fs(filesystem, :ensure_dir, [path]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:runtime_store_open_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call(:reload, _from, state) do
    case fs(state.filesystem, :ensure_dir, [state.path]) do
      :ok -> {:reply, {:ok, self()}, state}
      {:error, reason} -> {:reply, storage_error("runtime store reload failed", reason), state}
    end
  end

  def handle_call({:load, run_id}, _from, state) do
    {:reply, read_snapshot(state, run_id), state}
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
      with {:ok, snapshot} <- read_snapshot(state, run_id),
           :ok <- compare_fence(snapshot, expected_revision, current_incarnation) do
        revision = expected_revision + 1

        run =
          snapshot.run
          |> Map.put(:incarnation, next_incarnation)
          |> Map.put(:expected_revision, revision)

        fenced = %{snapshot | run: run, revision: revision, incarnation: next_incarnation}

        with :ok <- write_snapshot(state, run_id, fenced) do
          {:ok, %{revision: revision, run: run}}
        end
      end

    {:reply, result, state}
  end

  defp commit(context, stage), do: GenServer.call(context, {:commit, stage}, :infinity)

  defp persist_stage(state, stage) do
    with :ok <- validate_stage(stage),
         {:ok, current} <- current_snapshot(state, stage.run.run_id),
         :ok <- compare_stage(current, stage),
         snapshot = Map.take(stage, @record_keys),
         :ok <- validate_serializable(snapshot),
         :ok <- write_snapshot(state, stage.run.run_id, snapshot) do
      {:ok, %{revision: stage.revision}}
    end
  end

  defp current_snapshot(state, run_id) do
    case read_snapshot(state, run_id) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, %Error{class: :not_found}} -> {:ok, nil}
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
    case fs(state.filesystem, :read, [record_path(state.path, run_id)]) do
      {:ok, bytes} -> decode_snapshot(bytes, run_id)
      {:error, :enoent} -> {:error, Error.new(:not_found, "runtime run not found")}
      {:error, reason} -> storage_error("runtime record read failed", reason)
    end
  end

  defp decode_snapshot(bytes, run_id) do
    try do
      case :erlang.binary_to_term(bytes, [:safe]) do
        snapshot when is_map(snapshot) -> validate_snapshot(snapshot, run_id)
        _other -> malformed_record()
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

  defp write_snapshot(state, run_id, snapshot) do
    bytes = :erlang.term_to_binary(snapshot, compressed: 6)

    case fs(state.filesystem, :write_atomic, [record_path(state.path, run_id), bytes]) do
      :ok -> :ok
      {:error, reason} -> storage_error("runtime record commit failed", reason)
    end
  end

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
