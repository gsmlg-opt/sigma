defmodule Sigma.Session.Writer do
  @moduledoc """
  Serialized commit boundary for one append-only session journal.

  The writer reconstructs its active leaf once at startup, supplies that parent
  to `Sigma.Session.EntryEncoder`, and advances state only after the storage
  adapter acknowledges an append.
  """

  use GenServer

  alias Sigma.Session.{EntryEncoder, Log}
  alias Sigma.Session.Storage.JsonlFile

  defstruct [
    :storage_id,
    :storage_mod,
    :session_id,
    :cwd,
    :active_leaf_id,
    :last_append_result,
    header?: false,
    sequence: 0,
    message_entry_ids: %{},
    diagnostics: []
  ]

  @type append_result ::
          {:ok, String.t()}
          | :ignored
          | {:error, {:storage_append_failed, term()} | {:invalid_journal, term()} | term()}

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @spec append(GenServer.server(), term()) :: append_result()
  def append(writer, event) do
    GenServer.call(writer, {:append, event}, :infinity)
  end

  @doc "Acknowledges every append already accepted by this writer mailbox."
  def flush(writer) do
    GenServer.call(writer, :flush, :infinity)
  end

  @impl true
  def init(opts) do
    storage_id = Keyword.fetch!(opts, :storage_id)
    storage_mod = Keyword.get(opts, :storage_mod, JsonlFile)

    case Log.snapshot(storage_id, [], storage_mod) do
      {:ok, snapshot} ->
        {:ok,
         %__MODULE__{
           storage_id: storage_id,
           storage_mod: storage_mod,
           session_id: Keyword.fetch!(opts, :session_id),
           cwd: Keyword.get(opts, :cwd),
           header?: is_map(snapshot.header),
           active_leaf_id: snapshot.active_leaf_id,
           sequence: length(snapshot.branch_entry_ids) + if(snapshot.header, do: 1, else: 0),
           message_entry_ids: snapshot.message_entry_ids,
           diagnostics: blocking_diagnostics(snapshot.diagnostics)
         }}

      {:error, reason} ->
        {:stop, {:storage_read_failed, reason}}
    end
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {:reply,
     {:ok,
      %{
        active_leaf_id: state.active_leaf_id,
        sequence: state.sequence,
        last_append_result: state.last_append_result
      }}, state}
  end

  def handle_call({:append, event}, _from, state) do
    event = normalize_event(event, state)

    case EntryEncoder.encode(event, state.active_leaf_id, state.header?) do
      :ignored ->
        {:reply, :ignored, %{state | last_append_result: :ignored}}

      _durable when state.diagnostics != [] ->
        result = {:error, {:invalid_journal, state.diagnostics}}
        {:reply, result, %{state | last_append_result: result}}

      {:error, _reason} = error ->
        {:reply, error, %{state | last_append_result: error}}

      {:ok, %{"type" => "session"} = entry} ->
        {result, state} = append_entry(state, entry)
        {:reply, result, state}

      {:ok, entry} ->
        with {:ok, state} <- ensure_header(state),
             {result, state} <- append_entry(state, entry) do
          {:reply, result, state}
        else
          {:error, reason, state} -> {:reply, {:error, reason}, state}
        end
    end
  end

  defp ensure_header(%{header?: true} = state), do: {:ok, state}

  defp ensure_header(state) do
    case EntryEncoder.encode({:agent_start, state.cwd}, nil, false) do
      {:ok, header} ->
        case append_entry(state, header) do
          {{:ok, _header_id}, state} -> {:ok, state}
          {{:error, reason}, state} -> {:error, reason, state}
        end

      {:error, reason} ->
        result = {:error, reason}
        {:error, reason, %{state | last_append_result: result}}
    end
  end

  defp append_entry(state, entry) do
    started_at = System.monotonic_time()
    result = storage_append(state.storage_mod, state.storage_id, entry)
    duration = System.monotonic_time() - started_at
    entry_type = entry_type(entry["type"])
    telemetry_result = if match?({:ok, _id}, result), do: :ok, else: :error

    :telemetry.execute(
      [:sigma, :session, :writer, :append],
      %{count: 1, duration: duration},
      %{session_id: state.session_id, entry_type: entry_type, result: telemetry_result}
    )

    case result do
      {:ok, entry_id} ->
        state = %{
          state
          | active_leaf_id:
              if(entry_type == :session, do: state.active_leaf_id, else: entry_id),
            header?: state.header? or entry_type == :session,
            sequence: state.sequence + 1,
            message_entry_ids: put_message_entry_id(state.message_entry_ids, entry),
            last_append_result: result
        }

        {result, state}

      {:error, _reason} ->
        {result, %{state | last_append_result: result}}
    end
  end

  defp storage_append(storage_mod, storage_id, entry) do
    case storage_mod.append(storage_id, entry) do
      :ok -> {:ok, entry["id"]}
      {:error, reason} -> {:error, {:storage_append_failed, reason}}
      other -> {:error, {:storage_append_failed, other}}
    end
  rescue
    exception -> {:error, {:storage_append_failed, {:exception, exception.__struct__}}}
  catch
    kind, reason -> {:error, {:storage_append_failed, {kind, reason}}}
  end

  defp blocking_diagnostics(diagnostics) do
    Enum.reject(diagnostics, fn
      %{kind: :invalid_payload} -> true
      %{kind: :invalid_header, reason: :missing_header} -> true
      _diagnostic -> false
    end)
  end

  defp normalize_event({:compact, summary, first_kept_id}, state) do
    {:compact, summary, Map.get(state.message_entry_ids, first_kept_id, first_kept_id)}
  end

  defp normalize_event(event, _state), do: event

  defp put_message_entry_id(message_entry_ids, %{
         "type" => "message",
         "id" => entry_id,
         "message" => %{"id" => message_id}
       })
       when is_binary(entry_id) and is_binary(message_id) do
    Map.put(message_entry_ids, message_id, entry_id)
  end

  defp put_message_entry_id(message_entry_ids, _entry), do: message_entry_ids

  defp entry_type("session"), do: :session
  defp entry_type("message"), do: :message
  defp entry_type("compaction"), do: :compaction
  defp entry_type("model_change"), do: :model_change
  defp entry_type("thinking_level_change"), do: :thinking_level_change
  defp entry_type("service_tier_change"), do: :service_tier_change
  defp entry_type("mcp_server_selection_change"), do: :mcp_server_selection_change
  defp entry_type("mode_change"), do: :mode_change
  defp entry_type("branch_summary"), do: :branch_summary
  defp entry_type(_type), do: :unknown
end
