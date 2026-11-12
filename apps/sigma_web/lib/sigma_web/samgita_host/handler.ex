defmodule Sigma.Web.SamgitaHost.Handler do
  @moduledoc """
  samgita_protocol 1.0 host handler for `/app-server`.

  Translates native requests into Protocol V1 commands executed through
  `Sigma.Agent.PublicRuntime` and maps the results back. Mutating requests are
  deduplicated by `command_id` in `Sigma.Web.SamgitaHost.Commands`. Threads
  this connection starts or resumes are followed through
  `Sigma.Web.SamgitaHost.ThreadStream`, which pushes their notifications to the
  socket process.

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

  # TODO(upstream): gsmlg-opt/Samgita#1 — clients are required to offer all three
  # groups. The socket drops notifications of a group the connection did not
  # negotiate (closed with 1008 before samgita_protocol_websocket 0.4.1), so a
  # sessions-only client would silently miss item streaming.
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
      do: idempotent(method, params, context["command_id"], state),
      else: run(method, params, state)
  end

  defp idempotent(method, params, command_id, state) do
    case Commands.reserve(command_id, {method, params}) do
      :new ->
        try do
          run(method, params, state)
        catch
          kind, reason ->
            :ok = Commands.release(command_id)
            :erlang.raise(kind, reason, __STACKTRACE__)
        else
          {{:ok, result}, _state} = done ->
            :ok = Commands.complete(command_id, result)
            done

          {{:error, _error}, _state} = failed ->
            :ok = Commands.release(command_id)
            failed
        end

      {:done, result} ->
        {{:ok, result}, state}

      :conflict ->
        {{:error, Error.new("conflict")}, state}
    end
  end

  defp run("thread/start", params, state) do
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
         {:ok, active_stream} <- follow(thread_id) do
      send(self(), {:protocol_notification, Translate.thread_started(thread_id)})

      {{:ok, %{"thread_id" => thread_id, "thread" => thread(snapshot, active_stream)}},
       follows(state, thread_id)}
    else
      error -> {failure(error), state}
    end
  end

  defp run("thread/read", %{"thread_id" => thread_id}, state) do
    with {:ok, scope} <- scope(thread_id),
         {:ok, status} <- execute(scope, "session.status", %{}) do
      {{:ok, %{"thread_id" => thread_id, "thread" => thread(status, followed(state, thread_id))}},
       state}
    else
      error -> {failure(error), state}
    end
  end

  defp run("thread/resume", %{"thread_id" => thread_id}, state) do
    with {:ok, scope} <- scope(thread_id),
         {:ok, _snapshot} <- execute(scope, "session.resume", %{}),
         {:ok, active_stream} <- follow(thread_id),
         {:ok, status} <- execute(scope, "session.status", %{}) do
      {{:ok, %{"thread_id" => thread_id, "thread" => thread(status, active_stream)}},
       follows(state, thread_id)}
    else
      error -> {failure(error), state}
    end
  end

  defp run("turn/start", %{"thread_id" => thread_id, "input" => input}, state) do
    payload = %{"content" => text(input), "admission" => "reject_if_busy"}
    {admit(thread_id, "prompt.submit", payload), state}
  end

  defp run(
         "turn/steer",
         %{"thread_id" => thread_id, "turn_id" => turn_id, "input" => input},
         state
       ) do
    payload = %{"content" => text(input), "expectedTurnId" => turn_id}
    {admit(thread_id, "prompt.steer", payload), state}
  end

  defp run("turn/interrupt", %{"thread_id" => thread_id, "turn_id" => turn_id}, state) do
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

  defp run("stream/resume", %{"stream_id" => stream_id, "cursor" => cursor}, state) do
    reply =
      Enum.reduce_while(state.threads, {:error, Error.new("replay_gap")}, fn thread_id, gap ->
        case ThreadStream.resume(thread_id, stream_id, cursor) do
          {:ok, events} -> {:halt, {:ok, replay_page(stream_id, cursor, events)}}
          {:error, _} -> {:cont, gap}
        end
      end)

    {reply, state}
  end

  defp run("request/cancel", %{"request_id" => request_id}, state) do
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

  # Follows the thread's stream from this socket. Right after a stream exits,
  # `ensure` may still return the dying process, so a lost attach is retried once.
  defp follow(thread_id, retries \\ 1) do
    with {:ok, _pid} <- ThreadStream.ensure(thread_id),
         {:ok, %{active_stream: active_stream}} <- ThreadStream.attach(thread_id, self()) do
      {:ok, active_stream}
    else
      {:error, :not_found} when retries > 0 -> follow(thread_id, retries - 1)
      {:error, :not_found} = error -> error
    end
  end

  # Only threads this connection follows report their active stream; attaching
  # again is idempotent for an already attached socket.
  defp followed(state, thread_id) do
    with true <- MapSet.member?(state.threads, thread_id),
         {:ok, active_stream} <- follow(thread_id) do
      active_stream
    else
      _ -> nil
    end
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

  defp session_id,
    do: "session_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  defp failure({:error, %Error{} = error}), do: {:error, error}
  defp failure({:error, reason}), do: {:error, Translate.error(reason)}
  defp failure(_unexpected), do: {:error, Error.new("handler_error")}
end
