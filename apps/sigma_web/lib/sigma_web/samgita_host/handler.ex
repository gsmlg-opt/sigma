defmodule Sigma.Web.SamgitaHost.Handler do
  @moduledoc """
  samgita_protocol 1.0 host handler for `/app-server`.

  Translates native requests into Protocol V1 commands executed through
  `Sigma.Agent.PublicRuntime` and maps the results back. Mutating requests are
  deduplicated by `command_id` in `Sigma.Web.SamgitaHost.Commands`. Threads
  this connection starts or resumes are followed through
  `Sigma.Web.SamgitaHost.ThreadStream`, which pushes their notifications to the
  socket process, filtered to the groups this connection negotiated.

  The state lives in the socket process, so `self()` is the socket pid.
  """
  @behaviour SamgitaProtocol.Handler

  alias SamgitaProtocol.{Capabilities, Error}
  alias Sigma.Agent.PublicRuntime
  alias Sigma.Protocol.Envelope
  alias Sigma.Session.{ConfigManager, SessionFiles}
  alias Sigma.Web.ProtocolContext
  alias Sigma.Web.SamgitaHost.{Commands, ThreadId, ThreadStream, Translate}

  @completed_limit 128
  @thread_fields %{"messageCount" => "message_count", "runtime" => "runtime", "turn" => "turn"}

  @impl true
  def capabilities, do: ["sessions.v1", "streaming.v1", "cancellation.v1"]

  @impl true
  def methods, do: Capabilities.methods(capabilities())

  @doc "Initial handler state for a connection authenticated as `principal`."
  @spec state(term()) :: map()
  def state(principal),
    do: %{principal: principal, socket: self(), completed: [], threads: MapSet.new()}

  @impl true
  def handle_request(method, params, context, state) do
    {reply, state} = dispatch(method, params, context, state)
    reply = with {:uncertain, error} <- reply, do: {:error, error}

    state = %{
      state
      | completed: Enum.take([context["request_id"] | state.completed], @completed_limit)
    }

    case reply do
      {:ok, result} -> {:ok, result, state}
      {:error, %Error{} = error} -> {:error, error, state}
    end
  end

  defp dispatch(method, params, context, state) do
    if SamgitaProtocol.Schema.mutating?(method),
      do: idempotent(method, params, context, state),
      else: run(method, params, context, state)
  end

  # A command id is released only for a definite failure: one returned before or
  # by `PublicRuntime.execute/2`. A raise or exit, or a failure after a command
  # took effect (`:uncertain`), keeps it reserved, so a retry gets `conflict`.
  defp idempotent(method, params, %{"command_id" => command_id} = context, state) do
    case Commands.reserve(command_id, {method, params}) do
      :new ->
        case run(method, params, context, state) do
          {{:ok, result}, _state} = done ->
            :ok = Commands.complete(command_id, result)
            done

          {{:error, _error}, _state} = failed ->
            :ok = Commands.release(command_id)
            failed

          {{:uncertain, _error}, _state} = uncertain ->
            uncertain
        end

      {:done, result} ->
        replay(method, result, context, state)

      :conflict ->
        {{:error, Error.new("conflict", %{"reason" => "command_id_conflict"})}, state}
    end
  end

  # A replayed thread/start or thread/resume (typically a retry after a
  # reconnect) leaves this connection following the thread like the original.
  defp replay(method, %{"thread_id" => thread_id} = result, context, state)
       when method in ["thread/start", "thread/resume"] do
    case follow(thread_id, context) do
      {:ok, _active_stream} ->
        if method == "thread/start",
          do: send(self(), {:protocol_notification, Translate.thread_started(thread_id)})

        {{:ok, result}, follows(state, thread_id)}

      error ->
        {failure(error), state}
    end
  end

  defp replay(_method, result, _context, state), do: {{:ok, result}, state}

  defp run("thread/start", params, context, state) do
    metadata = params["metadata"] || %{}

    with {:ok, repo_path} <- ThreadId.repository(metadata["repository"]),
         session_id = session_id(),
         scope = %{
           repo_path: repo_path,
           sessions_dir: ConfigManager.ensure_sessions_dir(repo_path),
           session_id: session_id
         },
         {:ok, snapshot} <- execute(scope, "session.create", create_payload(repo_path, params)),
         thread_id = ThreadId.encode(repo_path, session_id),
         {:ok, active_stream} <- effected(follow(thread_id, context)) do
      send(self(), {:protocol_notification, Translate.thread_started(thread_id)})

      {{:ok, %{"thread_id" => thread_id, "thread" => thread(snapshot, active_stream)}},
       follows(state, thread_id)}
    else
      error -> {failure(error), state}
    end
  end

  defp run("thread/read", %{"thread_id" => thread_id}, context, state) do
    with {:ok, scope} <- scope(thread_id),
         {:ok, status} <- execute(scope, "session.status", %{}) do
      {{:ok,
        %{
          "thread_id" => thread_id,
          "thread" => thread(status, followed(state, thread_id, context))
        }}, state}
    else
      error -> {failure(error), state}
    end
  end

  defp run("thread/resume", %{"thread_id" => thread_id}, context, state) do
    with {:ok, scope} <- scope(thread_id),
         {:ok, _snapshot} <- execute(scope, "session.resume", %{}),
         {:ok, active_stream} <- effected(follow(thread_id, context)),
         {:ok, status} <- effected(execute(scope, "session.status", %{})) do
      {{:ok, %{"thread_id" => thread_id, "thread" => thread(status, active_stream)}},
       follows(state, thread_id)}
    else
      error -> {failure(error), state}
    end
  end

  defp run("turn/start", %{"thread_id" => thread_id, "input" => input}, context, state) do
    refollow(state, thread_id, context)
    payload = %{"content" => text(input), "admission" => "reject_if_busy"}
    {admit(thread_id, "prompt.submit", payload), state}
  end

  defp run(
         "turn/steer",
         %{"thread_id" => thread_id, "turn_id" => turn_id, "input" => input},
         context,
         state
       ) do
    refollow(state, thread_id, context)
    payload = %{"content" => text(input), "expectedTurnId" => turn_id}
    {admit(thread_id, "prompt.steer", payload), state}
  end

  defp run("turn/interrupt", %{"thread_id" => thread_id, "turn_id" => turn_id}, _context, state) do
    reply =
      with {:ok, scope} <- scope(thread_id),
           {:ok, status} <-
             scope
             |> execute("turn.cancel", %{"expectedTurnId" => turn_id})
             |> interrupt_status(turn_id) do
        {:ok, %{"thread_id" => thread_id, "turn_id" => turn_id, "status" => status}}
      else
        error -> failure(error)
      end

    {reply, state}
  end

  defp run("stream/resume", %{"stream_id" => stream_id, "cursor" => cursor}, _context, state) do
    reply =
      Enum.reduce_while(state.threads, {:error, Error.new("replay_gap")}, fn thread_id, gap ->
        case ThreadStream.resume(thread_id, stream_id, cursor) do
          {:ok, events} -> {:halt, {:ok, replay_page(stream_id, cursor, events)}}
          {:error, _} -> {:cont, gap}
        end
      end)

    {reply, state}
  end

  defp run("request/cancel", %{"request_id" => request_id}, _context, state) do
    reply =
      if request_id in state.completed,
        do: {:ok, %{"request_id" => request_id, "status" => "already_finished"}},
        else: {:error, Error.new("not_found")}

    {reply, state}
  end

  defp admit(thread_id, type, payload) do
    with {:ok, scope} <- scope(thread_id),
         {:ok, %{"turnId" => turn_id}} <- execute(scope, type, payload) do
      {:ok, %{"thread_id" => thread_id, "turn_id" => turn_id, "status" => "running"}}
    else
      error -> failure(error)
    end
  end

  defp interrupt_status(
         {:ok, %{"cancellation" => %{"status" => status, "turnId" => id}}},
         turn_id
       ) do
    case status do
      status when status in ["cancelling", "already_cancelling"] -> {:ok, "requested"}
      "already_cancelled" when id == turn_id -> {:ok, "interrupted"}
      "already_cancelled" -> {:ok, "already_finished"}
      _other -> {:error, :invalid_cancel_result}
    end
  end

  defp interrupt_status({:error, %Envelope{error: %{code: "no_active_turn"}}}, _turn_id),
    do: {:ok, "already_finished"}

  defp interrupt_status(error, _turn_id), do: error

  defp replay_page(stream_id, cursor, events) do
    last = if events == [], do: cursor, else: List.last(events)["cursor"]
    %{"stream_id" => stream_id, "cursor" => last, "events" => events}
  end

  # A failure after a command took effect leaves the request outcome uncertain.
  defp effected({:error, reason}), do: {:uncertain, reason}
  defp effected(result), do: result

  # Follows the thread's stream from this socket, filtered to the negotiated
  # groups. Right after a stream exits, `ensure` may still return the dying
  # process, so a lost attach is retried once.
  defp follow(thread_id, context, retries \\ 1) do
    opts = [capabilities: context["capabilities"]]

    with {:ok, _pid} <- ThreadStream.ensure(thread_id),
         {:ok, %{active_stream: active_stream}} <-
           ThreadStream.attach(thread_id, self(), opts) do
      {:ok, active_stream}
    else
      {:error, :not_found} when retries > 0 -> follow(thread_id, context, retries - 1)
      {:error, :not_found} = error -> error
    end
  end

  # Only threads this connection follows report their active stream; attaching
  # again is idempotent for an already attached socket.
  defp followed(state, thread_id, context) do
    with true <- MapSet.member?(state.threads, thread_id),
         {:ok, active_stream} <- follow(thread_id, context) do
      active_stream
    else
      _ -> nil
    end
  end

  # The stream stops when the session agent exits; re-attaching before a turn is
  # admitted lets a session restarted elsewhere stream to this connection again.
  # When the session is still stopped this fails and the turn is rejected with
  # `session_not_running`.
  defp refollow(state, thread_id, context) do
    if MapSet.member?(state.threads, thread_id), do: follow(thread_id, context)
    :ok
  end

  defp follows(state, thread_id), do: %{state | threads: MapSet.put(state.threads, thread_id)}

  defp thread(payload, active_stream) do
    payload
    |> Map.take(Map.keys(@thread_fields))
    |> Map.new(fn {key, value} -> {@thread_fields[key], value} end)
    |> Map.put("active_stream", active_stream)
  end

  defp scope(thread_id) do
    with {:ok, scope} <- ThreadId.decode(thread_id),
         {:ok, journal} <- SessionFiles.jsonl_path(scope.sessions_dir, scope.session_id),
         true <- File.regular?(journal) do
      {:ok, scope}
    else
      _ -> {:error, :not_found}
    end
  end

  defp execute(scope, type, payload) do
    with {:ok, command} <- Envelope.command(type, scope.session_id, payload),
         {:ok, prepared} <- ProtocolContext.prepare(command, scope.repo_path),
         {:ok, %Envelope{payload: result}} <-
           PublicRuntime.execute(prepared, context(scope, prepared)) do
      {:ok, result}
    end
  end

  defp context(scope, command) do
    ProtocolContext.build(
      %{
        workdir: scope.repo_path,
        sessions_dir: scope.sessions_dir,
        session_id: scope.session_id,
        subscriber: self()
      },
      interactive_approvals: false,
      initial_metadata: initial_metadata(command)
    )
  end

  defp initial_metadata(%Envelope{type: "session.create", payload: payload}),
    do: payload["metadata"]

  defp initial_metadata(_command), do: nil

  defp create_payload(repo_path, params) do
    {overrides, metadata} =
      (params["metadata"] || %{})
      |> Map.delete("repository")
      |> Map.split(["provider_id", "model_id"])

    metadata = if params["title"], do: Map.put(metadata, "title", params["title"]), else: metadata

    %{"cwd" => repo_path, "metadata" => metadata}
    |> put_override("providerId", overrides["provider_id"])
    |> put_override("modelId", overrides["model_id"])
  end

  defp put_override(payload, _key, nil), do: payload
  defp put_override(payload, key, value), do: Map.put(payload, key, value)

  defp text(input), do: Enum.map_join(input, "\n\n", & &1["text"])

  defp session_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp failure({:uncertain, reason}) do
    {:error, error} = failure({:error, reason})
    {:uncertain, error}
  end

  defp failure({:error, %Error{} = error}), do: {:error, error}
  defp failure({:error, reason}), do: {:error, Translate.error(reason)}
  defp failure(_unexpected), do: {:error, Error.new("handler_error")}
end
