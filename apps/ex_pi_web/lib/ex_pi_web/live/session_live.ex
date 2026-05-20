defmodule PiWeb.SessionLive do
  use PiWeb, :live_view

  alias PiSession.ConfigManager

  @impl true
  def mount(%{"id" => session_id, "repository" => encoded_repository}, _session, socket) do
    workdir = Base.url_decode64!(encoded_repository, padding: false)
    sessions_dir = get_sessions_dir(workdir)
    File.mkdir_p!(sessions_dir)
    storage_path = Path.join(sessions_dir, "#{session_id}.jsonl")

    system_config = ConfigManager.get_config()

    config =
      Application.get_env(:ex_pi_web, :test_provider_config) ||
        ConfigManager.get_active_provider_config()

    global_prompt = Map.get(system_config, "system_prompt")
    system_prompt = PiSession.ContextFiles.assemble(global_prompt, workdir)

    case resolve_provider(config) do
      {:error, reason} ->
        {:ok, socket |> put_flash(:error, reason) |> push_navigate(to: ~p"/settings")}

      {:ok, {provider_mod, model_id, provider_id, api_key, base_url}} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(PiWeb.PubSub, "session:#{session_id}")
        end

        {:ok, initial_messages} = PiSession.Log.replay(storage_path)

        on_event = fn event ->
          PiSession.Log.persist_event(storage_path, event)
          Phoenix.PubSub.broadcast(PiWeb.PubSub, "session:#{session_id}", event)
        end

        {:ok, {agent, _policy}} =
          PiWeb.SessionManager.get_agent(session_id,
            model: %{id: model_id, api: provider_id, provider: provider_id},
            provider: provider_mod,
            options: [api_key: api_key, base_url: base_url],
            system_prompt: system_prompt,
            on_event: on_event,
            tools: [
              PiCoding.Tools.Read,
              PiCoding.Tools.Write,
              PiCoding.Tools.Bash,
              PiCoding.Tools.Edit,
              PiCoding.Tools.Glob,
              PiCoding.Tools.Grep,
              PiCoding.Tools.LS,
              PiCoding.Tools.UrlFetch
            ],
            dispatcher_opts: [],
            messages: initial_messages,
            cwd: workdir
          )

        if connected?(socket) do
          Process.monitor(agent)
        end

        {:ok, sessions} = PiSession.Log.list_sessions(sessions_dir)

        active_provider = system_config["providers"][provider_id] || %{}
        available_models = active_provider["models"] || [model_id]

        socket =
          socket
          |> assign(:active_tab, :repository)
          |> assign(:session_id, session_id)
          |> assign(:workdir, workdir)
          |> assign(:encoded_repository, encoded_repository)
          |> assign(:sessions_dir, sessions_dir)
          |> assign(:agent, agent)
          |> assign(:input, "")
          |> assign(:turn_in_flight, false)
          |> assign(:sessions, sessions)
          |> assign(:active_provider_id, provider_id)
          |> assign(:current_model, model_id)
          |> assign(:available_models, available_models)
          |> stream(:messages, initial_messages)

        {:ok, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-[calc(100vh-64px)] relative bg-surface text-on-surface font-sans">
      <!-- Sidebar -->
      <aside class="w-72 bg-secondary text-secondary-content border-r border-outline-variant shrink-0 flex flex-col">
        <div class="p-6 border-b border-secondary-content/10 text-on-secondary">
          <div class="flex items-center gap-2 mb-1">
            <.dm_mdi name="folder-outline" class="w-4 h-4 opacity-70" />
            <span class="text-xs uppercase tracking-widest font-bold opacity-70">Workspace</span>
          </div>
          <h2 class="font-semibold truncate" title={@workdir}>{Path.basename(@workdir)}</h2>
          <.dm_link
            navigate={~p"/repository/#{@encoded_repository}"}
            class="text-[10px] text-primary-content hover:underline mt-2 inline-block font-bold"
          >
            Session List
          </.dm_link>
        </div>

        <.dm_left_menu id="sidebar-sessions" class="flex-1 overflow-y-auto px-2 pt-4">
          <:title>Sessions</:title>
          <:menu>
            <.dm_left_menu_group id="sessions-list" active={@session_id}>
              <:title>History</:title>
              <:menu
                :for={s <- @sessions}
                to={~p"/repository/#{@encoded_repository}/sessions/#{s}"}
                id={"session-link-#{s}"}
              >
                <div class="flex items-center gap-2 truncate">
                  <.dm_mdi name="chat-outline" class="w-4 h-4" />
                  <span class="truncate">{s}</span>
                </div>
              </:menu>
            </.dm_left_menu_group>
          </:menu>
        </.dm_left_menu>

        <div class="p-4 border-t border-secondary-content/10 text-center">
          <.dm_btn
            id="fork-session-btn"
            phx-click="fork_session"
            phx-hook="WebComponentHook"
            variant="primary"
            class="w-full"
          >
            <:prefix><.dm_mdi name="source-branch" class="w-4 h-4" /></:prefix>
            Fork Branch
          </.dm_btn>
        </div>
      </aside>

      <!-- Main Chat -->
      <div class="flex-1 flex flex-col min-w-0 bg-surface-container-lowest">
        <div id="messages" phx-update="stream" phx-hook="ScrollBottom" class="flex-1 overflow-y-auto p-6 space-y-6">
          <div :for={{id, message} <- @streams.messages} id={id} class="max-w-4xl mx-auto w-full">
            <.dm_card
              variant={if message.role == :user, do: "bordered", else: "glass"}
              shadow="sm"
              class="overflow-hidden"
            >
              <div class="flex items-start gap-4 p-4 text-on-surface">
                <div class={[
                  "mt-1 p-2 rounded-xl",
                  message.role == :user && "bg-primary text-primary-content",
                  message.role == :tool_result && "bg-tertiary text-tertiary-content",
                  message.role not in [:user, :tool_result] && "bg-secondary text-secondary-content"
                ]}>
                  <.dm_mdi
                    name={
                      case message.role do
                        :user -> "account"
                        :tool_result -> "console"
                        _ -> "robot"
                      end
                    }
                    class="w-5 h-5"
                  />
                </div>
                <div class="min-w-0 flex-1">
                  <div class="flex justify-between items-center mb-1">
                    <span class="text-xs font-bold uppercase tracking-wider opacity-60 font-mono">
                      {role_label(message)}
                    </span>
                    <div class="flex items-center gap-2">
                      <span :if={message.is_error} class="text-[10px] font-bold text-error font-mono">
                        ERROR
                      </span>
                      <span class="text-[10px] opacity-40 font-mono">
                        {format_timestamp(message.timestamp)}
                      </span>
                      <.dm_btn
                        :if={message.id != nil}
                        id={"fork-at-#{message.id}"}
                        phx-click="fork_at"
                        phx-value-msg-id={message.id}
                        phx-hook="WebComponentHook"
                        variant="ghost"
                        size="xs"
                        title="Fork session from here"
                      >
                        <.dm_mdi name="source-branch" class="w-3 h-3 opacity-50 hover:opacity-100" />
                      </.dm_btn>
                    </div>
                  </div>
                  <div
                    :if={message.role in [:assistant, :compaction_summary]}
                    id={"md-#{message.id}"}
                    phx-hook="MarkdownContent"
                    data-content={render_content(message.content)}
                    class="content markdown font-sans text-base leading-relaxed"
                  >
                  </div>
                  <div
                    :if={message.role not in [:assistant, :compaction_summary]}
                    class={[
                      "content whitespace-pre-wrap font-sans text-base leading-relaxed",
                      message.is_error && "text-error"
                    ]}
                  >
                    {render_content(message.content)}
                  </div>
                  <div
                    :if={message.role == :assistant and not is_nil(message.usage)}
                    class="mt-2 flex gap-3 text-[10px] font-mono opacity-40"
                  >
                    <span>in: {message.usage.input}</span>
                    <span>out: {message.usage.output}</span>
                    <span :if={not is_nil(get_in(message.usage, [:cost, :total]))}>
                      ${format_cost(get_in(message.usage, [:cost, :total]))}
                    </span>
                  </div>
                </div>
              </div>
            </.dm_card>
          </div>
        </div>

        <div class="p-6 border-t border-outline-variant bg-surface">
          <div class="max-w-4xl mx-auto">
            <!-- Agent status banner: only visible while a turn is in flight -->
            <div
              :if={@turn_in_flight}
              id="agent-status"
              role="status"
              aria-live="polite"
              class="mb-3 flex items-center gap-3 px-4 py-2 rounded-xl bg-primary-container/40 border border-primary/30 text-on-surface"
            >
              <.dm_loading_spinner size="sm" variant="primary" />
              <span class="text-sm font-medium">Agent is working…</span>
              <span class="text-[10px] opacity-60 ml-auto font-mono">streaming</span>
            </div>

            <form phx-submit="send_prompt">
              <div class="relative">
                <textarea
                  id="prompt-input"
                  name="prompt"
                  rows="3"
                  phx-hook="ChatInput"
                  placeholder="Ask π anything… (Markdown supported, Shift+Enter for newline)"
                  class="w-full pr-12 px-4 py-3 rounded-2xl border border-outline-variant bg-surface-container focus:border-primary focus:outline-none resize-none font-mono text-sm leading-relaxed"
                  autocomplete="off"
                  spellcheck="false"
                >{@input}</textarea>
                <div class="absolute right-2 bottom-2 flex gap-1">
                  <.dm_btn
                    :if={@turn_in_flight}
                    id="cancel-turn-btn"
                    type="button"
                    phx-click="cancel_turn"
                    phx-hook="WebComponentHook"
                    variant="ghost"
                    shape="circle"
                    size="sm"
                  >
                    <.dm_mdi name="stop" class="text-error w-5 h-5" />
                  </.dm_btn>
                  <.dm_btn
                    id="send-prompt-btn"
                    type="submit"
                    variant="ghost"
                    shape="circle"
                    size="sm"
                    phx-hook="WebComponentHook"
                  >
                    <.dm_mdi name="send" class="text-primary w-5 h-5" />
                  </.dm_btn>
                </div>
              </div>
            </form>

            <!-- Footer row: model selector + hint -->
            <div class="mt-3 flex items-center justify-between gap-4 text-[11px] text-on-surface-variant">
              <form phx-change="select_model" class="flex items-center gap-2">
                <label for="model-select" class="opacity-60 font-medium">Model</label>
                <select
                  id="model-select"
                  name="model"
                  class="px-2 py-1 rounded-lg border border-outline-variant bg-surface-container text-on-surface text-xs focus:border-primary focus:outline-none font-mono"
                >
                  <option
                    :for={m <- ensure_in_list(@available_models, @current_model)}
                    value={m}
                    selected={m == @current_model}
                  >{m}</option>
                </select>
                <span :if={@active_provider_id != nil} class="opacity-40 font-mono">
                  · {@active_provider_id}
                </span>
              </form>
              <p class="opacity-60 text-right">
                π is an AI agent. Review its work carefully. Enter sends, Shift+Enter for newline.
              </p>
            </div>
          </div>
        </div>
      </div>

    </div>
    """
  end

  defp render_content(content) when is_binary(content), do: content

  defp render_content(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{type: :text, text: text} -> text
      %{type: :thinking} -> "[Thinking...]"
      %{type: :tool_call, name: name} -> "→ #{name}(...)"
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp render_content(_), do: ""

  defp role_label(%{role: :tool_result, tool_name: name}) when is_binary(name),
    do: "tool: #{name}"

  defp role_label(%{role: :compaction_summary}), do: "compacted summary"
  defp role_label(%{role: role}), do: role

  defp format_timestamp(ts) when is_integer(ts) do
    ts |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%H:%M:%S")
  end

  defp format_timestamp(_), do: ""

  defp format_cost(cost) when is_float(cost) and cost < 0.001,
    do: :erlang.float_to_binary(cost, decimals: 6)

  defp format_cost(cost) when is_float(cost),
    do: :erlang.float_to_binary(cost, decimals: 4)

  defp format_cost(_), do: "?"

  # Defensive: even if the current model isn't in the configured list
  # (e.g. user is running with a value set outside the UI), include it
  # in the dropdown so the visible selection matches reality.
  defp ensure_in_list(list, nil), do: list || []
  defp ensure_in_list(nil, current), do: [current]

  defp ensure_in_list(list, current) do
    if current in list, do: list, else: [current | list]
  end

  @impl true
  def handle_event("fork_session", _, socket) do
    do_fork(socket, :all)
  end

  @impl true
  def handle_event("fork_at", %{"msg-id" => msg_id}, socket) do
    do_fork(socket, {:at, msg_id})
  end

  @impl true
  def handle_event("cancel_turn", _, socket) do
    PiAgent.cancel(socket.assigns.agent)
    {:noreply, socket}
  end

  @impl true
  def handle_event("send_prompt", %{"prompt" => prompt}, socket) do
    case String.trim(prompt) do
      "" ->
        {:noreply, socket}

      trimmed ->
        PiAgent.prompt(socket.assigns.agent, trimmed)
        {:noreply, assign(socket, input: "")}
    end
  end

  @impl true
  def handle_event("select_model", %{"model" => model_id}, socket) do
    provider_id = socket.assigns.active_provider_id

    PiAgent.set_model(socket.assigns.agent, %{
      id: model_id,
      api: provider_id,
      provider: provider_id
    })

    ConfigManager.update_provider(provider_id, %{"model" => model_id})

    {:noreply, assign(socket, current_model: model_id)}
  end

  @impl true
  def handle_info({:agent_start, _cwd}, socket) do
    {:noreply, assign(socket, :turn_in_flight, true)}
  end

  @impl true
  def handle_info({:agent_end, _}, socket) do
    {:noreply, assign(socket, :turn_in_flight, false)}
  end

  @impl true
  def handle_info({:turn_cancelled}, socket) do
    {:noreply, assign(socket, :turn_in_flight, false)}
  end

  @impl true
  def handle_info({:turn_error, reason}, socket) do
    msg = if is_binary(reason), do: reason, else: inspect(reason)

    {:noreply,
     socket
     |> put_flash(:error, "Turn failed: #{msg}")
     |> assign(:turn_in_flight, false)}
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
  def handle_info({:compact, summary_msg, _first_kept_id}, socket) do
    socket =
      socket
      |> stream_insert(:messages, summary_msg)
      |> put_flash(
        :info,
        "Context compacted — older messages summarized to stay within token limits."
      )

    {:noreply, socket}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket) do
    socket =
      socket
      |> put_flash(
        :error,
        "The agent process crashed. Your session history is preserved — refresh to reconnect."
      )
      |> assign(:turn_in_flight, false)

    {:noreply, socket}
  end

  @impl true
  def handle_info(_event, socket) do
    {:noreply, socket}
  end

  defp do_fork(socket, mode) do
    new_id = "fork_#{System.unique_integer([:positive])}"
    source_path = Path.join(socket.assigns.sessions_dir, "#{socket.assigns.session_id}.jsonl")
    target_path = Path.join(socket.assigns.sessions_dir, "#{new_id}.jsonl")
    workdir = socket.assigns.workdir

    case mode do
      :all ->
        PiSession.Log.fork_at_message(source_path, target_path, :all, workdir)

      {:at, msg_id} ->
        PiSession.Log.fork_at_message(source_path, target_path, msg_id, workdir)
    end

    {:noreply,
     push_navigate(socket,
       to: ~p"/repository/#{socket.assigns.encoded_repository}/sessions/#{new_id}"
     )}
  end

  defp resolve_provider(nil) do
    case Application.get_env(:ex_pi_web, :test_provider_config) do
      nil -> {:error, "No provider configured. Go to Settings to add one."}
      config -> resolve_provider(config)
    end
  end

  defp resolve_provider(config) do
    provider_mod =
      case config["api_type"] do
        "anthropic" -> PiAi.Providers.Anthropic
        "openai" -> PiAi.Providers.OpenAI
        _ -> Application.get_env(:ex_pi_web, :mock_provider_module)
      end

    cond do
      is_nil(provider_mod) ->
        {:error, "Unknown provider type: #{config["api_type"]}"}

      config["model"] in [nil, ""] ->
        {:error,
         "No model configured for provider #{config["name"]}. Go to Settings to configure one."}

      true ->
        {:ok,
         {provider_mod, config["model"], config["id"], config["resolved_key"] || "",
          config["base_url"] || ""}}
    end
  end

  defp get_sessions_dir(workdir) do
    encoded_cwd = Base.url_encode64(workdir, padding: false)
    Path.join(PiWeb.get_sessions_root(), encoded_cwd)
  end
end
