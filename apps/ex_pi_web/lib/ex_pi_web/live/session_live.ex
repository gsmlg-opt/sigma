defmodule ExPiWeb.SessionLive do
  use ExPiWeb, :live_view

  @impl true
  def mount(%{"id" => session_id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ExPiWeb.PubSub, "session:#{session_id}")
    end

    sessions_dir = Path.expand("../../priv/sessions", __DIR__)
    File.mkdir_p!(sessions_dir)
    storage_path = Path.join(sessions_dir, "#{session_id}.jsonl")

    # Replay messages if they exist
    {:ok, initial_messages} = ExPiSession.Log.replay(storage_path)

    {:ok, policy} = ExPiCoding.PermissionPolicy.start_link(default: :ask)

    request_fn = fn tool_call ->
      Phoenix.PubSub.broadcast(ExPiWeb.PubSub, "session:#{session_id}", {:permission_request, self(), tool_call})
      receive do
        {:permission_response, action} -> action
      after
        60_000 -> {:deny, "Timeout"}
      end
    end

    # Subscribe to log events to persist them
    on_event = fn event ->
      ExPiSession.Log.persist_event(storage_path, event)
      Phoenix.PubSub.broadcast(ExPiWeb.PubSub, "session:#{session_id}", event)
    end

    # Get or start agent for this session
    _topic = "session:#{session_id}"

    {:ok, agent} =
      ExPiWeb.SessionManager.get_agent(session_id,
        model: %{id: "mock-model", api: "mock", provider: "mock"},
        provider: MockProvider,
        system_prompt: "You are a helpful assistant.",
        on_event: on_event,
        tools: [ExPiCoding.Tools.Read, ExPiCoding.Tools.Bash, ExPiCoding.Tools.Edit],
        dispatcher_opts: [permission_policy: policy, permission_request_fn: request_fn],
        messages: initial_messages,
        cwd: File.cwd!()
      )

    {:ok, sessions} = ExPiSession.Log.list_sessions(sessions_dir)

    socket =
      socket
      |> assign(:session_id, session_id)
      |> assign(:sessions_dir, sessions_dir)
      |> assign(:agent, agent)
      |> assign(:input, "")
      |> assign(:permission_request, nil)
      |> assign(:sessions, sessions)
      |> stream(:messages, initial_messages)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen relative bg-surface-base text-surface-content">
      <!-- Sidebar -->
      <.dm_left_menu id="sidebar" class="w-64 border-r border-base-content/10">
        <:title>Sessions</:title>
        <.dm_left_menu_group id="sessions-group">
          <:title>Active Sessions</:title>
          <:menu :for={s <- @sessions} to={~p"/sessions/#{s}"} active={s == @session_id}>
            {s}
          </:menu>
        </.dm_left_menu_group>
        <div class="p-4 border-t border-base-content/10">
          <.dm_btn phx-click="fork_session" variant="primary" class="w-full">Fork Session</.dm_btn>
        </div>
      </.dm_left_menu>

      <!-- Main Chat -->
      <div class="flex-1 flex flex-col min-w-0">
        <div id="messages" phx-update="stream" class="flex-1 overflow-y-auto p-4 space-y-4">
          <div :for={{id, message} <- @streams.messages} id={id} class="w-full">
            <.dm_card variant="bordered" class="w-full">
              <:title>
                <span class="text-sm font-mono opacity-60 uppercase">{message.role}</span>
              </:title>
              <div class="mt-2 whitespace-pre-wrap font-sans">
                {render_content(message.content)}
              </div>
            </.dm_card>
          </div>
        </div>

        <div class="p-4 border-t border-base-content/10 bg-surface-base">
          <form phx-submit="send_prompt">
            <.dm_input type="text" name="prompt" value={@input} placeholder="Type a message..." class="w-full" autocomplete="off" />
          </form>
        </div>
      </div>

      <!-- Modal -->
      <.dm_modal :if={@permission_request} id="permission-modal">
        <:title>Permission Required</:title>
        <:body>
          <p class="mb-4">
            The agent wants to call tool <code class="bg-surface-base px-1 rounded">{@permission_request.tool_call.name}</code>
            with arguments:
          </p>
          <pre class="bg-surface-base p-2 rounded mb-4 overflow-x-auto text-sm">{Jason.encode!(@permission_request.tool_call.arguments, pretty: true)}</pre>
        </:body>
        <:footer>
          <.dm_btn phx-click="permission_deny" variant="ghost">Deny</.dm_btn>
          <.dm_btn phx-click="permission_allow" variant="primary">Allow</.dm_btn>
        </:footer>
      </.dm_modal>
    </div>
    """
  end

  defp render_content(content) when is_binary(content), do: content
  defp render_content(content) when is_list(content) do
    Enum.map(content, fn
      %{type: :text, text: text} -> text
      %{type: :thinking, thinking: thinking} -> "[Thinking: #{thinking}]"
      %{type: :tool_call, name: name} -> "[Calling tool: #{name}]"
      _ -> ""
    end)
    |> Enum.join("\n")
  end

  @impl true
  def handle_event("fork_session", _, socket) do
    new_id = "fork_#{System.unique_integer([:positive])}"
    source_path = Path.join(socket.assigns.sessions_dir, "#{socket.assigns.session_id}.jsonl")
    target_path = Path.join(socket.assigns.sessions_dir, "#{new_id}.jsonl")

    # Fork the log (take all current messages)
    {:ok, messages} = ExPiSession.Log.replay(source_path)
    ExPiSession.Log.fork(source_path, target_path, length(messages))

    {:noreply, push_navigate(socket, to: ~p"/sessions/#{new_id}")}
  end

  @impl true
  def handle_event("send_prompt", %{"prompt" => prompt}, socket) do
    ExPiAgent.prompt(socket.assigns.agent, prompt)
    {:noreply, assign(socket, input: "")}
  end

  @impl true
  def handle_event("permission_allow", _, socket) do
    send(socket.assigns.permission_request.from, {:permission_response, :allow})
    {:noreply, assign(socket, :permission_request, nil)}
  end

  @impl true
  def handle_event("permission_deny", _, socket) do
    send(socket.assigns.permission_request.from, {:permission_response, {:deny, "User denied permission"}})
    {:noreply, assign(socket, :permission_request, nil)}
  end

  @impl true
  def handle_info({:message_start, message}, socket) do
    {:noreply, stream_insert(socket, :messages, message)}
  end

  @impl true
  def handle_info({:message_update, message, _event}, socket) do
    {:noreply, stream_insert(socket, :messages, message)}
  end

  @impl true
  def handle_info({:message_end, message}, socket) do
    {:noreply, stream_insert(socket, :messages, message)}
  end

  @impl true
  def handle_info({:permission_request, from_pid, tool_call}, socket) do
    {:noreply, assign(socket, :permission_request, %{from: from_pid, tool_call: tool_call})}
  end

  @impl true
  def handle_info(_event, socket) do
    {:noreply, socket}
  end
end

# Temporary MockProvider for testing
defmodule MockProvider do
  @behaviour ExPiAi.Provider

  @impl true
  def stream(_params) do
    initial_msg = %{
      role: :assistant,
      content: [],
      model: "mock-model",
      provider: "mock-provider",
      api: "mock-api",
      usage: %{input: 0, output: 0, cache_read: 0, cache_write: 0, total_tokens: 0, cost: %{total: 0.0, input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0}},
      stop_reason: nil,
      timestamp: System.system_time(:millisecond)
    }

    delta_msg = %{initial_msg | content: [%{type: :text, text: "I am a mock response."}]}
    done_msg = %{delta_msg | stop_reason: :stop}

    [
      {:start, initial_msg},
      {:text_delta, 0, "I am a mock response.", delta_msg},
      {:done, :stop, done_msg}
    ]
  end
end
