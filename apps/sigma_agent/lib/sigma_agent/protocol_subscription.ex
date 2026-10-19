defmodule Sigma.Agent.ProtocolSubscription do
  @moduledoc "Non-blocking relay from one Agent event stream to one protocol client."

  use GenServer

  alias Sigma.Agent.ProtocolEventMapper
  alias Sigma.Protocol.{Codec, Envelope, Error, Subagents}

  @default_max_sink_queue 256
  @subagent_resync_retry_ms 25
  @terminal_types ~w(turn.completed turn.failed turn.cancelled session.error)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def child_spec(opts) do
    %{
      id: Keyword.fetch!(opts, :subscription_id),
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def attach(agent, session_id, sink, opts \\ [])
      when is_pid(agent) and is_binary(session_id) and is_pid(sink) do
    case attach_snapshot(agent, session_id, sink, opts) do
      {:ok, subscription_id, _cursor, _snapshot} ->
        {:ok, subscription_id}

      {:ok, subscription_id, _cursor, _snapshot, _attachment_snapshot} ->
        {:ok, subscription_id}

      {:error, _reason} = error ->
        error
    end
  end

  def attach_snapshot(agent, session_id, sink, opts \\ [])
      when is_pid(agent) and is_binary(session_id) and is_pid(sink) do
    subscription_id = Keyword.get(opts, :subscription_id, random_id())

    child_opts = [
      agent: agent,
      session_id: session_id,
      sink: sink,
      subscription_id: subscription_id,
      max_sink_queue: Keyword.get(opts, :max_sink_queue, @default_max_sink_queue),
      capabilities: Keyword.get(opts, :capabilities, [])
    ]

    case DynamicSupervisor.start_child(
           Sigma.Agent.ProtocolSubscriptionSupervisor,
           {__MODULE__, child_opts}
         ) do
      {:ok, pid} ->
        loader = Keyword.get(opts, :snapshot_loader)

        case GenServer.call(pid, {:activate, loader}, :infinity) do
          {:ok, cursor, turn_snapshot, attachment_snapshot} ->
            if Keyword.has_key?(opts, :snapshot_loader) do
              {:ok, subscription_id, cursor, turn_snapshot, attachment_snapshot}
            else
              {:ok, subscription_id, cursor, turn_snapshot}
            end

          {:error, _reason} = error ->
            DynamicSupervisor.terminate_child(Sigma.Agent.ProtocolSubscriptionSupervisor, pid)
            error
        end

      {:error, {:already_started, _pid}} ->
        {:error, :subscription_exists}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Validates a snapshot response inside the relay before advancing its roster watermark."
  def snapshot(subscription_id, sink, snapshot_loader, validator \\ nil)
      when is_binary(subscription_id) and is_pid(sink) and is_function(snapshot_loader, 0) and
             (is_nil(validator) or is_function(validator, 3)) do
    case Registry.lookup(Sigma.Agent.ProtocolSubscriptionRegistry, subscription_id) do
      [{pid, ^sink}] -> GenServer.call(pid, {:snapshot, snapshot_loader, validator}, :infinity)
      [{_pid, _other_sink}] -> {:error, :subscription_owner_mismatch}
      [] -> {:error, :subscription_not_found}
    end
  end

  def detach(subscription_id, sink) when is_binary(subscription_id) and is_pid(sink) do
    case Registry.lookup(Sigma.Agent.ProtocolSubscriptionRegistry, subscription_id) do
      [{pid, ^sink}] ->
        DynamicSupervisor.terminate_child(Sigma.Agent.ProtocolSubscriptionSupervisor, pid)

      [{_pid, _other_sink}] ->
        {:error, :subscription_owner_mismatch}

      [] ->
        {:error, :subscription_not_found}
    end
  end

  @impl true
  def init(opts) do
    subscription_id = Keyword.fetch!(opts, :subscription_id)
    sink = Keyword.fetch!(opts, :sink)
    agent = Keyword.fetch!(opts, :agent)

    {:ok, _owner} =
      Registry.register(Sigma.Agent.ProtocolSubscriptionRegistry, subscription_id, sink)

    snapshot = Sigma.Agent.subscribe_snapshot(agent)
    monitor_ref = Process.monitor(sink)

    {:ok,
     %{
       agent: agent,
       session_id: Keyword.fetch!(opts, :session_id),
       subscription_id: subscription_id,
       sink: sink,
       sink_monitor_ref: monitor_ref,
       max_sink_queue: Keyword.fetch!(opts, :max_sink_queue),
       capabilities: Keyword.fetch!(opts, :capabilities),
       turn_id: snapshot.turn_id,
       snapshot: snapshot,
       ready?: false,
       pending: [],
       pending_count: 0,
       subagent_revision: 0,
       subagent_observer: nil,
       subagent_retired_observers: MapSet.new(),
       subagent_agents: %{},
       subagent_blocked?: false,
       subagent_resync: nil,
       subagent_resync_timer: nil,
       last_error: nil,
       dropped: 0,
       cursor: 0,
       resync_required: nil,
       metric_revisions: %{},
       metric_events: %{}
     }}
  end

  @impl true
  def handle_call({:activate, snapshot_loader}, _from, state) do
    case load_attachment_snapshot(snapshot_loader) do
      {:ok, attachment_snapshot} ->
        state = seed_subagents(state, attachment_snapshot)
        Enum.each(Enum.reverse(state.pending), &send(self(), &1))

        {:reply, {:ok, state.cursor, state.snapshot, attachment_snapshot},
         %{state | ready?: true, pending: [], pending_count: 0}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:snapshot, snapshot_loader}, from, state),
    do: handle_call({:snapshot, snapshot_loader, nil}, from, state)

  def handle_call({:snapshot, snapshot_loader, validator}, _from, state) do
    with {:ok, cursor, turn_snapshot, attachment_snapshot} <-
           subscription_snapshot(state, snapshot_loader),
         {:ok, response} <-
           validate_snapshot(validator, cursor, turn_snapshot, attachment_snapshot) do
      {:reply, response, seed_snapshot_response(state, response, attachment_snapshot)}
    else
      error -> {:reply, error, state}
    end
  end

  defp seed_snapshot_response(
         state,
         {:ok, %Envelope{type: "session.snapshot", payload: payload}},
         snapshot
       ) do
    case Subagents.snapshot(payload["subagents"]) do
      {:ok, _roster} -> seed_subagents(state, snapshot)
      {:error, _reason} -> state
    end
  end

  defp seed_snapshot_response(state, {:ok, _cursor, _turn, _snapshot}, snapshot),
    do: seed_subagents(state, snapshot)

  defp seed_snapshot_response(state, _response, _snapshot), do: state

  defp validate_snapshot(nil, cursor, turn_snapshot, attachment_snapshot),
    do: {:ok, {:ok, cursor, turn_snapshot, attachment_snapshot}}

  defp validate_snapshot(validator, cursor, turn_snapshot, attachment_snapshot) do
    with {:ok, response} <- validator.(cursor, turn_snapshot, attachment_snapshot),
         do: {:ok, {:ok, response}}
  end

  @impl true
  def terminate(_reason, state) do
    cancel_subagent_resync_timer(state)
    if Process.alive?(state.agent), do: Sigma.Agent.unsubscribe(state.agent)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{sink_monitor_ref: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(
        {:subagent_resync_retry, token},
        %{subagent_resync_timer: {_timer, token}} = state
      ) do
    {:noreply, flush_subagent_resync(%{state | subagent_resync_timer: nil})}
  end

  def handle_info({:subagent_resync_retry, _token}, state), do: {:noreply, state}

  def handle_info({:subagent, _} = message, %{ready?: false} = state) do
    cond do
      "subagents.v1" not in state.capabilities ->
        {:noreply, state}

      state.pending_count < max(state.max_sink_queue, 1) ->
        {:noreply,
         %{state | pending: [message | state.pending], pending_count: state.pending_count + 1}}

      true ->
        {:noreply, require_subagent_resync(state, "subscriber_overflow")}
    end
  end

  def handle_info(message, %{ready?: false} = state) do
    {:noreply, %{state | pending: [message | state.pending]}}
  end

  def handle_info({:turn_error, reason}, state) do
    {:noreply, %{state | last_error: reason}}
  end

  def handle_info({:turn_failed, _turn_id} = raw_event, state) do
    {event, turn_id} = ProtocolEventMapper.map(raw_event, state.session_id, state.turn_id)

    event =
      if event && state.last_error do
        %{event | error: ProtocolEventMapper.public_error(state.last_error)}
      else
        event
      end

    {:noreply, deliver(event, %{state | turn_id: turn_id, last_error: nil})}
  end

  def handle_info({:turn_completed, _turn_id} = raw_event, state) do
    {event, turn_id} = ProtocolEventMapper.map(raw_event, state.session_id, state.turn_id)
    {:noreply, deliver(event, %{state | turn_id: turn_id, last_error: nil})}
  end

  def handle_info({:turn_cancelled} = raw_event, state) do
    {event, turn_id} = ProtocolEventMapper.map(raw_event, state.session_id, state.turn_id)
    {:noreply, deliver(event, %{state | turn_id: turn_id, last_error: nil})}
  end

  def handle_info({:subagent, attrs} = raw_event, state) do
    if "subagents.v1" in state.capabilities do
      with {:ok, fact} <- Subagents.event(attrs),
           {:deliver, state} <- track_subagent(fact, state) do
        {event, _turn_id} = ProtocolEventMapper.map(raw_event, state.session_id, state.turn_id)
        {:noreply, deliver_subagent(event, state)}
      else
        {:ignore, state} -> {:noreply, flush_subagent_resync(state)}
        {:error, _} -> {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:metrics, fact, attrs} = raw_event, state) do
    if "metrics.v1" in state.capabilities do
      case track_metric_event(fact, attrs, state) do
        {:duplicate, state} ->
          {:noreply, state}

        {:deliver, state} ->
          {event, turn_id} = ProtocolEventMapper.map(raw_event, state.session_id, state.turn_id)
          {:noreply, deliver(event, %{state | turn_id: turn_id})}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(raw_event, state) do
    {event, turn_id} = ProtocolEventMapper.map(raw_event, state.session_id, state.turn_id)
    {:noreply, deliver(event, %{state | turn_id: turn_id})}
  end

  # Snapshot replay is authoritative; the future host adapter supplies live ownership.
  defp seed_subagents(state, snapshot) when is_map(snapshot) do
    with true <- "subagents.v1" in state.capabilities,
         {:ok, roster} <- Subagents.snapshot(Map.get(snapshot, :subagents)) do
      latest = Enum.max_by(roster.agents, & &1.revision, fn -> nil end)
      observer = if latest, do: latest.observer_incarnation

      retired =
        if state.subagent_observer && state.subagent_observer != observer,
          do: MapSet.put(state.subagent_retired_observers, state.subagent_observer),
          else: state.subagent_retired_observers

      state = cancel_subagent_resync_timer(state)

      %{
        state
        | subagent_revision: roster.revision,
          subagent_observer: observer,
          subagent_retired_observers: retired,
          subagent_agents: Map.new(roster.agents, &{&1.agent_id, &1}),
          subagent_blocked?: false,
          subagent_resync: nil
      }
    else
      _ -> state
    end
  end

  defp seed_subagents(state, _), do: state

  defp track_subagent(fact, state) do
    previous = state.subagent_agents[fact.data.agent_id]

    cond do
      MapSet.member?(state.subagent_retired_observers, fact.observer_incarnation) ->
        {:ignore, state}

      fact.revision <= state.subagent_revision ->
        {:ignore, state}

      previous &&
          (fact.data.incarnation < previous.incarnation or
             (fact.data.incarnation == previous.incarnation and
                fact.data.run_id != previous.run_id)) ->
        {:ignore, state}

      state.subagent_blocked? ->
        {:ignore, state}

      fact.revision != state.subagent_revision + 1 ->
        {:ignore, require_subagent_resync(state, "subagent_revision_gap")}

      state.subagent_observer && state.subagent_observer != fact.observer_incarnation &&
          fact.fact != :recovered ->
        {:ignore, require_subagent_resync(state, "subagent_observer_changed")}

      fact.data[:root_session_id] && fact.data.root_session_id != state.session_id ->
        {:ignore, require_subagent_resync(state, "subagent_identity_conflict")}

      true ->
        retired =
          if state.subagent_observer && state.subagent_observer != fact.observer_incarnation,
            do: MapSet.put(state.subagent_retired_observers, state.subagent_observer),
            else: state.subagent_retired_observers

        {:deliver,
         %{
           state
           | subagent_revision: fact.revision,
             subagent_observer: fact.observer_incarnation,
             subagent_retired_observers: retired,
             subagent_agents: Map.put(state.subagent_agents, fact.data.agent_id, fact.data)
         }}
    end
  end

  defp require_subagent_resync(state, reason) do
    %{
      state
      | subagent_blocked?: true,
        subagent_resync:
          state.subagent_resync || %{"reason" => reason, "snapshotRequired" => true}
    }
    |> schedule_subagent_resync_retry()
  end

  defp schedule_subagent_resync_retry(%{subagent_resync_timer: nil} = state) do
    token = make_ref()
    timer = Process.send_after(self(), {:subagent_resync_retry, token}, @subagent_resync_retry_ms)
    %{state | subagent_resync_timer: {timer, token}}
  end

  defp schedule_subagent_resync_retry(state), do: state

  defp cancel_subagent_resync_timer(%{subagent_resync_timer: {timer, _token}} = state) do
    Process.cancel_timer(timer)
    %{state | subagent_resync_timer: nil}
  end

  defp cancel_subagent_resync_timer(state), do: state

  defp deliver_subagent(nil, state), do: state

  defp deliver_subagent(event, state) do
    state = flush_subagent_resync(state)
    {event, state} = add_cursor(event, state)

    case Codec.encode(event) do
      {:ok, _encoded} ->
        if sink_queue_len(state.sink) < state.max_sink_queue do
          send(state.sink, {:sigma_protocol, state.subscription_id, event})
          state
        else
          require_subagent_resync(state, "subscriber_overflow")
        end

      {:error, reason} ->
        reason =
          if reason == :payload_too_large,
            do: "subagent_payload_too_large",
            else: "subagent_payload_rejected"

        state |> require_subagent_resync(reason) |> flush_subagent_resync()
    end
  end

  defp flush_subagent_resync(%{subagent_resync: details} = state) when is_map(details) do
    if sink_queue_len(state.sink) < state.max_sink_queue do
      {:ok, event} =
        Envelope.event("session.error", state.session_id, details,
          error:
            Error.new(
              "resync_required",
              "Subscription state is incomplete; fetch a new snapshot."
            )
        )

      {event, state} = add_cursor(event, state)
      send(state.sink, {:sigma_protocol, state.subscription_id, event})
      state = cancel_subagent_resync_timer(state)
      %{state | subagent_resync: nil}
    else
      schedule_subagent_resync_retry(state)
    end
  end

  defp flush_subagent_resync(state), do: state

  defp deliver(nil, state), do: state

  defp deliver(%Envelope{} = event, state) do
    state = maybe_deliver_resync(event, state)
    {event, state} = add_cursor(event, state)
    queue_len = sink_queue_len(state.sink)

    :telemetry.execute(
      [:sigma, :protocol, :subscriber, :delivery],
      %{count: 1, queue_depth: queue_len},
      %{session_id: state.session_id, subscription_id: state.subscription_id}
    )

    if queue_len < state.max_sink_queue or event.type in @terminal_types do
      send(state.sink, {:sigma_protocol, state.subscription_id, event})
      state
    else
      dropped = state.dropped + 1

      :telemetry.execute(
        [:sigma, :protocol, :subscriber, :dropped],
        %{count: 1},
        %{session_id: state.session_id, subscription_id: state.subscription_id}
      )

      resync = %{
        "reason" => "subscriber_overflow",
        "cursor" => state.cursor,
        "dropped" => dropped
      }

      %{state | dropped: dropped, resync_required: resync}
    end
  end

  defp add_cursor(%Envelope{payload: payload} = event, %{cursor: cursor} = state) do
    cursor = cursor + 1
    {%{event | payload: Map.put(payload, "cursor", cursor)}, %{state | cursor: cursor}}
  end

  defp maybe_deliver_resync(%Envelope{} = event, %{resync_required: details} = state)
       when is_map(details) do
    error =
      Error.new("resync_required", "Subscription state is incomplete; fetch a new snapshot.")

    {cursor, state} = resync_cursor(details, state)

    payload =
      details
      |> Map.delete("cursor")
      |> Map.put("cursor", cursor)
      |> Map.put("snapshotRequired", true)

    {:ok, marker} =
      Envelope.event(
        "session.error",
        event.session_id,
        payload,
        turn_id: event.turn_id,
        error: error
      )

    send(state.sink, {:sigma_protocol, state.subscription_id, marker})
    %{state | resync_required: nil}
  end

  defp maybe_deliver_resync(_event, state), do: state

  defp resync_cursor(%{"cursor" => cursor}, state) when is_integer(cursor), do: {cursor, state}

  defp resync_cursor(_details, state) do
    cursor = state.cursor + 1
    {cursor, %{state | cursor: cursor}}
  end

  defp track_metric_event(fact, attrs, state) when is_atom(fact) and is_map(attrs) do
    with {kind, id} when is_binary(id) and id != "" <- metric_identity(fact, attrs),
         revision when is_integer(revision) and revision >= 0 <- metric_value(attrs, :revision) do
      identity = {kind, id}
      event_identity = {fact, identity}
      fingerprint = {revision, attrs}

      if state.metric_events[event_identity] == fingerprint do
        {:duplicate, state}
      else
        previous_revision = Map.get(state.metric_revisions, identity)

        state = %{
          state
          | metric_events: Map.put(state.metric_events, event_identity, fingerprint),
            metric_revisions:
              Map.put(state.metric_revisions, identity, max_revision(previous_revision, revision))
        }

        state = maybe_require_revision_resync(state, identity, previous_revision, revision)
        {:deliver, state}
      end
    else
      _missing_identity_or_revision -> {:deliver, state}
    end
  end

  defp metric_identity(fact, attrs)
       when fact in [:request_started, :request_finished, :request_usage],
       do: {:request, metric_value(attrs, :request_id)}

  defp metric_identity(fact, attrs) when fact in [:turn_started, :turn_finished],
    do: {:turn, metric_value(attrs, :turn_id)}

  defp metric_identity(:tool_finished, attrs),
    do: {:tool, metric_value(attrs, :tool_id)}

  defp metric_identity(:compaction, attrs),
    do: {:compaction, metric_value(attrs, :compaction_id)}

  defp metric_identity(fact, attrs) when fact in [:operation_started, :operation_finished],
    do: {:operation, metric_value(attrs, :operation_id)}

  defp metric_identity(_fact, _attrs), do: nil

  defp metric_value(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp max_revision(nil, revision), do: revision
  defp max_revision(previous, revision), do: max(previous, revision)

  defp maybe_require_revision_resync(state, _identity, nil, _revision), do: state

  defp maybe_require_revision_resync(
         %{resync_required: details} = state,
         _identity,
         _previous,
         _revision
       )
       when is_map(details),
       do: state

  defp maybe_require_revision_resync(state, identity, previous_revision, revision)
       when revision > previous_revision + 1 do
    %{
      state
      | resync_required: %{
          "reason" => "revision_gap",
          "entity" => metric_identity_payload(identity),
          "expectedRevision" => previous_revision + 1,
          "actualRevision" => revision
        }
    }
  end

  defp maybe_require_revision_resync(state, _identity, _previous_revision, _revision), do: state

  defp metric_identity_payload({kind, id}),
    do: %{"kind" => Atom.to_string(kind), "id" => id}

  defp sink_queue_len(sink) do
    case Process.info(sink, :message_queue_len) do
      {:message_queue_len, length} -> length
      nil -> @default_max_sink_queue
    end
  end

  defp load_attachment_snapshot(opts) do
    case opts do
      nil -> {:ok, nil}
      loader when is_function(loader, 0) -> loader.()
      _loader -> {:error, :invalid_snapshot_loader}
    end
  rescue
    exception -> {:error, {:snapshot_load_failed, exception.__struct__}}
  catch
    kind, reason -> {:error, {:snapshot_load_failed, kind, reason}}
  end

  defp subscription_snapshot(state, snapshot_loader) do
    with {:ok, attachment_snapshot} <- load_attachment_snapshot(snapshot_loader) do
      turn_snapshot = Sigma.Agent.subscribe_snapshot(state.agent)
      {:ok, state.cursor, turn_snapshot, attachment_snapshot}
    end
  catch
    :exit, reason -> {:error, {:snapshot_load_failed, :exit, reason}}
  end

  defp random_id do
    "sub_" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))
  end
end
