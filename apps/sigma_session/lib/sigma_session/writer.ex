defmodule Sigma.Session.Writer do
  @moduledoc """
  Serialized commit boundary for one append-only session journal.

  The writer reconstructs its active leaf once at startup, supplies that parent
  to `Sigma.Session.EntryEncoder`, and advances state only after the storage
  adapter acknowledges an append.
  """

  use GenServer

  alias Sigma.Session.{EntryEncoder, HookFeedback, Log, SubagentAdmissions, Subagents}
  alias Sigma.Session.Storage.JsonlFile
  alias Sigma.Protocol.AsyncInteractions

  defstruct [
    :storage_id,
    :storage_mod,
    :session_id,
    :cwd,
    :active_leaf_id,
    :last_append_result,
    :subagent_roster,
    header?: false,
    sequence: 0,
    message_entry_ids: %{},
    subagent_entry_ids: %{},
    subagent_admissions: %{},
    subagent_admission_entry_ids: %{},
    context_window_entry_ids: %{},
    async_interactions: %{version: 1, items: %{}, events: %{}},
    async_interaction_entry_ids: %{},
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

  @doc "Reads the durable context at this writer's selected branch after accepted appends."
  def context_snapshot(writer), do: GenServer.call(writer, :context_snapshot, :infinity)

  @doc "Reads the configured journal behind accepted appends with its selected leaf."
  def selected_journal(writer), do: GenServer.call(writer, :selected_journal, :infinity)

  @doc "Returns durable async facts with the raw selected branch and trusted host session."
  def async_interaction_state(writer),
    do: GenServer.call(writer, :async_interaction_state, :infinity)

  @doc "Commits an async fact only at the expected selected conversation leaf."
  def append_async_interaction(writer, event, expected_leaf_id) do
    GenServer.call(writer, {:append_async_interaction, event, expected_leaf_id}, :infinity)
  end

  @doc "Reads Sigma-owned hook receipts and the selected raw journal ancestry."
  def hook_feedback_state(writer), do: GenServer.call(writer, :hook_feedback_state, :infinity)

  @doc "Commits a hook receipt at the expected selected conversation leaf."
  def append_hook_feedback(writer, event, expected_leaf_id) do
    GenServer.call(writer, {:append_hook_feedback, event, expected_leaf_id}, :infinity)
  end

  @doc "Returns the acknowledged internal subagent projections for the session host."
  def subagent_state(writer), do: GenServer.call(writer, :subagent_state, :infinity)

  @doc "Checks out a persisted branch boundary without rewriting journal history."
  def checkout(writer, checkpoint_entry_id, expected_leaf_id) do
    GenServer.call(writer, {:checkout, checkpoint_entry_id, expected_leaf_id}, :infinity)
  end

  @impl true
  def init(opts) do
    storage_id = Keyword.fetch!(opts, :storage_id)
    storage_mod = Keyword.get(opts, :storage_mod, JsonlFile)
    session_id = Keyword.fetch!(opts, :session_id)

    case Log.snapshot(storage_id, [hook_session_id: session_id], storage_mod) do
      {:ok, snapshot} ->
        {:ok,
         %__MODULE__{
           storage_id: storage_id,
           storage_mod: storage_mod,
           session_id: session_id,
           cwd: Keyword.get(opts, :cwd),
           header?: is_map(snapshot.header),
           active_leaf_id: snapshot.active_leaf_id,
           sequence: length(snapshot.branch_entry_ids) + if(snapshot.header, do: 1, else: 0),
           message_entry_ids: snapshot.message_entry_ids,
           subagent_roster: snapshot.subagent_roster,
           subagent_entry_ids: snapshot.subagent_entry_ids,
           subagent_admissions: snapshot.subagent_admissions,
           subagent_admission_entry_ids: snapshot.subagent_admission_entry_ids,
           context_window_entry_ids: snapshot.context_window_entry_ids,
           async_interactions: snapshot.async_interaction_history,
           async_interaction_entry_ids: snapshot.async_interaction_entry_ids,
           diagnostics: blocking_diagnostics(snapshot.diagnostics)
         }}

      {:error, reason} ->
        {:stop, {:storage_read_failed, reason}}
    end
  end

  @impl true
  def handle_call(:subagent_state, _from, state) do
    {:reply, {:ok, %{roster: state.subagent_roster, admissions: state.subagent_admissions}},
     state}
  end

  def handle_call(:flush, _from, state) do
    {:reply,
     {:ok,
      %{
        active_leaf_id: state.active_leaf_id,
        sequence: state.sequence,
        last_append_result: state.last_append_result,
        subagents: Subagents.snapshot(state.subagent_roster),
        subagent_admissions: state.subagent_admissions
      }}, state}
  end

  def handle_call(:context_snapshot, _from, state) do
    result =
      with {:ok, snapshot} <-
             Log.snapshot(
               state.storage_id,
               [leaf_id: state.active_leaf_id, hook_session_id: state.session_id],
               state.storage_mod
             ) do
        case blocking_diagnostics(snapshot.diagnostics) do
          [] -> {:ok, Map.take(snapshot, [:messages, :context_messages, :context_window])}
          diagnostics -> {:error, {:invalid_journal, diagnostics}}
        end
      end

    {:reply, result, state}
  end

  def handle_call(:selected_journal, _from, state) do
    {:reply, read_selected_journal(state), state}
  end

  def handle_call(:async_interaction_state, _from, state) do
    result =
      with {:ok, journal} <- read_selected_journal(state),
           {:ok, projection} <-
             Sigma.Session.Journal.async_interaction_projection(
               state.async_interactions,
               journal.entries,
               journal.leaf_id
             ) do
        {:ok, Map.merge(journal, %{projection: projection, session_id: state.session_id})}
      end

    {:reply, result, state}
  end

  def handle_call({:append_async_interaction, attrs, expected_leaf_id}, _from, state) do
    with true <- state.active_leaf_id == expected_leaf_id,
         {:ok, event} <- AsyncInteractions.event(attrs),
         true <- event["session_id"] == state.session_id,
         {:ok, journal} <- read_selected_journal(state),
         :ok <- validate_async_branch(event, state.async_interactions, journal),
         {:ok, projection} <- AsyncInteractions.apply_event(state.async_interactions, event) do
      if projection == state.async_interactions do
        result = {:ok, Map.fetch!(state.async_interaction_entry_ids, event["event_id"])}
        {:reply, result, %{state | last_append_result: result}}
      else
        case append_event({:async_interaction, event}, state) do
          {:reply, {:ok, entry_id} = result, committed} ->
            {:reply, result,
             %{
               committed
               | async_interactions: projection,
                 async_interaction_entry_ids:
                   Map.put(committed.async_interaction_entry_ids, event["event_id"], entry_id)
             }}

          reply ->
            reply
        end
      end
    else
      false ->
        result = {:error, :invalid_async_interaction_scope}
        {:reply, result, %{state | last_append_result: result}}

      {:error, _} = result ->
        {:reply, result, %{state | last_append_result: result}}
    end
  end

  def handle_call(:hook_feedback_state, _from, state) do
    {:reply, read_hook_feedback(state), state}
  end

  def handle_call({:append_hook_feedback, attrs, expected_leaf_id}, _from, state) do
    with true <- state.active_leaf_id == expected_leaf_id,
         {:ok, event} <- HookFeedback.event(attrs),
         true <- event["session_id"] == state.session_id,
         {:ok, journal} <- read_hook_feedback(state),
         :ok <- validate_hook_branch(event, journal),
         {:ok, updated} <- HookFeedback.apply_event(journal.history, event) do
      if updated == journal.history do
        result = {:ok, Map.fetch!(journal.entry_ids, event["event_id"])}
        {:reply, result, %{state | last_append_result: result}}
      else
        append_event({:hook_feedback, event}, state)
      end
    else
      false ->
        result = {:error, :invalid_hook_feedback_scope}
        {:reply, result, %{state | last_append_result: result}}

      {:error, _} = result ->
        {:reply, result, %{state | last_append_result: result}}
    end
  end

  def handle_call({:checkout, checkpoint_entry_id, expected_leaf_id}, _from, state) do
    cond do
      state.active_leaf_id != expected_leaf_id ->
        {:reply,
         {:error, {:leaf_conflict, %{expected: expected_leaf_id, actual: state.active_leaf_id}}},
         state}

      true ->
        with {:ok, snapshot} <-
               Log.snapshot(
                 state.storage_id,
                 [leaf_id: checkpoint_entry_id, hook_session_id: state.session_id],
                 state.storage_mod
               ),
             [] <- blocking_diagnostics(snapshot.diagnostics) do
          {:reply, :ok,
           %{
             state
             | active_leaf_id: snapshot.active_leaf_id,
               message_entry_ids: snapshot.message_entry_ids,
               context_window_entry_ids: snapshot.context_window_entry_ids
           }}
        else
          {:error, reason} ->
            {:reply, {:error, {:invalid_retry_checkpoint, reason}}, state}

          diagnostics ->
            {:reply, {:error, {:invalid_journal, diagnostics}}, state}
        end
    end
  end

  def handle_call({:append, {:async_interaction, _}}, _from, state),
    do: {:reply, {:error, :async_interaction_requires_expected_leaf}, state}

  def handle_call({:append, {:hook_feedback, _}}, _from, state),
    do: {:reply, {:error, :hook_feedback_requires_expected_leaf}, state}

  def handle_call({:append, {:subagent_admission, attrs}}, _from, state) do
    with {:ok, event} <- SubagentAdmissions.normalize(attrs),
         {:ok, admissions, roster} <-
           SubagentAdmissions.apply_event(state.subagent_admissions, state.subagent_roster, event) do
      key = SubagentAdmissions.key(event)

      if admissions == state.subagent_admissions do
        result = {:ok, Map.fetch!(state.subagent_admission_entry_ids, key)}
        {:reply, result, %{state | last_append_result: result}}
      else
        case append_event({:subagent_admission, event}, state) do
          {:reply, {:ok, entry_id} = result, committed} ->
            fact_ids =
              Enum.reduce(event.facts, committed.subagent_entry_ids, fn fact, acc ->
                Map.put_new(acc, fact.event_id, entry_id)
              end)

            {:reply, result,
             %{
               committed
               | subagent_admissions: admissions,
                 subagent_roster: roster,
                 subagent_entry_ids: fact_ids,
                 subagent_admission_entry_ids:
                   Map.put(committed.subagent_admission_entry_ids, key, entry_id)
             }}

          reply ->
            reply
        end
      end
    else
      {:error, _} = result -> {:reply, result, %{state | last_append_result: result}}
    end
  end

  def handle_call({:append, {:subagent, attrs}}, _from, state) do
    with {:ok, event} <- Sigma.Protocol.Subagents.event(attrs),
         {:ok, projection} <- Subagents.apply_event(state.subagent_roster, event) do
      if projection == state.subagent_roster do
        result = {:ok, Map.fetch!(state.subagent_entry_ids, event.event_id)}
        {:reply, result, %{state | last_append_result: result}}
      else
        case append_event({:subagent, event}, state) do
          {:reply, {:ok, entry_id} = result, committed} ->
            {:reply, result,
             %{
               committed
               | subagent_roster: projection,
                 subagent_entry_ids:
                   Map.put(committed.subagent_entry_ids, event.event_id, entry_id)
             }}

          reply ->
            reply
        end
      end
    else
      {:error, _reason} = result -> {:reply, result, %{state | last_append_result: result}}
    end
  end

  def handle_call({:append, {:context_window_started, attrs}}, _from, state) do
    with {:ok, window} <- Sigma.Session.EntryDecoder.context_window(attrs) do
      key = {window.run_id, window.incarnation, window.window}

      stale? =
        Enum.any?(state.context_window_entry_ids, fn
          {{run, incarnation, version}, _id} ->
            run == window.run_id and incarnation == window.incarnation and version > window.window
        end)

      cond do
        Map.has_key?(state.context_window_entry_ids, key) ->
          result = {:ok, Map.fetch!(state.context_window_entry_ids, key)}
          {:reply, result, %{state | last_append_result: result}}

        stale? ->
          result = {:error, :stale_context_window}
          {:reply, result, %{state | last_append_result: result}}

        true ->
          case append_event({:context_window_started, window}, state) do
            {:reply, {:ok, id} = result, committed} ->
              {:reply, result,
               %{
                 committed
                 | context_window_entry_ids: Map.put(committed.context_window_entry_ids, key, id)
               }}

            reply ->
              reply
          end
      end
    else
      {:error, _reason} = result -> {:reply, result, %{state | last_append_result: result}}
    end
  end

  def handle_call({:append, event}, _from, state), do: append_event(event, state)

  defp append_event(event, state) do
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
              if(
                entry_type in [
                  :session,
                  :metrics,
                  :subagent,
                  :subagent_admission,
                  :async_interaction,
                  :hook_feedback
                ],
                do: state.active_leaf_id,
                else: entry_id
              ),
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
      %{kind: :message_repair} -> true
      _diagnostic -> false
    end)
  end

  defp normalize_event({:compact, summary, first_kept_id}, state) do
    {:compact, summary, Map.get(state.message_entry_ids, first_kept_id, first_kept_id)}
  end

  defp normalize_event(event, _state), do: event

  defp read_selected_journal(state) do
    read =
      if Code.ensure_loaded?(state.storage_mod) and
           function_exported?(state.storage_mod, :read_with_diagnostics, 1) do
        state.storage_mod.read_with_diagnostics(state.storage_id)
      else
        with {:ok, entries} <- state.storage_mod.read(state.storage_id), do: {:ok, entries, []}
      end

    with {:ok, entries, diagnostics} <- read,
         {:ok, snapshot} <-
           Sigma.Session.Journal.replay(entries,
             leaf_id: state.active_leaf_id,
             hook_session_id: state.session_id,
             diagnostics: diagnostics
           ),
         [] <- blocking_diagnostics(snapshot.diagnostics) do
      {:ok, %{entries: entries, leaf_id: state.active_leaf_id}}
    else
      {:error, _} = error -> error
      diagnostics -> {:error, {:invalid_journal, diagnostics}}
    end
  end

  defp validate_async_branch(event, projection, journal) do
    origin =
      if event["fact"] == "received",
        do: event["origin"],
        else: get_in(projection, [:items, event["item_id"], "origin"])

    index = Sigma.Session.Journal.Index.build(journal.entries)

    with %{} <- origin,
         {:ok, {_leaf, nodes}} <- Sigma.Session.Journal.Index.path(index, journal.leaf_id),
         {:ok, selected} <-
           Sigma.Session.Journal.async_interaction_projection(
             projection,
             journal.entries,
             journal.leaf_id
           ),
         true <-
           not Map.has_key?(projection.items, event["item_id"]) or
             Map.has_key?(selected.items, event["item_id"]),
         %{
           entry: %{
             "type" => "message",
             "message" => %{"role" => "user", "metadata" => %{"turn_id" => run_id}}
           }
         } <-
           Enum.find(nodes, &(&1.entry["id"] == origin["branch_entry_id"])),
         true <- run_id == origin["run_id"] do
      :ok
    else
      _ -> {:error, :invalid_async_interaction_scope}
    end
  end

  defp read_hook_feedback(state) do
    with {:ok, journal} <- read_selected_journal(state),
         {:ok, projection} <-
           Sigma.Session.Journal.hook_feedback_projection(
             journal.entries,
             journal.leaf_id,
             state.session_id
           ) do
      {:ok, Map.merge(journal, Map.put(projection, :session_id, state.session_id))}
    end
  end

  defp validate_hook_branch(event, journal) do
    origin =
      if event["fact"] == "received",
        do: event["origin"],
        else: get_in(journal.history, [:items, event["item_id"], "origin"])

    index = Sigma.Session.Journal.Index.build(journal.entries)

    with %{} <- origin,
         {:ok, {_leaf, nodes}} <- Sigma.Session.Journal.Index.path(index, journal.leaf_id),
         true <-
           not Map.has_key?(journal.history.items, event["item_id"]) or
             Map.has_key?(journal.projection.items, event["item_id"]),
         %{entry: %{"type" => "message"}} <-
           Enum.find(nodes, &(&1.entry["id"] == origin["branch_entry_id"])) do
      :ok
    else
      _ -> {:error, :invalid_hook_feedback_scope}
    end
  end

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
  defp entry_type("context_window"), do: :context_window
  defp entry_type("model_change"), do: :model_change
  defp entry_type("thinking_level_change"), do: :thinking_level_change
  defp entry_type("service_tier_change"), do: :service_tier_change
  defp entry_type("mcp_server_selection_change"), do: :mcp_server_selection_change
  defp entry_type("mode_change"), do: :mode_change
  defp entry_type("branch_summary"), do: :branch_summary
  defp entry_type("skill_invocation"), do: :skill_invocation
  defp entry_type("metrics"), do: :metrics
  defp entry_type("subagent"), do: :subagent
  defp entry_type("subagent_admission"), do: :subagent_admission
  defp entry_type("async_interaction"), do: :async_interaction
  defp entry_type("hook_feedback"), do: :hook_feedback
  defp entry_type(_type), do: :unknown
end
