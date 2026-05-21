defmodule PiWeb.SessionLive do
  use PiWeb, :live_view

  alias PiSession.ConfigManager

  @impl true
  def mount(%{"id" => session_id, "repository" => encoded_repository}, _session, socket) do
    workdir = Base.url_decode64!(encoded_repository, padding: false)
    sessions_dir = get_sessions_dir(workdir)
    File.mkdir_p!(sessions_dir)
    storage_path = Path.join(sessions_dir, "#{session_id}.jsonl")

    meta_path = Path.join(sessions_dir, "#{session_id}.meta.json")
    session_meta = read_session_meta(meta_path)
    effective_cwd = Map.get(session_meta, "cwd", workdir)
    session_branch = Map.get(session_meta, "branch")

    system_config = ConfigManager.get_config()

    config =
      Application.get_env(:ex_pi_web, :test_provider_config) ||
        ConfigManager.get_active_provider_config()

    global_prompt = Map.get(system_config, "system_prompt")
    system_prompt = PiSession.ContextFiles.assemble(global_prompt, effective_cwd)

    system_prompt =
      if effective_cwd != workdir and session_branch do
        "# Worktree Context\nYou are working in a git worktree for branch `#{session_branch}` at `#{effective_cwd}`. The project root is at `#{workdir}`.\n\n" <>
          system_prompt
      else
        system_prompt
      end

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
            cwd: effective_cwd
          )

        if connected?(socket) do
          Process.monitor(agent)
        end

        {:ok, sessions} = PiSession.Log.list_sessions(sessions_dir)

        active_provider = system_config["providers"][provider_id] || %{}
        available_models = active_provider["models"] || [model_id]

        {stream_messages, tool_results, tool_call_to_msg} = split_messages(initial_messages)

        socket =
          socket
          |> assign(:active_tab, :repository)
          |> assign(:session_id, session_id)
          |> assign(:workdir, workdir)
          |> assign(:encoded_repository, encoded_repository)
          |> assign(:sessions_dir, sessions_dir)
          |> assign(:agent, agent)
          |> assign(:turn_in_flight, false)
          |> assign(:streaming_message_id, nil)
          |> assign(:tool_results, tool_results)
          |> assign(:tool_call_to_msg, tool_call_to_msg)
          |> assign(:sessions, sessions)
          |> assign(:active_provider_id, provider_id)
          |> assign(:current_model, model_id)
          |> assign(:available_models, available_models)
          |> stream(:messages, stream_messages)

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
              <:title></:title>
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
          <.dm_link
            navigate={~p"/repository/#{@encoded_repository}/sessions/new"}
            class="btn btn-primary w-full"
          >
            <.dm_mdi name="plus" class="w-4 h-4 mr-1" /> New Session
          </.dm_link>
        </div>
      </aside>

      <!-- Main Chat -->
      <div class="flex-1 flex flex-col min-w-0 bg-surface-container-lowest">
        <div id="messages" phx-update="stream" phx-hook="ScrollBottom" class="flex-1 overflow-y-auto p-6 space-y-2">
          <div :for={{id, message} <- @streams.messages} id={id} class="max-w-4xl mx-auto w-full">
            <.message_bubble
              message={message}
              tool_results={@tool_results}
              streaming_message_id={@streaming_message_id}
              encoded_repository={@encoded_repository}
            />
          </div>
        </div>

        <div class="p-6 border-t border-outline-variant bg-surface">
          <div class="max-w-4xl mx-auto">
            <div :if={@turn_in_flight} class="mb-3 flex items-center justify-between gap-3">
              <div class="flex items-center gap-3 text-sm text-on-surface-variant">
                <.dm_chat_typing />
                <span>Agent is working…</span>
              </div>
              <.dm_btn
                id="cancel-turn-btn"
                type="button"
                phx-click="cancel_turn"
                phx-hook="WebComponentHook"
                variant="ghost"
                size="sm"
              >
                <:prefix><.dm_mdi name="stop" class="text-error w-4 h-4" /></:prefix>
                Stop
              </.dm_btn>
            </div>

            <.dm_chat_input
              id="prompt-input"
              placeholder="Ask π anything… (Ctrl+Enter to send)"
              disabled={@turn_in_flight}
              clear_on_send={true}
              duskmoon-send-send="send_prompt"
            />

            <div class="mt-3 flex items-center justify-between gap-4 text-[11px] text-on-surface-variant">
              <form phx-change="select_model" class="flex items-center gap-2">
                <label class="opacity-60 font-medium text-[11px]">Model</label>
                <.dm_select id="model-select" name="model" value={@current_model} size="xs">
                  <option
                    :for={m <- ensure_in_list(@available_models, @current_model)}
                    value={m}
                    selected={m == @current_model}
                  >{m}</option>
                </.dm_select>
                <span :if={@active_provider_id != nil} class="opacity-40 font-mono">
                  · {@active_provider_id}
                </span>
              </form>
              <p class="opacity-60 text-right">
                π is an AI agent. Review its work carefully.
              </p>
            </div>
          </div>
        </div>
      </div>

    </div>
    """
  end

  defp message_bubble(%{message: %{role: :user}} = assigns) do
    ~H"""
    <.dm_chat
      id={@message.id}
      align="end"
      variant="filled"
      color="secondary"
      avatar="You"
      time={format_timestamp(@message.timestamp)}
      content={user_content(@message.content)}
    />
    """
  end

  defp message_bubble(%{message: %{role: :assistant}} = assigns) do
    ~H"""
    <.dm_chat
      id={@message.id}
      align="start"
      avatar="π"
      time={format_timestamp(@message.timestamp)}
      streaming={@message.id == @streaming_message_id}
    >
      <.content_block
        :for={block <- List.wrap(@message.content)}
        block={block}
        tool_results={@tool_results}
      />
      <:footer :if={not is_nil(@message.usage)}>
        <span class="text-[10px] opacity-40 font-mono">
          in: {@message.usage.input} · out: {@message.usage.output}
        </span>
      </:footer>
      <:actions_slot>
        <.dm_btn
          id={"fork-at-#{@message.id}"}
          phx-click="fork_at"
          phx-value-msg-id={@message.id}
          phx-hook="WebComponentHook"
          variant="ghost"
          size="xs"
          title="Fork session from here"
        >
          <.dm_mdi name="source-branch" class="w-3 h-3" />
        </.dm_btn>
      </:actions_slot>
    </.dm_chat>
    """
  end

  defp message_bubble(%{message: %{role: :compaction_summary}} = assigns) do
    ~H"""
    <.dm_chat
      id={@message.id}
      align="start"
      avatar="∑"
      time={format_timestamp(@message.timestamp)}
      content={@message.summary || "Context compacted."}
    />
    """
  end

  defp message_bubble(assigns), do: ~H""

  defp content_block(%{block: %{type: :thinking}} = assigns) do
    ~H"""
    <.dm_chat_reasoning summary="Reasoning">
      {@block.thinking}
    </.dm_chat_reasoning>
    """
  end

  defp content_block(%{block: %{type: :text}} = assigns) do
    ~H"""
    <.dm_markdown content={@block.text} />
    """
  end

  defp content_block(%{block: %{type: :tool_call}} = assigns) do
    ~H"""
    <.dm_chat_tool name={@block.name} status={tool_call_status(@tool_results, @block.id)}>
      <:call>
        <pre class="text-xs overflow-x-auto p-2 whitespace-pre-wrap">{format_tool_args(@block.arguments)}</pre>
      </:call>
      <:result :if={Map.has_key?(@tool_results, @block.id)}>
        <pre class="text-xs overflow-x-auto p-2 whitespace-pre-wrap">{elem(@tool_results[@block.id], 0)}</pre>
      </:result>
    </.dm_chat_tool>
    """
  end

  defp content_block(assigns), do: ~H""

  defp user_content(content) when is_binary(content), do: content

  defp user_content(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{type: :text, text: text} -> text
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp user_content(_), do: ""

  defp tool_call_status(tool_results, tool_call_id) do
    case Map.get(tool_results, tool_call_id) do
      nil -> "running"
      {_, true} -> "error"
      _ -> "success"
    end
  end

  defp format_tool_args(args) when is_map(args) do
    Jason.encode!(args, pretty: true)
  rescue
    _ -> inspect(args)
  end

  defp format_tool_args(args), do: inspect(args)

  defp render_tool_result_content(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{type: :text, text: text} -> text
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp render_tool_result_content(content) when is_binary(content), do: content
  defp render_tool_result_content(_), do: ""

  defp split_messages(messages) do
    Enum.reduce(messages, {[], %{}, %{}}, fn msg, {stream_msgs, tool_results, tc_map} ->
      case msg.role do
        :tool_result ->
          content_str = render_tool_result_content(msg.content)

          {stream_msgs, Map.put(tool_results, msg.tool_call_id, {content_str, msg.is_error}),
           tc_map}

        :assistant ->
          new_tc_map =
            List.wrap(msg.content)
            |> Enum.filter(&(is_map(&1) && Map.get(&1, :type) == :tool_call))
            |> Enum.reduce(tc_map, &Map.put(&2, &1.id, msg))

          {stream_msgs ++ [msg], tool_results, new_tc_map}

        _ ->
          {stream_msgs ++ [msg], tool_results, tc_map}
      end
    end)
  end

  defp format_timestamp(ts) when is_integer(ts) do
    ts |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%H:%M:%S")
  end

  defp format_timestamp(_), do: ""

  defp ensure_in_list(list, nil), do: list || []
  defp ensure_in_list(nil, current), do: [current]

  defp ensure_in_list(list, current) do
    if current in list, do: list, else: [current | list]
  end

  @impl true
  def handle_event("theme_changed", _, socket) do
    {:noreply, socket}
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
  def handle_event("send_prompt", %{"value" => prompt}, socket) do
    case String.trim(prompt) do
      "" ->
        {:noreply, socket}

      trimmed ->
        PiAgent.prompt(socket.assigns.agent, trimmed)
        {:noreply, socket}
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
    {:noreply, assign(socket, turn_in_flight: false, streaming_message_id: nil)}
  end

  @impl true
  def handle_info({:turn_cancelled}, socket) do
    {:noreply, assign(socket, turn_in_flight: false, streaming_message_id: nil)}
  end

  @impl true
  def handle_info({:turn_error, reason}, socket) do
    msg = if is_binary(reason), do: reason, else: inspect(reason)

    {:noreply,
     socket
     |> put_flash(:error, "Turn failed: #{msg}")
     |> assign(turn_in_flight: false, streaming_message_id: nil)}
  end

  @impl true
  def handle_info({:message_start, %{role: :assistant} = message}, socket) do
    socket =
      socket
      |> stream_insert(:messages, message)
      |> assign(:streaming_message_id, message.id)

    {:noreply, socket}
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
  def handle_info({:message_end, %{role: :tool_result} = message}, socket) do
    content_str = render_tool_result_content(message.content)
    parent_msg = Map.get(socket.assigns.tool_call_to_msg, message.tool_call_id)

    socket =
      update(
        socket,
        :tool_results,
        &Map.put(&1, message.tool_call_id, {content_str, message.is_error})
      )

    socket = if parent_msg, do: stream_insert(socket, :messages, parent_msg), else: socket
    {:noreply, socket}
  end

  @impl true
  def handle_info({:message_end, %{role: :assistant, content: content} = message}, socket)
      when is_list(content) do
    new_tc_map =
      content
      |> Enum.filter(&(is_map(&1) && Map.get(&1, :type) == :tool_call))
      |> Enum.reduce(socket.assigns.tool_call_to_msg, &Map.put(&2, &1.id, message))

    socket =
      socket
      |> stream_insert(:messages, message)
      |> assign(:tool_call_to_msg, new_tc_map)

    {:noreply, socket}
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
      |> assign(turn_in_flight: false, streaming_message_id: nil)

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

  defp read_session_meta(meta_path) do
    case File.read(meta_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, meta} -> meta
          _ -> %{}
        end

      _ ->
        %{}
    end
  end
end
