defmodule ExPiWeb.SessionLive do
  use ExPiWeb, :live_view

  @impl true
  def mount(%{"id" => session_id, "workdir" => encoded_workdir}, _session, socket) do
    workdir = Base.url_decode64!(encoded_workdir, padding: false)
    sessions_dir = get_sessions_dir(workdir)
    File.mkdir_p!(sessions_dir)
    storage_path = Path.join(sessions_dir, "#{session_id}.jsonl")

    if connected?(socket) do
      Phoenix.PubSub.subscribe(ExPiWeb.PubSub, "session:#{session_id}")
    end

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
        cwd: workdir
      )

    {:ok, sessions} = ExPiSession.Log.list_sessions(sessions_dir)

    socket =
      socket
      |> assign(:active_tab, :workdir)
      |> assign(:session_id, session_id)
      |> assign(:workdir, workdir)
      |> assign(:encoded_workdir, encoded_workdir)
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
    <div class="flex h-[calc(100vh-64px)] relative bg-surface text-on-surface">
      <!-- Sidebar -->
      <aside class="w-72 bg-secondary text-secondary-content border-r border-outline-variant shrink-0 flex flex-col">
        <div class="p-6 border-b border-secondary-content/10">
          <div class="flex items-center gap-2 mb-1">
            <.dm_mdi name="folder-outline" class="w-4 h-4 opacity-70" />
            <span class="text-xs uppercase tracking-widest font-bold opacity-70">Workspace</span>
          </div>
          <h2 class="font-semibold truncate" title={@workdir}>{Path.basename(@workdir)}</h2>
          <.dm_btn navigate={~p"/workdir/#{@encoded_workdir}"} variant="link" class="p-0 h-auto text-[10px] text-secondary-content hover:underline mt-2 inline-block font-bold">
            Change Directory
          </.dm_btn>
        </div>

        <.dm_left_menu id="sidebar-sessions" class="flex-1 overflow-y-auto px-2 pt-4">
          <:title>Sessions</:title>
          <.dm_left_menu_group id="sessions-list" active={@session_id}>
            <:title>History</:title>
            <:menu :for={s <- @sessions} to={~p"/workdir/#{@encoded_workdir}/sessions/#{s}"} id={s}>
              <div class="flex items-center gap-2 truncate">
                <.dm_mdi name="chat-outline" class="w-4 h-4" />
                <span class="truncate">{s}</span>
              </div>
            </:menu>
          </.dm_left_menu_group>
        </.dm_left_menu>

        <div class="p-4 border-t border-secondary-content/10">
          <.dm_btn phx-click="fork_session" variant="primary" class="w-full">
            <:prefix><.dm_mdi name="source-branch" /></:prefix>
            Fork Branch
          </.dm_btn>
        </div>
      </aside>

      <!-- Main Chat -->
      <div class="flex-1 flex flex-col min-w-0 bg-surface-container-lowest">
        <div id="messages" phx-update="stream" class="flex-1 overflow-y-auto p-6 space-y-6">
          <div :for={{id, message} <- @streams.messages} id={id} class="max-w-4xl mx-auto w-full">
            <.dm_card variant={if message.role == :user, do: "bordered", else: "glass"} shadow="sm" class="overflow-hidden">
              <div class="flex items-start gap-4 p-4 text-on-surface">
                <div class={"mt-1 p-2 rounded-xl #{if message.role == :user, do: "bg-primary text-primary-content", else: "bg-secondary text-secondary-content"}"}>
                  <.dm_mdi name={if message.role == :user, do: "account", else: "robot"} class="w-5 h-5" />
                </div>
                <div class="min-w-0 flex-1">
                  <div class="flex justify-between items-center mb-1">
                    <span class="text-xs font-bold uppercase tracking-wider opacity-60 font-mono">{message.role}</span>
                    <span class="text-[10px] opacity-40 font-mono">{format_timestamp(message.timestamp)}</span>
                  </div>
                  <div class="content whitespace-pre-wrap font-sans text-base leading-relaxed">
                    {render_content(message.content)}
                  </div>
                </div>
              </div>
            </.dm_card>
          </div>
        </div>

        <div class="p-6 border-t border-outline-variant bg-surface">
          <div class="max-w-4xl mx-auto">
            <form phx-submit="send_prompt">
              <div class="relative">
                <.dm_input
                  type="text"
                  name="prompt"
                  value={@input}
                  placeholder="Ask π anything..."
                  class="w-full pr-12"
                  autocomplete="off"
                />
                <div class="absolute right-2 top-1/2 -translate-y-1/2">
                  <.dm_btn type="submit" variant="ghost" shape="circle" size="sm">
                    <.dm_mdi name="send" class="text-primary w-5 h-5" />
                  </.dm_btn>
                </div>
              </div>
            </form>
            <p class="mt-3 text-[10px] text-center text-on-surface-variant opacity-60">
              π is an AI agent. Review its work carefully. Press Enter to send.
            </p>
          </div>
        </div>
      </div>

      <!-- Modal -->
      <.dm_modal :if={@permission_request} id="permission-modal">
        <:title>
          <div class="flex items-center gap-2 text-warning">
            <.dm_mdi name="shield-alert" class="w-6 h-6" />
            <span>Security Interceptor</span>
          </div>
        </:title>
        <:body>
          <p class="mb-4 text-on-surface">
            The agent is requesting permission to execute a <span class="font-bold">{@permission_request.tool_call.name}</span> command.
          </p>
          <div class="bg-surface-container-high p-4 rounded-xl border border-outline-variant text-on-surface">
             <p class="text-xs uppercase tracking-widest font-bold opacity-50 mb-2">Arguments</p>
             <pre class="overflow-x-auto text-sm font-mono leading-relaxed">{Jason.encode!(@permission_request.tool_call.arguments, pretty: true)}</pre>
          </div>
        </:body>
        <:footer>
          <.dm_btn phx-click="permission_deny" variant="ghost">Deny</.dm_btn>
          <.dm_btn phx-click="permission_allow" variant="primary">Authorize Execution</.dm_btn>
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

  defp format_timestamp(ts) when is_integer(ts) do
    ts |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%H:%M:%S")
  end
  defp format_timestamp(_), do: ""

  @impl true
  def handle_event("fork_session", _, socket) do
    new_id = "fork_#{System.unique_integer([:positive])}"
    source_path = Path.join(socket.assigns.sessions_dir, "#{socket.assigns.session_id}.jsonl")
    target_path = Path.join(socket.assigns.sessions_dir, "#{new_id}.jsonl")

    # Fork the log (take all current messages)
    {:ok, messages} = ExPiSession.Log.replay(source_path)
    ExPiSession.Log.fork(source_path, target_path, length(messages))

    {:noreply, push_navigate(socket, to: ~p"/workdir/#{socket.assigns.encoded_workdir}/sessions/#{new_id}")}
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

  defp get_sessions_dir(workdir) do
    encoded_cwd = Base.url_encode64(workdir, padding: false)
    Path.join(ExPiWeb.get_sessions_root(), encoded_cwd)
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
