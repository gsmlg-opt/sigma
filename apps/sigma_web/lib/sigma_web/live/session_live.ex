defmodule Sigma.Web.SessionLive do
  use Sigma.Web, :live_view

  alias Sigma.Agent.SessionContext
  alias Sigma.Session.ConfigManager
  alias Sigma.Session.RepoManager
  alias Sigma.Session.Skills
  alias Sigma.Session.SlashCommands

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
    project_mcp_server_ids = RepoManager.mcp_server_ids(workdir)
    mcp_server_ids = Map.get(session_meta, "mcp_server_ids", project_mcp_server_ids)

    system_config = ConfigManager.get_config()

    config =
      Application.get_env(:sigma_web, :test_provider_config) ||
        ConfigManager.get_active_provider_config()

    global_agents = Map.get(system_config, "system_prompt")

    worktree_context =
      if effective_cwd != workdir and session_branch do
        "# Worktree Context\nYou are working in a git worktree for branch `#{session_branch}` at `#{effective_cwd}`. The project root is at `#{workdir}`."
      end

    builtin_tools = Sigma.Tools.default_tools()
    mcp_servers = ConfigManager.mcp_servers_for(mcp_server_ids)

    session_context =
      SessionContext.new(
        skills: session_skills_context(effective_cwd),
        agents_context: [
          global_agents,
          {"Worktree Context", worktree_context},
          Sigma.Session.ContextFiles.assemble(nil, effective_cwd)
        ],
        current_date: Date.utc_today()
      )

    case resolve_provider(config) do
      {:error, reason} ->
        {:ok, socket |> put_flash(:error, reason) |> push_navigate(to: ~p"/settings")}

      {:ok, {provider_mod, model_id, provider_id, api_key, base_url}} ->
        selected_agent_model = agent_model(config, provider_id, model_id)

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Sigma.Web.PubSub, "session:#{session_id}")
          Phoenix.PubSub.subscribe(Sigma.Web.PubSub, "sigma:logs:#{session_id}")
          Sigma.Logs.start_session(session_id)
        end

        {:ok, initial_messages} = Sigma.Session.Log.replay(storage_path)

        on_event = fn event ->
          Sigma.Session.Log.persist_event(storage_path, event)
          Phoenix.PubSub.broadcast(Sigma.Web.PubSub, "session:#{session_id}", event)
        end

        {:ok, runtime_session} =
          Sigma.Agent.Runtime.get_session(workdir, session_id,
            model: selected_agent_model,
            provider: provider_mod,
            options: [api_key: api_key, base_url: base_url],
            system_prompt: nil,
            session_context: session_context,
            on_event: on_event,
            tools: builtin_tools,
            mcp_servers: mcp_servers,
            messages: initial_messages,
            cwd: effective_cwd
          )

        agent = runtime_session.agent

        Sigma.Agent.set_provider(
          agent,
          provider_mod,
          selected_agent_model,
          api_key: api_key,
          base_url: base_url
        )

        agent_ref = if connected?(socket), do: Process.monitor(agent), else: nil

        pending_user_questions = Sigma.Agent.pending_user_questions(agent)

        {:ok, sessions} = Sigma.Session.Log.list_sessions(sessions_dir)

        model_options = model_options(system_config, provider_id)
        current_model_value = model_option_value(provider_id, model_id)

        {stream_messages, tool_results, tool_call_to_msg} = split_messages(initial_messages)

        socket =
          socket
          |> assign(:active_tab, :repository)
          |> assign(:session_id, session_id)
          |> assign(:workdir, workdir)
          |> assign(:effective_cwd, effective_cwd)
          |> assign(:encoded_repository, encoded_repository)
          |> assign(:sessions_dir, sessions_dir)
          |> assign(:agent, agent)
          |> assign(:agent_ref, agent_ref)
          |> assign(:turn_in_flight, false)
          |> assign(:streaming_message_id, nil)
          |> assign(:tool_results, tool_results)
          |> assign(:tool_call_to_msg, tool_call_to_msg)
          |> assign(:sessions, sessions)
          |> assign(:renaming_session, nil)
          |> assign(:active_provider_id, provider_id)
          |> assign(:current_model, model_id)
          |> assign(:current_model_value, current_model_value)
          |> assign(:model_options, ensure_model_option(model_options, provider_id, model_id))
          |> assign(:context_token_count, latest_context_token_count(initial_messages))
          |> assign(:context_window, model_context_window(selected_agent_model))
          |> assign(:pending_user_questions, pending_user_questions)
          |> assign(:logs_available, true)
          |> assign(:mcp_server_ids, mcp_server_ids)
          |> assign(:show_logs, false)
          |> assign(:log_entries, [])
          |> assign(:log_filter, nil)
          |> assign(:log_search, "")
          |> assign(:show_web_shell, false)
          |> assign(:web_shell_pid, nil)
          |> assign(:web_shell_ref, nil)
          |> assign(:web_shell_status, "Shell ready")
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

          <nav class="flex flex-col gap-2 mt-4">
            <.dm_link
              id="session-sidebar-settings"
              navigate={~p"/repository/#{@encoded_repository}/settings"}
              class="btn btn-ghost w-full justify-start"
            >
              <.dm_mdi name="cog-outline" class="w-4 h-4 mr-1" /> Settings
            </.dm_link>
            <.dm_link
              id="session-sidebar-skills"
              navigate={~p"/repository/#{@encoded_repository}/skills"}
              class="btn btn-ghost w-full justify-start"
            >
              <.dm_mdi name="auto-fix" class="w-4 h-4 mr-1" /> Skills
            </.dm_link>
            <.dm_link
              id="session-sidebar-new-session"
              navigate={~p"/repository/#{@encoded_repository}/sessions/new"}
              class="btn btn-primary w-full justify-start"
            >
              <.dm_mdi name="plus" class="w-4 h-4 mr-1" /> New Session
            </.dm_link>
            <.dm_link
              id="session-sidebar-session-list"
              navigate={~p"/repository/#{@encoded_repository}"}
              class="btn btn-ghost w-full justify-start"
            >
              <.dm_mdi name="format-list-bulleted" class="w-4 h-4 mr-1" /> Session List
            </.dm_link>
            <.dm_btn
              id="web-shell-open-btn"
              type="button"
              phx-click="open_web_shell"
              phx-hook="WebComponentHook"
              variant="ghost"
              class="w-full justify-start"
            >
              <.dm_mdi name="console-line" class="w-4 h-4 mr-1" /> Terminal
            </.dm_btn>
          </nav>
        </div>

        <div class="flex-1 overflow-y-auto">
          <div class="px-4 py-3 text-xs uppercase tracking-widest font-bold opacity-60 text-secondary-content">
            Sessions
          </div>
          <ul class="px-2 flex flex-col gap-0.5">
            <li :for={s <- @sessions} class="group relative flex items-center rounded-xl">
              <% is_renaming = @renaming_session == s %>
              <% menu_button_id = session_menu_button_id(s) %>
              <% menu_id = session_menu_id(s) %>
              <form :if={is_renaming} phx-submit="rename_session" class="flex-1 flex items-center gap-1 px-2 py-1">
                <input type="hidden" name="old_id" value={s} />
                <input
                  type="text"
                  name="new_name"
                  value={s}
                  autofocus
                  class="flex-1 text-sm bg-surface text-on-surface rounded px-2 py-1 border border-primary focus:outline-none"
                />
              </form>
              <.dm_link
                :if={not is_renaming}
                navigate={~p"/repository/#{@encoded_repository}/sessions/#{s}"}
                class={["flex-1 flex items-center gap-2 px-3 py-2 truncate rounded-xl transition-colors text-secondary-content",
                  if(s == @session_id, do: "bg-primary text-primary-content font-bold", else: "hover:bg-secondary-content/10")]}
              >
                <.dm_mdi name="chat-outline" class="w-4 h-4 shrink-0 opacity-70" />
                <span class="truncate text-xs font-mono">{s}</span>
              </.dm_link>
              <.dm_btn
                :if={not is_renaming}
                id={menu_button_id}
                type="button"
                variant="ghost"
                size="xs"
                class="shrink-0 mr-1 opacity-0 group-hover:opacity-60 transition-opacity"
              >
                <.dm_mdi name="dots-vertical" class="w-4 h-4" />
              </.dm_btn>
              <.dm_menu
                :if={not is_renaming}
                id={menu_id}
                anchor={"##{menu_button_id}"}
                placement="bottom-end"
                phx-hook="SessionMenuHook"
                data-session={s}
              >
                <.dm_menu_item value="rename" icon="pencil-outline">Rename</.dm_menu_item>
                <.dm_menu_item value="fork" icon="source-branch">Fork</.dm_menu_item>
                <.dm_menu_item value="archive" icon="archive-outline">Archive</.dm_menu_item>
                <.dm_menu_item value="delete" icon="delete-outline">Delete</.dm_menu_item>
              </.dm_menu>
            </li>
          </ul>
        </div>

        <div class="p-4 border-t border-secondary-content/10" />
      </aside>

      <!-- Main Chat -->
      <div class="flex-1 flex flex-col min-w-0 bg-surface-container-lowest">
        <div id="messages" phx-update="stream" phx-hook="ScrollBottom" class="flex-1 overflow-y-auto p-6 space-y-2">
          <div :for={{id, message} <- @streams.messages} id={id} class="max-w-4xl mx-auto w-full">
            <.message_bubble
              message={message}
              tool_results={@tool_results}
              streaming_message_id={@streaming_message_id}
            />
          </div>
        </div>

        <div class="p-6 border-t border-outline-variant bg-surface">
          <div
            id="chat-input-area"
            phx-hook="ChatInputHook"
            data-slash-commands={
              Jason.encode!([
                %{value: "/init", label: "/init", description: "Create or update AGENTS.md"},
                %{
                  value: "/reload-tools",
                  label: "/reload-tools",
                  description: "Reconnect MCP servers and refresh their tools"
                }
              ])
            }
            class="max-w-4xl mx-auto relative"
          >
            <.pending_user_questions questions={@pending_user_questions} />

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

            <div class="relative">
              <.dm_chat_input
                id="prompt-input"
                phx-update="ignore"
                placeholder="Ask ∑ anything… (⌘/Ctrl+Enter to send)"
                disabled={@turn_in_flight}
                clear_on_send={true}
                duskmoon-send-send="send_prompt"
              />

              <form phx-change="select_model" class="absolute bottom-[8px] right-[107px] z-10 flex items-center">
                <.dm_select id="model-select" name="model" value={@current_model_value} size="xs" disabled={@turn_in_flight}>
                  <option
                    :for={option <- @model_options}
                    value={option.value}
                    selected={option.value == @current_model_value}
                  >{option.label}</option>
                </.dm_select>
              </form>
            </div>

            <div class="mt-3 flex items-center justify-between gap-4 text-[11px] text-on-surface-variant">
              <span :if={@active_provider_id != nil} class="opacity-40 font-mono">
                Provider: {@active_provider_id}
              </span>
              <span
                id="session-context-size"
                class="opacity-40 font-mono"
                title={format_context_size_title(@context_token_count, @context_window)}
                aria-label={"Context #{format_context_size_title(@context_token_count, @context_window)}"}
              >
                Context: {format_context_size(@context_token_count, @context_window)}
              </span>
              <p class="opacity-60 text-right ml-auto">
                ∑ is an AI agent. Review its work carefully.
              </p>
            </div>
          </div>
        </div>
      </div>

      <.web_shell_panel
        :if={@show_web_shell}
        cwd={@effective_cwd}
        status={@web_shell_status}
      />

      <.live_component
        :if={@show_logs}
        module={Sigma.Web.LogDrawerLive}
        id="log-drawer"
        entries={@log_entries}
        filter={@log_filter}
        search={@log_search}
      />
    </div>
    """
  end

  defp web_shell_panel(assigns) do
    ~H"""
    <section
      id="web-shell-panel"
      class="absolute left-72 right-0 bottom-0 z-20 flex max-h-[48vh] flex-col border-t border-outline-variant bg-surface shadow-2xl"
    >
      <div class="flex min-h-12 items-center justify-between gap-4 border-b border-outline-variant px-4 py-2">
        <div class="flex min-w-0 items-center gap-3">
          <span class="flex h-8 w-8 shrink-0 items-center justify-center rounded-md bg-surface-container-high text-on-surface-variant">
            <.dm_mdi name="console-line" class="h-4 w-4" />
          </span>
          <div class="min-w-0">
            <h2 class="text-sm font-semibold text-on-surface">Terminal</h2>
            <p class="truncate font-mono text-xs text-on-surface-variant" title={@cwd}>{@cwd}</p>
          </div>
        </div>
        <div class="flex shrink-0 items-center gap-3">
          <span id="web-shell-status" class="font-mono text-xs text-on-surface-variant">
            {@status}
          </span>
          <.dm_btn
            id="web-shell-close-btn"
            type="button"
            phx-click="close_web_shell"
            phx-hook="WebComponentHook"
            variant="ghost"
            size="xs"
            title="Close terminal"
          >
            <.dm_mdi name="close" class="h-4 w-4" />
          </.dm_btn>
        </div>
      </div>
      <div
        id="web-shell-terminal"
        phx-update="ignore"
        phx-hook="WebShellTerminal"
        data-cwd={@cwd}
        class="web-shell-terminal"
        aria-label="Repository terminal"
      />
    </section>
    """
  end

  defp pending_user_questions(assigns) do
    questions =
      Enum.map(assigns.questions, fn question ->
        question
        |> normalize_user_question_request()
        |> Map.merge(Map.take(question, [:id, :reply_to]))
      end)

    assigns = assign(assigns, :questions, questions)

    ~H"""
    <div
      :if={@questions != []}
      id="ask-user-questions"
      class="mb-4 space-y-3"
      role="group"
      aria-label="Questions from the agent"
    >
      <div
        :for={question <- @questions}
        id={"ask-user-question-#{question.id}"}
        class="rounded-lg border border-primary/30 bg-primary/5 p-4 shadow-sm"
      >
        <div class="mb-3 flex items-start gap-3">
          <div class="mt-0.5 flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-primary text-primary-content">
            <.dm_mdi name="help" class="h-4 w-4" />
          </div>
          <div class="min-w-0">
            <p class="text-xs font-semibold uppercase text-on-surface-variant">Agent question</p>
            <p class="text-sm font-medium text-on-surface">{question.question}</p>
          </div>
        </div>

        <form
          id={"ask-user-question-form-#{question.id}"}
          phx-submit="answer_user_question"
          class="space-y-3"
        >
          <input type="hidden" name="question_id" value={question.id} />

          <div
            class="space-y-2"
            role="radiogroup"
            aria-label={"Answers for #{question.question}"}
          >
            <label
              :for={{option, index} <- Enum.with_index(question.options, 1)}
              id={"ask-user-question-option-#{question.id}-#{index}"}
              class="group flex cursor-pointer items-center gap-3 rounded-lg border border-outline-variant bg-surface-container-low px-3 py-2 transition-colors hover:border-primary/70 hover:bg-primary/10 has-[:checked]:border-primary has-[:checked]:bg-primary/15"
            >
              <input
                type="radio"
                name="selected_answer"
                value={option.value}
                class="peer sr-only"
              />
              <span class="flex h-7 w-7 shrink-0 items-center justify-center rounded-md bg-surface-container-high text-sm font-semibold text-on-surface-variant peer-checked:bg-primary peer-checked:text-primary-content">
                {index}
              </span>
              <span class="min-w-0">
                <span class="block text-sm font-medium text-on-surface">{option.label}</span>
                <span :if={option.description} class="block text-xs text-on-surface-variant">
                  {option.description}
                </span>
              </span>
            </label>

            <label
              :if={question.allow_freeform}
              id={"ask-user-question-custom-#{question.id}"}
              class="flex items-center gap-3 rounded-lg border border-outline-variant bg-surface-container-low px-3 py-2 focus-within:border-primary focus-within:bg-primary/10"
            >
              <span class="flex h-7 w-7 shrink-0 items-center justify-center rounded-md bg-surface-container-high text-sm font-semibold text-on-surface-variant">
                {length(question.options) + 1}
              </span>
              <input
                id={"ask-user-question-input-#{question.id}"}
                name="answer"
                value=""
                placeholder={question.placeholder || "Tell Sigma Agent what to do instead"}
                class="min-w-0 flex-1 bg-transparent text-sm text-on-surface placeholder:text-on-surface-variant focus:outline-none"
              />
            </label>
          </div>

          <div class="flex justify-end gap-2">
            <.dm_btn
              type="button"
              phx-click="cancel_user_question"
              phx-value-question-id={question.id}
              phx-hook="WebComponentHook"
              variant="ghost"
              size="sm"
            >
              Cancel
            </.dm_btn>
            <.dm_btn type="submit" phx-hook="WebComponentHook" variant="primary" size="sm">
              Send answer
            </.dm_btn>
          </div>
        </form>
      </div>
    </div>
    """
  end

  defp message_bubble(%{message: %{role: :user}} = assigns) do
    ~H"""
    <.dm_chat
      id={@message.id}
      align="start"
      color="secondary"
      avatar="You"
      author="You"
      content={user_content(@message.content)}
    >
      <:header><.local_time id={@message.id} timestamp={@message.timestamp} /></:header>
    </.dm_chat>
    """
  end

  defp message_bubble(%{message: %{role: :assistant}} = assigns) do
    content = List.wrap(assigns.message.content)

    assigns =
      assigns
      |> assign(:thinking, Enum.find(content, &(&1.type == :thinking)))
      |> assign(:texts, Enum.filter(content, &(&1.type == :text)))
      |> assign(:tool_calls, Enum.filter(content, &(&1.type == :tool_call)))

    ~H"""
    <.dm_chat
      id={@message.id}
      align="start"
      avatar="∑"
      author="∑"
      streaming={@message.id == @streaming_message_id}
    >
      <:header><.local_time id={@message.id} timestamp={@message.timestamp} /></:header>

      <%!-- Reasoning block; tool calls shown inside via the tools slot --%>
      <.dm_chat_reasoning :if={@thinking} summary="Reasoning">
        {@thinking.thinking}
        <:tools :if={@tool_calls != []}>
          <.dm_chat_tool
            :for={block <- @tool_calls}
            name={block.name}
            status={tool_call_status(@tool_results, block.id)}
          >
            <:call>
              <pre class="text-xs overflow-x-auto p-2 whitespace-pre-wrap">{format_tool_call_args(block)}</pre>
            </:call>
            <:result :if={Map.has_key?(@tool_results, block.id)}>
              <pre class="text-xs overflow-x-auto p-2 whitespace-pre-wrap">{elem(@tool_results[block.id], 0)}</pre>
            </:result>
          </.dm_chat_tool>
        </:tools>
      </.dm_chat_reasoning>

      <%!-- Tool calls at top level when there is no reasoning block --%>
      <.dm_chat_tool
        :if={is_nil(@thinking)}
        :for={block <- @tool_calls}
        name={block.name}
        status={tool_call_status(@tool_results, block.id)}
      >
        <:call>
          <pre class="text-xs overflow-x-auto p-2 whitespace-pre-wrap">{format_tool_call_args(block)}</pre>
        </:call>
        <:result :if={Map.has_key?(@tool_results, block.id)}>
          <pre class="text-xs overflow-x-auto p-2 whitespace-pre-wrap">{elem(@tool_results[block.id], 0)}</pre>
        </:result>
      </.dm_chat_tool>

      <.dm_markdown :for={block <- @texts} content={block.text} />

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
      author="Summary"
      content={@message.summary || "Context compacted."}
    >
      <:header><.local_time id={@message.id} timestamp={@message.timestamp} /></:header>
    </.dm_chat>
    """
  end

  defp message_bubble(assigns), do: ~H""

  defp local_time(assigns) do
    assigns = assign(assigns, :dom_id, "#{assigns.id}-local-time")

    ~H"""
    <span
      :if={is_integer(@timestamp)}
      id={@dom_id}
      phx-hook="LocalTime"
      data-ts={@timestamp}
      class="ml-2 font-mono text-[10px] opacity-50"
    >
      {format_timestamp(@timestamp)}
    </span>
    """
  end

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

  defp format_tool_call_args(%{arguments: args}), do: format_tool_args(args)

  defp format_tool_call_args(%{partial_json: partial_json}) when is_binary(partial_json),
    do: partial_json

  defp format_tool_call_args(_), do: ""

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

  defp latest_context_token_count(messages) do
    messages
    |> Enum.map(&message_context_token_count/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> 0 end)
  end

  defp message_context_token_count(%{role: :assistant, usage: usage}) when is_map(usage) do
    non_negative_integer(Map.get(usage, :input) || Map.get(usage, "input"))
  end

  defp message_context_token_count(_message), do: nil

  defp assign_context_token_count(socket, message) do
    case message_context_token_count(message) do
      nil ->
        socket

      count ->
        assign(socket, :context_token_count, max(socket.assigns.context_token_count, count))
    end
  end

  defp format_context_size(count, nil),
    do: "#{format_token_count(non_negative_integer(count) || 0)} tokens"

  defp format_context_size(count, context_window) do
    "#{format_token_count(non_negative_integer(count) || 0)} / #{format_token_count(context_window)} tokens"
  end

  defp format_context_size_title(count, nil),
    do: "#{format_integer(non_negative_integer(count) || 0)} tokens"

  defp format_context_size_title(count, context_window) do
    "#{format_integer(non_negative_integer(count) || 0)} / #{format_integer(context_window)} tokens"
  end

  defp format_token_count(value) when is_integer(value) and value < 1_000 do
    format_integer(value)
  end

  defp format_token_count(value) when is_integer(value) and value < 1_000_000 do
    "~#{format_compact_number(value, 1_000)}K"
  end

  defp format_token_count(value) when is_integer(value) do
    "~#{format_compact_number(value, 1_000_000)}M"
  end

  defp format_compact_number(value, scale) do
    value
    |> Kernel./(scale)
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
    |> String.trim_trailing(".0")
  end

  defp format_integer(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
    |> Enum.map_join(",", &Enum.join/1)
  end

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 -> number
      _ -> nil
    end
  end

  defp non_negative_integer(_value), do: nil

  defp positive_integer(value) do
    case non_negative_integer(value) do
      number when is_integer(number) and number > 0 -> number
      _ -> nil
    end
  end

  defp model_options(system_config, active_provider_id) do
    system_config
    |> Map.get("providers", %{})
    |> Enum.sort_by(fn {provider_id, provider} ->
      {provider_id != active_provider_id, provider["name"] || provider_id}
    end)
    |> Enum.flat_map(fn {provider_id, provider} ->
      provider
      |> Map.get("models", [])
      |> List.wrap()
      |> Enum.map(&to_model_id/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.map(&model_option(provider_id, provider, &1))
    end)
  end

  defp ensure_model_option(options, _provider_id, nil), do: options

  defp ensure_model_option(options, provider_id, model_id) do
    value = model_option_value(provider_id, model_id)

    if Enum.any?(options, &(&1.value == value)) do
      options
    else
      [%{value: value, label: model_id, provider_id: provider_id, model_id: model_id} | options]
    end
  end

  defp model_option(provider_id, provider, model_id) do
    provider_name = provider["name"] || provider_id

    %{
      value: model_option_value(provider_id, model_id),
      label: "#{provider_name}: #{model_id}",
      provider_id: provider_id,
      model_id: model_id
    }
  end

  defp model_option_value(provider_id, model_id) do
    Jason.encode!(%{"provider_id" => provider_id, "model_id" => model_id})
  end

  defp agent_model(provider_config, provider_id, model_id) do
    metadata =
      provider_config
      |> Map.get("models", [])
      |> List.wrap()
      |> Enum.find(%{}, &(to_model_id(&1) == model_id))

    metadata =
      case metadata do
        model when is_map(model) -> model
        _ -> %{}
      end

    Map.merge(metadata, %{id: model_id, api: provider_id, provider: provider_id})
  end

  defp model_context_window(model) when is_map(model) do
    [
      :context_window,
      "context_window",
      :contextWindow,
      "contextWindow",
      :context_length,
      "context_length",
      :contextLength,
      "contextLength",
      :max_context_tokens,
      "max_context_tokens",
      :maxContextTokens,
      "maxContextTokens",
      :input_token_limit,
      "input_token_limit",
      :inputTokenLimit,
      "inputTokenLimit"
    ]
    |> Enum.find_value(fn key -> positive_integer(Map.get(model, key)) end)
  end

  defp parse_model_option_value(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{"provider_id" => provider_id, "model_id" => model_id}}
      when is_binary(provider_id) and is_binary(model_id) ->
        {:ok, provider_id, model_id}

      _ ->
        :error
    end
  end

  defp parse_model_option_value(_), do: :error

  defp to_model_id(%{"id" => id}) when is_binary(id), do: id
  defp to_model_id(%{id: id}) when is_binary(id), do: id
  defp to_model_id(id) when is_binary(id), do: id
  defp to_model_id(_), do: ""

  defp normalize_user_question_request(request) do
    options = request |> Map.get(:options, []) |> normalize_user_question_options()
    placeholder = Map.get(request, :placeholder)

    {options, placeholder} =
      maybe_promote_user_question_placeholder_examples(options, placeholder)

    %{
      question: Map.get(request, :question, ""),
      options: options,
      allow_freeform: Map.get(request, :allow_freeform, true),
      placeholder: placeholder
    }
  end

  defp normalize_user_question_options(options) when is_list(options) do
    options
    |> Enum.map(&normalize_user_question_option/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_user_question_options(_options), do: []

  defp normalize_user_question_option(option) when is_binary(option) do
    label = String.trim(option)
    if label == "", do: nil, else: %{label: label, value: label, description: nil}
  end

  defp normalize_user_question_option(option) when is_map(option) do
    label =
      option |> Map.get(:label, Map.get(option, "label", "")) |> to_string() |> String.trim()

    value = option |> Map.get(:value, Map.get(option, "value", label)) |> to_string()
    description = Map.get(option, :description, Map.get(option, "description"))

    if label == "" do
      nil
    else
      %{label: label, value: value, description: description}
    end
  end

  defp normalize_user_question_option(_option), do: nil

  defp maybe_promote_user_question_placeholder_examples([], placeholder)
       when is_binary(placeholder) do
    case user_question_example_options_from_placeholder(placeholder) do
      [] -> {[], placeholder}
      options -> {options, nil}
    end
  end

  defp maybe_promote_user_question_placeholder_examples(options, placeholder),
    do: {options, placeholder}

  defp user_question_example_options_from_placeholder(placeholder) do
    placeholder
    |> String.trim()
    |> String.replace(~r/^(e\.g\.?|eg\.?|for example|examples?)[:,]?\s*/i, "")
    |> String.split(~r/\s*(?:,|;|\||\/|\bor\b)\s*/u, trim: true)
    |> Enum.map(&String.trim(&1, " \"'`"))
    |> Enum.reject(&(&1 == ""))
    |> case do
      [_single] -> []
      examples -> Enum.map(examples, &%{label: &1, value: &1, description: nil})
    end
  end

  defp upsert_user_question(questions, question) do
    questions
    |> remove_user_question(question.id)
    |> Kernel.++([question])
  end

  defp remove_user_question(questions, question_id) do
    Enum.reject(questions, &(&1.id == question_id))
  end

  defp reply_to_user_question(socket, question_id, reply) do
    Sigma.Agent.answer_user_question(socket.assigns.agent, question_id, reply)

    {:noreply, update(socket, :pending_user_questions, &remove_user_question(&1, question_id))}
  end

  defp user_question_answer(params) do
    [params["answer"], params["selected_answer"]]
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.find("", &(&1 != ""))
  end

  defp submit_prompt(socket, prompt) do
    agent = socket.assigns.agent

    Sigma.Agent.prompt(agent, prompt,
      dispatcher_opts: [
        ask_user_question_fn: fn request, tool_opts ->
          Sigma.Agent.ask_user_question(agent, request, tool_opts)
        end
      ]
    )
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
  def handle_event("session_menu_action", %{"value" => action, "session" => s}, socket) do
    case action do
      "rename" ->
        {:noreply, assign(socket, :renaming_session, s)}

      "fork" ->
        new_id = "fork_#{System.unique_integer([:positive])}"
        source_path = Path.join(socket.assigns.sessions_dir, "#{s}.jsonl")
        target_path = Path.join(socket.assigns.sessions_dir, "#{new_id}.jsonl")
        Sigma.Session.Log.fork_at_message(source_path, target_path, :all, socket.assigns.workdir)

        {:noreply,
         push_navigate(socket,
           to: ~p"/repository/#{socket.assigns.encoded_repository}/sessions/#{new_id}"
         )}

      "archive" ->
        {:noreply, put_flash(socket, :info, "Archive not yet implemented")}

      "delete" ->
        File.rm(Path.join(socket.assigns.sessions_dir, "#{s}.jsonl"))
        {:ok, sessions} = Sigma.Session.Log.list_sessions(socket.assigns.sessions_dir)
        socket = assign(socket, :sessions, sessions)

        if s == socket.assigns.session_id do
          {:noreply,
           push_navigate(socket, to: ~p"/repository/#{socket.assigns.encoded_repository}")}
        else
          {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("rename_session", %{"old_id" => old_id, "new_name" => new_name}, socket) do
    new_name = String.trim(new_name)
    socket = assign(socket, :renaming_session, nil)

    if new_name == "" or new_name == old_id do
      {:noreply, socket}
    else
      old_path = Path.join(socket.assigns.sessions_dir, "#{old_id}.jsonl")
      new_path = Path.join(socket.assigns.sessions_dir, "#{new_name}.jsonl")
      File.rename(old_path, new_path)
      {:ok, sessions} = Sigma.Session.Log.list_sessions(socket.assigns.sessions_dir)
      socket = assign(socket, :sessions, sessions)

      if old_id == socket.assigns.session_id do
        {:noreply,
         push_navigate(socket,
           to: ~p"/repository/#{socket.assigns.encoded_repository}/sessions/#{new_name}"
         )}
      else
        {:noreply, socket}
      end
    end
  end

  @impl true
  def handle_event("cancel_rename", _, socket) do
    {:noreply, assign(socket, :renaming_session, nil)}
  end

  @impl true
  def handle_event("cancel_turn", _, socket) do
    Sigma.Agent.cancel(socket.assigns.agent)
    {:noreply, socket}
  end

  @impl true
  def handle_event("answer_user_question", params, socket) do
    case user_question_answer(params) do
      "" ->
        {:noreply, put_flash(socket, :error, "Select an answer or type a response.")}

      answer ->
        reply_to_user_question(socket, params["question_id"], {:ok, answer})
    end
  end

  @impl true
  def handle_event("cancel_user_question", %{"question-id" => question_id}, socket) do
    reply_to_user_question(socket, question_id, {:error, "User cancelled the question."})
  end

  @impl true
  def handle_event("send_prompt", %{"value" => prompt}, socket) do
    case String.trim(prompt) do
      "" ->
        {:noreply, socket}

      trimmed ->
        handle_prompt(trimmed, socket)
    end
  end

  @impl true
  def handle_event("open_web_shell", _params, socket) do
    if is_pid(socket.assigns.web_shell_pid) and Process.alive?(socket.assigns.web_shell_pid) do
      {:noreply,
       socket
       |> assign(:show_web_shell, true)
       |> assign(:web_shell_status, "Shell ready")
       |> push_event("web_shell_focus", %{})}
    else
      start_web_shell(socket)
    end
  end

  @impl true
  def handle_event("close_web_shell", _params, socket) do
    {:noreply, socket |> stop_web_shell() |> push_event("web_shell_closed", %{})}
  end

  @impl true
  def handle_event("web_shell_input", %{"data" => data}, socket) when is_binary(data) do
    if is_pid(socket.assigns.web_shell_pid) do
      Sigma.Web.WebShell.input(socket.assigns.web_shell_pid, data)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("web_shell_resize", %{"cols" => cols, "rows" => rows}, socket) do
    if is_pid(socket.assigns.web_shell_pid) do
      Sigma.Web.WebShell.resize(socket.assigns.web_shell_pid, cols, rows)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_logs", _params, socket) do
    {:noreply, assign(socket, :show_logs, !socket.assigns.show_logs)}
  end

  @impl true
  def handle_event("set_log_filter", %{"category" => cat}, socket) do
    category =
      case cat do
        "" -> nil
        c when c in ~w(llm tool permission) -> String.to_existing_atom(c)
        _ -> socket.assigns.log_filter
      end

    entries =
      Sigma.Logs.search(socket.assigns.session_id,
        category: category,
        text: socket.assigns.log_search
      )
      |> Enum.reverse()

    {:noreply, socket |> assign(:log_filter, category) |> assign(:log_entries, entries)}
  end

  @impl true
  def handle_event("set_log_search", %{"value" => q}, socket) do
    entries =
      Sigma.Logs.search(socket.assigns.session_id, category: socket.assigns.log_filter, text: q)
      |> Enum.reverse()

    {:noreply, socket |> assign(:log_search, q) |> assign(:log_entries, entries)}
  end

  @impl true
  def handle_event("select_model", %{"model" => selected}, socket) do
    with {:ok, provider_id, model_id} <- parse_model_option_value(selected),
         config when is_map(config) <- ConfigManager.get_config(),
         provider_config when is_map(provider_config) <-
           get_in(config, ["providers", provider_id]),
         selected_config = Map.put(provider_config, "model", model_id),
         selected_agent_model = agent_model(selected_config, provider_id, model_id),
         {:ok, {provider_mod, _model_id, _provider_id, api_key, base_url}} <-
           resolve_provider(selected_config) do
      Sigma.Agent.set_provider(
        socket.assigns.agent,
        provider_mod,
        selected_agent_model,
        api_key: api_key,
        base_url: base_url
      )

      ConfigManager.set_active_provider(provider_id)
      ConfigManager.update_provider(provider_id, %{"model" => model_id})

      {:noreply,
       assign(socket,
         active_provider_id: provider_id,
         current_model: model_id,
         current_model_value: selected,
         context_window: model_context_window(selected_agent_model)
       )}
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Unknown model selection.")}
    end
  end

  defp handle_prompt(cmd, socket) when cmd in ["/reload-tools", "/reload_tools"] do
    case Sigma.Agent.reload_mcp_tools(socket.assigns.agent) do
      {:ok, count} ->
        {:noreply, put_flash(socket, :info, "Reloaded MCP tools (#{count} available).")}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to reload MCP tools.")}
    end
  end

  defp handle_prompt(prompt, socket) do
    case SlashCommands.expand(prompt) do
      :not_command ->
        submit_prompt(socket, prompt)
        {:noreply, socket}

      {:ok, expanded_prompt} ->
        submit_prompt(socket, expanded_prompt)
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  defp start_web_shell(socket) do
    case Sigma.Web.WebShell.open(owner: self(), cwd: socket.assigns.effective_cwd) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        {:noreply,
         socket
         |> clear_web_shell_monitor()
         |> assign(:show_web_shell, true)
         |> assign(:web_shell_pid, pid)
         |> assign(:web_shell_ref, ref)
         |> assign(:web_shell_status, "Shell ready")
         |> push_event("web_shell_opened", %{cwd: socket.assigns.effective_cwd})}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, web_shell_error(reason))}
    end
  end

  defp stop_web_shell(socket) do
    if is_pid(socket.assigns.web_shell_pid) and Process.alive?(socket.assigns.web_shell_pid) do
      Sigma.Web.WebShell.stop(socket.assigns.web_shell_pid)
    end

    socket
    |> clear_web_shell_monitor()
    |> assign(:show_web_shell, false)
    |> assign(:web_shell_pid, nil)
    |> assign(:web_shell_status, "Shell closed")
  rescue
    _ ->
      socket
      |> clear_web_shell_monitor()
      |> assign(:show_web_shell, false)
      |> assign(:web_shell_pid, nil)
      |> assign(:web_shell_status, "Shell closed")
  end

  defp clear_web_shell_monitor(socket) do
    if is_reference(socket.assigns.web_shell_ref) do
      Process.demonitor(socket.assigns.web_shell_ref, [:flush])
    end

    assign(socket, :web_shell_ref, nil)
  end

  defp web_shell_error({:shutdown, reason}), do: web_shell_error(reason)
  defp web_shell_error(reason) when is_binary(reason), do: reason
  defp web_shell_error(reason), do: "Could not open terminal: #{inspect(reason)}"

  @impl true
  def handle_info({:web_shell_output, pid, data}, socket)
      when pid == socket.assigns.web_shell_pid do
    {:noreply, push_event(socket, "web_shell_output", %{data: data})}
  end

  @impl true
  def handle_info({:web_shell_exit, pid, status}, socket)
      when pid == socket.assigns.web_shell_pid do
    socket =
      socket
      |> clear_web_shell_monitor()
      |> assign(:web_shell_pid, nil)
      |> assign(:web_shell_status, "Shell exited (#{status})")
      |> push_event("web_shell_output", %{data: "\r\n[process exited with status #{status}]\r\n"})

    {:noreply, socket}
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
  def handle_info({:ask_user_question, question_id, request}, socket) do
    question =
      request
      |> normalize_user_question_request()
      |> Map.put(:id, question_id)

    {:noreply, update(socket, :pending_user_questions, &upsert_user_question(&1, question))}
  end

  @impl true
  def handle_info({:ask_user_question_resolved, question_id}, socket) do
    {:noreply, update(socket, :pending_user_questions, &remove_user_question(&1, question_id))}
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
      |> assign_context_token_count(message)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:message_end, %{role: :assistant} = message}, socket) do
    socket =
      socket
      |> stream_insert(:messages, message)
      |> assign_context_token_count(message)

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
  def handle_info({:DOWN, ref, :process, _pid, _reason}, socket) do
    cond do
      ref == socket.assigns.web_shell_ref ->
        {:noreply,
         socket
         |> assign(:web_shell_pid, nil)
         |> assign(:web_shell_ref, nil)
         |> assign(:web_shell_status, "Shell closed")}

      ref == socket.assigns.agent_ref ->
        socket =
          socket
          |> put_flash(
            :error,
            "The agent process crashed. Your session history is preserved — refresh to reconnect."
          )
          |> assign(turn_in_flight: false, streaming_message_id: nil)

        {:noreply, socket}

      true ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:log_entry, entry}, socket) do
    %{log_filter: filter, log_search: search, log_entries: entries} = socket.assigns

    entries =
      if entry_matches?(entry, filter, search) do
        [entry | entries] |> Enum.take(500)
      else
        entries
      end

    {:noreply, assign(socket, :log_entries, entries)}
  end

  @impl true
  def handle_info({:toggle_logs}, socket) do
    {:noreply, assign(socket, :show_logs, !socket.assigns.show_logs)}
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
        Sigma.Session.Log.fork_at_message(source_path, target_path, :all, workdir)

      {:at, msg_id} ->
        Sigma.Session.Log.fork_at_message(source_path, target_path, msg_id, workdir)
    end

    {:noreply,
     push_navigate(socket,
       to: ~p"/repository/#{socket.assigns.encoded_repository}/sessions/#{new_id}"
     )}
  end

  defp resolve_provider(nil) do
    case Application.get_env(:sigma_web, :test_provider_config) do
      nil -> {:error, "No provider configured. Go to Settings to add one."}
      config -> resolve_provider(config)
    end
  end

  defp resolve_provider(config) do
    provider_mod =
      case config["api_type"] do
        "anthropic" -> Sigma.Ai.Providers.Anthropic
        "openai" -> Sigma.Ai.Providers.OpenAI
        _ -> Application.get_env(:sigma_web, :mock_provider_module)
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

  defp session_menu_button_id(session_id) do
    "session-menu-btn-#{session_dom_token(session_id)}"
  end

  defp session_menu_id(session_id) do
    "session-menu-#{session_dom_token(session_id)}"
  end

  defp session_dom_token(session_id) do
    session_id
    |> to_string()
    |> Base.url_encode64(padding: false)
  end

  defp get_sessions_dir(workdir) do
    Sigma.Session.ConfigManager.sessions_dir(workdir)
  end

  defp session_skills_context(effective_cwd) do
    [Skills.list_global().skills, Skills.list_repository(effective_cwd).skills]
    |> List.flatten()
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

  defp entry_matches?(_entry, nil, ""), do: true

  defp entry_matches?(entry, category, "") when not is_nil(category),
    do: entry.category == category

  defp entry_matches?(entry, nil, text), do: String.contains?(inspect(entry.metadata), text)

  defp entry_matches?(entry, category, text),
    do: entry.category == category and String.contains?(inspect(entry.metadata), text)

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:session_id] do
      Sigma.Logs.stop_session(socket.assigns.session_id)
    end

    :ok
  end
end
