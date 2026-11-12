defmodule Sigma.Web.SamgitaHost.ThreadStream do
  @moduledoc """
  Per-thread samgita_protocol notification stream.

  Subscribes to the Sigma session's Protocol V1 events, translates them into
  native notifications and keeps one bounded `SamgitaProtocol.Replay` log per
  turn (`stream_id` = turn id, cursor 1 = the first notification of the turn).
  Notifications fan out to attached socket processes as
  `{:protocol_notification, message}`.

  A socket attaching mid-turn receives the active turn's retained backlog in
  the same call, before any live notification. If that log no longer holds
  cursor 1 the socket skips the active turn and starts at the next one.

  Events of a turn that already completed are dropped. When the subscription
  reports or reveals event loss (a `resync_required` marker or a non-contiguous
  subscription cursor), the affected turn is poisoned: it stops fanning out, its
  log is discarded so `resume/3` answers `replay_gap`, and it is no longer active.

  The stream exits (detaching its subscription) when the session agent exits,
  or after `idle_timeout` with no attached sockets and no running turn.
  """
  use GenServer

  require Logger

  alias SamgitaProtocol.{Error, Replay}
  alias Sigma.Agent.PublicRuntime
  alias Sigma.Protocol.Envelope
  alias Sigma.Web.ProtocolContext
  alias Sigma.Web.SamgitaHost.{ThreadId, Translate}

  @registry Sigma.Web.SamgitaHost.Registry
  @supervisor Sigma.Web.SamgitaHost.ThreadStreams
  @replay_limit 4096
  @retained_turns 8
  @closed_turns 32
  @idle_timeout 300_000

  @type active_stream :: nil | %{String.t() => String.t() | non_neg_integer()}

  def child_spec({thread_id, opts}) do
    %{
      id: {__MODULE__, thread_id},
      start: {__MODULE__, :start_link, [{thread_id, opts}]},
      restart: :temporary
    }
  end

  def start_link({thread_id, opts}),
    do: GenServer.start_link(__MODULE__, {thread_id, opts}, name: via(thread_id))

  @doc "Finds or starts the stream for `thread_id`, subscribing to its running session."
  @spec ensure(String.t(), keyword()) :: {:ok, pid()} | {:error, :not_found}
  def ensure(thread_id, opts \\ []) do
    case whereis(thread_id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        case DynamicSupervisor.start_child(@supervisor, {__MODULE__, {thread_id, opts}}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          _ignored_or_failed -> {:error, :not_found}
        end
    end
  end

  @doc "Attaches `socket_pid`; the active turn's backlog is sent before this returns."
  @spec attach(String.t(), pid()) ::
          {:ok, %{active_stream: active_stream()}} | {:error, :not_found}
  def attach(thread_id, socket_pid) when is_pid(socket_pid),
    do: call(thread_id, {:attach, socket_pid}, {:error, :not_found})

  @doc "Notifications of `stream_id` after `cursor`; unknown threads or streams are a `replay_gap`."
  @spec resume(String.t(), String.t(), non_neg_integer()) :: {:ok, [map()]} | {:error, Error.t()}
  def resume(thread_id, stream_id, cursor),
    do: call(thread_id, {:resume, stream_id, cursor}, {:error, Error.new("replay_gap")})

  defp call(thread_id, request, missing) do
    case whereis(thread_id) do
      nil -> missing
      pid -> GenServer.call(pid, request)
    end
  catch
    :exit, {:noproc, _} -> missing
    :exit, {reason, _} when reason in [:normal, :shutdown] -> missing
  end

  defp whereis(thread_id) when is_binary(thread_id) do
    case Registry.lookup(@registry, thread_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp whereis(_thread_id), do: nil

  defp via(thread_id), do: {:via, Registry, {@registry, thread_id}}

  @impl true
  def init({thread_id, opts}) do
    with {:ok, scope} <- ThreadId.decode(thread_id),
         context = context(scope),
         {:ok, command} <- Envelope.command("subscription.attach", scope.session_id, %{}),
         {:ok, %Envelope{payload: %{"subscriptionId" => subscription_id} = ack}} <-
           PublicRuntime.execute(command, context),
         {:ok, agent_ref} <- monitor_agent(scope, context, subscription_id) do
      state = %{
        thread_id: thread_id,
        session_id: scope.session_id,
        context: context,
        subscription_id: subscription_id,
        agent_ref: agent_ref,
        next_cursor: next_cursor(ack["cursor"]),
        closed: [],
        replay_limit: Keyword.get(opts, :replay_limit, @replay_limit),
        idle_timeout: Keyword.get(opts, :idle_timeout, @idle_timeout),
        idle_timer: nil,
        logs: %{},
        turns: [],
        active: nil,
        sockets: %{}
      }

      {:ok, schedule_idle(state)}
    else
      _ -> :ignore
    end
  end

  @impl true
  def handle_call({:attach, socket}, _from, state) do
    if Map.has_key?(state.sockets, socket) do
      {:reply, {:ok, %{active_stream: active_stream(state, socket)}}, state}
    else
      ref = Process.monitor(socket)
      skip = deliver_backlog(state, socket)
      state = put_in(state.sockets[socket], %{ref: ref, skip: skip})
      {:reply, {:ok, %{active_stream: active_stream(state, socket)}}, schedule_idle(state)}
    end
  end

  def handle_call({:resume, stream_id, cursor}, _from, state) do
    reply =
      case state.logs do
        %{^stream_id => log} -> Replay.since(log, cursor)
        _ -> {:error, Error.new("replay_gap")}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info({:sigma_protocol, id, %Envelope{} = event}, %{subscription_id: id} = state),
    do: {:noreply, state |> check_continuity(event) |> publish(event) |> schedule_idle()}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{agent_ref: ref} = state) do
    detach(state)
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, schedule_idle(%{state | sockets: Map.delete(state.sockets, pid)})}
  end

  def handle_info({:idle_timeout, ref}, %{idle_timer: {_timer, ref}} = state) do
    if idle?(state) do
      detach(state)
      {:stop, :normal, state}
    else
      {:noreply, %{state | idle_timer: nil}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp context(scope) do
    ProtocolContext.build(
      %{
        workdir: scope.repo_path,
        sessions_dir: scope.sessions_dir,
        session_id: scope.session_id,
        subscriber: self()
      },
      interactive_approvals: false
    )
  end

  defp monitor_agent(scope, context, subscription_id) do
    case Sigma.Agent.Runtime.lookup(scope.repo_path, scope.session_id, :agent) do
      agent when is_pid(agent) ->
        {:ok, Process.monitor(agent)}

      nil ->
        detach(%{session_id: scope.session_id, subscription_id: subscription_id, context: context})
        {:error, :not_found}
    end
  end

  # Best effort: the subscription also stops on its own once this process exits.
  defp detach(state) do
    {:ok, command} =
      Envelope.command("subscription.detach", state.session_id, %{
        "subscriptionId" => state.subscription_id
      })

    PublicRuntime.execute(command, state.context)
  end

  defp next_cursor(cursor) when is_integer(cursor), do: cursor + 1
  defp next_cursor(_cursor), do: nil

  # Every delivered subscription event carries a contiguous `payload["cursor"]`,
  # including events Translate skips; a gap or a resync marker means events were dropped.
  defp check_continuity(state, %Envelope{payload: payload} = event) do
    cursor = payload["cursor"]

    lost? =
      resync_marker?(event) or
        (is_integer(cursor) and is_integer(state.next_cursor) and cursor != state.next_cursor)

    state = if is_integer(cursor), do: %{state | next_cursor: cursor + 1}, else: state

    if lost? do
      Logger.warning("samgita thread stream lost subscription events; poisoning the affected turn")

      [state.active, event.turn_id]
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.reduce(state, &poison(&2, &1))
    else
      state
    end
  end

  defp resync_marker?(%Envelope{type: "session.error", error: %{code: "resync_required"}}),
    do: true

  defp resync_marker?(_event), do: false

  defp poison(state, turn_id) do
    if turn_id in state.closed do
      state
    else
      state
      |> close(turn_id)
      |> Map.update!(:logs, &Map.delete(&1, turn_id))
      |> Map.update!(:turns, &List.delete(&1, turn_id))
    end
  end

  # Marks the turn terminated: later events for it are dropped and it is no longer active.
  defp close(state, turn_id) do
    sockets =
      Map.new(state.sockets, fn
        {socket, %{skip: ^turn_id} = attachment} -> {socket, %{attachment | skip: nil}}
        entry -> entry
      end)

    %{
      state
      | closed: Enum.take([turn_id | List.delete(state.closed, turn_id)], @closed_turns),
        active: if(state.active == turn_id, do: nil, else: state.active),
        sockets: sockets
    }
  end

  # Returns the turn id the socket must skip, or nil.
  defp deliver_backlog(%{active: nil}, _socket), do: nil

  defp deliver_backlog(%{active: turn_id} = state, socket) do
    case state.logs[turn_id].events do
      [%{"cursor" => 1} | _] = events ->
        Enum.each(events, &send(socket, {:protocol_notification, &1}))
        nil

      _lost_first_cursor ->
        turn_id
    end
  end

  defp active_stream(%{active: nil}, _socket), do: nil

  defp active_stream(%{active: turn_id} = state, socket) do
    case state.sockets[socket] do
      %{skip: ^turn_id} ->
        nil

      _following ->
        %{"stream_id" => turn_id, "cursor" => state.logs[turn_id].next_cursor - 1}
    end
  end

  defp publish(state, %Envelope{turn_id: turn_id} = event) when is_binary(turn_id) do
    if turn_id in state.closed, do: state, else: publish_open(state, event)
  end

  defp publish(state, _event), do: state

  defp publish_open(state, event) do
    case translate(event, state.thread_id) do
      {:ok, %{"correlation_id" => turn_id} = notification} ->
        append(state, turn_id, notification)

      :skip ->
        state
    end
  end

  defp translate(event, thread_id) do
    Translate.notification(event, thread_id)
  rescue
    exception ->
      Logger.warning(
        "samgita thread stream skipped untranslatable #{event.type} event: " <>
          inspect(exception.__struct__)
      )

      :skip
  end

  defp append(state, turn_id, notification) do
    {log, new?, state} = log_for(state, turn_id)

    case Replay.append(log, notification) do
      {:ok, message, log} ->
        state = %{state | logs: Map.put(state.logs, turn_id, log)}
        fan_out(state, turn_id, message)
        track_active(state, turn_id, notification["method"], new?)

      {:error, %Error{code: code}} ->
        Logger.warning(
          "samgita thread stream skipped #{notification["method"]} notification rejected by replay: #{code}"
        )

        state
    end
  end

  defp log_for(state, turn_id) do
    case state.logs do
      %{^turn_id => log} ->
        {log, false, state}

      logs ->
        {:ok, log} = Replay.new(turn_id, limit: state.replay_limit)
        {evicted, turns} = Enum.split(state.turns ++ [turn_id], -@retained_turns)
        {log, true, %{state | logs: Map.drop(logs, evicted), turns: turns}}
    end
  end

  defp fan_out(state, turn_id, message) do
    Enum.each(state.sockets, fn
      {_socket, %{skip: ^turn_id}} -> :ok
      {socket, _attachment} -> send(socket, {:protocol_notification, message})
    end)
  end

  defp track_active(state, turn_id, "turn/completed", _new?), do: close(state, turn_id)

  # A turn becomes active on `turn/started`, or on its first event when that arrives first.
  defp track_active(state, turn_id, method, new?) when method == "turn/started" or new?,
    do: %{state | active: turn_id}

  defp track_active(state, _turn_id, _method, _new?), do: state

  defp idle?(state), do: state.sockets == %{} and is_nil(state.active)

  defp schedule_idle(%{idle_timer: nil} = state) do
    if idle?(state) do
      ref = make_ref()
      timer = Process.send_after(self(), {:idle_timeout, ref}, state.idle_timeout)
      %{state | idle_timer: {timer, ref}}
    else
      state
    end
  end

  defp schedule_idle(%{idle_timer: {timer, _ref}} = state) do
    if idle?(state) do
      state
    else
      Process.cancel_timer(timer)
      %{state | idle_timer: nil}
    end
  end
end
