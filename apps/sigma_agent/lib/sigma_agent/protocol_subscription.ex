defmodule Sigma.Agent.ProtocolSubscription do
  @moduledoc "Non-blocking relay from one Agent event stream to one protocol client."

  use GenServer

  alias Sigma.Agent.ProtocolEventMapper
  alias Sigma.Protocol.Envelope

  @default_max_sink_queue 256
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
    subscription_id = Keyword.get(opts, :subscription_id, random_id())

    child_opts = [
      agent: agent,
      session_id: session_id,
      sink: sink,
      subscription_id: subscription_id,
      max_sink_queue: Keyword.get(opts, :max_sink_queue, @default_max_sink_queue)
    ]

    case DynamicSupervisor.start_child(
           Sigma.Agent.ProtocolSubscriptionSupervisor,
           {__MODULE__, child_opts}
         ) do
      {:ok, _pid} -> {:ok, subscription_id}
      {:error, {:already_started, _pid}} -> {:error, :subscription_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  def detach(subscription_id, sink) when is_binary(subscription_id) and is_pid(sink) do
    case Registry.lookup(Sigma.Agent.ProtocolSubscriptionRegistry, subscription_id) do
      [{pid, ^sink}] -> DynamicSupervisor.terminate_child(Sigma.Agent.ProtocolSubscriptionSupervisor, pid)
      [{_pid, _other_sink}] -> {:error, :subscription_owner_mismatch}
      [] -> {:error, :subscription_not_found}
    end
  end

  @impl true
  def init(opts) do
    subscription_id = Keyword.fetch!(opts, :subscription_id)
    sink = Keyword.fetch!(opts, :sink)
    agent = Keyword.fetch!(opts, :agent)

    {:ok, _owner} =
      Registry.register(Sigma.Agent.ProtocolSubscriptionRegistry, subscription_id, sink)

    :ok = Sigma.Agent.subscribe(agent)
    monitor_ref = Process.monitor(sink)

    turn_id =
      case Sigma.Agent.status(agent) do
        %{turn_id: turn_id} -> turn_id
        _status -> nil
      end

    {:ok,
     %{
       agent: agent,
       session_id: Keyword.fetch!(opts, :session_id),
       subscription_id: subscription_id,
       sink: sink,
       sink_monitor_ref: monitor_ref,
       max_sink_queue: Keyword.fetch!(opts, :max_sink_queue),
       turn_id: turn_id,
       last_error: nil,
       dropped: 0
     }}
  end

  @impl true
  def terminate(_reason, state) do
    if Process.alive?(state.agent), do: Sigma.Agent.unsubscribe(state.agent)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{sink_monitor_ref: ref} = state) do
    {:stop, :normal, state}
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

  def handle_info(raw_event, state) do
    {event, turn_id} = ProtocolEventMapper.map(raw_event, state.session_id, state.turn_id)
    {:noreply, deliver(event, %{state | turn_id: turn_id})}
  end

  defp deliver(nil, state), do: state

  defp deliver(%Envelope{} = event, state) do
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

      %{state | dropped: dropped}
    end
  end

  defp sink_queue_len(sink) do
    case Process.info(sink, :message_queue_len) do
      {:message_queue_len, length} -> length
      nil -> @default_max_sink_queue
    end
  end

  defp random_id do
    "sub_" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))
  end
end
