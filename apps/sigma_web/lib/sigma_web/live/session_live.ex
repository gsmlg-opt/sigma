defmodule Sigma.Web.SessionLive do
  use Sigma.Web, :live_view

  alias Sigma.Agent.SessionContext
  alias Sigma.Session.ConfigManager
  alias Sigma.Session.RepoManager
  alias Sigma.Session.SessionFiles
  alias Sigma.Session.Skills
  alias Sigma.Session.SlashCommands
  alias Sigma.Web.ImageAttachments
  alias Sigma.Web.Session.TerminalBinding
  alias Sigma.Web.SessionObservability
  alias Sigma.Web.SessionTerminalComponents
  alias Phoenix.LiveView.AsyncResult

  @fork_id_attempts 5
  # Agent startup initializes MCP clients serially; allow that bounded startup
  # window to finish before treating the session as unavailable.
  @session_start_timeout_ms 120_000

  @impl true
  def mount(%{"id" => session_id, "repository" => encoded_repository}, _session, socket) do
    case fetch_registered_repo(encoded_repository) do
      {:ok, workdir, _repo} ->
        mount_registered_session(session_id, encoded_repository, workdir, socket)

      {:error, :unknown_repository} ->
        {:ok, redirect_unknown_repository(socket)}
    end
  end

  defp mount_registered_session(session_id, encoded_repository, workdir, socket) do
    sessions_dir = get_sessions_dir(workdir)

    with {:ok, storage_path} <- SessionFiles.jsonl_path(sessions_dir, session_id),
         {:ok, meta_path} <- SessionFiles.meta_path(sessions_dir, session_id) do
      mount_valid_session(
        session_id,
        encoded_repository,
        workdir,
        sessions_dir,
        storage_path,
        meta_path,
        socket
      )
    else
      {:error, :invalid_session_id} ->
        {:ok, redirect_invalid_session(socket, encoded_repository)}
    end
  end

  defp mount_valid_session(
         session_id,
         encoded_repository,
         workdir,
         sessions_dir,
         storage_path,
         meta_path,
         socket
       ) do
    repo_key = ConfigManager.repository_key(workdir)
    log_session_id = Sigma.Logs.session_key(repo_key, session_id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Sigma.Web.PubSub, session_topic(repo_key, session_id))
      Phoenix.PubSub.subscribe(Sigma.Web.PubSub, logs_topic(repo_key, session_id))
      Sigma.Logs.start_session(log_session_id)
    end

    socket =
      socket
      |> assign_session_defaults(
        session_id,
        encoded_repository,
        workdir,
        sessions_dir,
        meta_path,
        log_session_id
      )
      |> assign(:storage_path, storage_path)
      |> stream(:messages, [])
      |> start_async(:session_load, fn ->
        load_session_data(
          session_id,
          workdir,
          sessions_dir,
          storage_path,
          meta_path,
          repo_key,
          log_session_id
        )
      end)

    {:ok, socket}
  end

  defp load_session_data(
         session_id,
         workdir,
         sessions_dir,
         storage_path,
         meta_path,
         repo_key,
         log_session_id
       ) do
    with {:ok, snapshot} <- Sigma.Session.Log.snapshot(storage_path) do
      load_session_data(
        snapshot,
        session_id,
        workdir,
        sessions_dir,
        storage_path,
        meta_path,
        repo_key,
        log_session_id
      )
    end
  end

  defp load_session_data(
         snapshot,
         session_id,
         workdir,
         sessions_dir,
         storage_path,
         meta_path,
         repo_key,
         log_session_id
       ) do
    session_meta = read_session_meta(meta_path)
    effective_cwd = Map.get(session_meta, "cwd", workdir)
    session_branch = Map.get(session_meta, "branch")
    project_mcp_server_ids = RepoManager.mcp_server_ids(workdir)
    mcp_server_ids = Map.get(session_meta, "mcp_server_ids", project_mcp_server_ids)

    system_config = ConfigManager.get_config()

    config =
      Application.get_env(:sigma_web, :test_provider_config) ||
        session_provider_config(snapshot, session_meta)

    global_agents = Map.get(system_config, "system_prompt")

    worktree_context =
      if effective_cwd != workdir and session_branch do
        "# Worktree Context\nYou are working in a git worktree for branch `#{session_branch}` at `#{effective_cwd}`. The project root is at `#{workdir}`."
      end

    builtin_tools = Sigma.Tools.default_tools()
    mcp_servers = ConfigManager.mcp_servers_for(mcp_server_ids)
    context_discovery = Sigma.Session.ContextFiles.discover(nil, effective_cwd)

    session_context =
      SessionContext.new(
        skills: session_skills_context(effective_cwd),
        agents_context: [
          global_agents,
          {"Worktree Context", worktree_context},
          context_discovery.content
        ],
        current_date: Date.utc_today()
      )

    case resolve_provider(config) do
      {:error, reason} ->
        {:error, {:provider_config, reason}}

      {:ok, {provider_mod, model_id, provider_id, provider_options}} ->
        selected_agent_model = agent_model(config, provider_id, model_id)
        initial_messages = snapshot.messages

        terminal_capability = TerminalBinding.capability()

        with {:ok, runtime_session} <-
               Sigma.Agent.Runtime.get_session(workdir, session_id,
                 model: selected_agent_model,
                 provider: provider_mod,
                 options: provider_options,
                 system_prompt: nil,
                 session_context: session_context,
                 on_event: session_event_handler(repo_key, session_id),
                 permission_config: ConfigManager.get_permissions(),
                 tools: builtin_tools,
                 mcp_servers: mcp_servers,
                 messages: initial_messages,
                 cwd: effective_cwd,
                 transcript_path: storage_path,
                 log_session_id: log_session_id,
                 terminal_backend: TerminalBinding.runtime_backend(terminal_capability)
               ),
             {:ok, sessions} <- Sigma.Session.Log.list_session_summaries(sessions_dir) do
          agent = runtime_session.agent
          runtime_status = Sigma.Agent.Runtime.session_status(workdir, session_id)
          agent_status = load_agent_status(agent)

          pending_user_questions = load_pending_user_questions(agent)
          model_options = model_options(system_config, provider_id)
          current_model_value = model_option_value(provider_id, model_id)
          {stream_messages, tool_results, tool_call_to_msg} = split_messages(initial_messages)
          session_metrics_state = ensure_metrics_session(snapshot.metrics, session_id)
          session_metrics = Sigma.Session.Metrics.snapshot(session_metrics_state)
          context_snapshot = agent_status.context_snapshot
          context_policy = agent_status.context_policy
          branch_summaries = load_branch_summaries(snapshot, storage_path)

          {:ok,
           %{
             active_provider_id: provider_id,
             agent: agent,
             context_snapshot: context_snapshot,
             current_request_id: agent_status.current_request_id,
             context_token_count: context_display_tokens(context_snapshot),
             context_window: context_policy[:context_window],
             session_metrics: session_metrics,
             session_metrics_state: session_metrics_state,
             context_policy: context_policy,
             branch_summaries: branch_summaries,
             parent_session_id: snapshot.parent_session_id,
             runtime_status:
               runtime_phase(
                 agent_status.phase,
                 session_process_runtime_status(runtime_status.status)
               ),
             current_model: model_id,
             current_model_value: current_model_value,
             context_diagnostics: context_discovery.diagnostics,
             context_trace: context_discovery.trace,
             effective_cwd: effective_cwd,
             mcp_server_ids: mcp_server_ids,
             model_options: ensure_model_option(model_options, provider_id, model_id),
             pending_user_questions: pending_user_questions,
             pending_mcp_elicitations: load_pending_mcp_elicitations(agent),
             sessions: sessions,
             stream_messages: stream_messages,
             tool_call_to_msg: tool_call_to_msg,
             tool_results: tool_results,
             terminal_capability: terminal_capability
           }}
        else
          {:error, reason} -> {:error, reason}
          reason -> {:error, reason}
        end
    end
  end

  @impl true
  def handle_async(:session_load, {:ok, {:ok, session_data}}, socket) do
    agent = session_data.agent
    agent_ref = Process.monitor(agent)

    socket =
      socket
      |> assign(:session_load, AsyncResult.ok(socket.assigns.session_load, true))
      |> assign(:active_provider_id, session_data.active_provider_id)
      |> assign(:agent, session_data.agent)
      |> assign(:agent_ref, agent_ref)
      |> assign(:context_token_count, session_data.context_token_count)
      |> assign(:context_window, session_data.context_window)
      |> assign(:context_snapshot, session_data.context_snapshot)
      |> assign(:current_request_id, session_data.current_request_id)
      |> assign(:session_metrics, session_data.session_metrics)
      |> assign(:session_metrics_state, session_data.session_metrics_state)
      |> assign(:context_policy, session_data.context_policy)
      |> assign(:branch_summaries, session_data.branch_summaries)
      |> assign(:parent_session_id, session_data.parent_session_id)
      |> assign(:runtime_status, session_data.runtime_status)
      |> assign(:current_model, session_data.current_model)
      |> assign(:current_model_value, session_data.current_model_value)
      |> assign(:context_diagnostics, session_data.context_diagnostics)
      |> assign(:context_trace, session_data.context_trace)
      |> assign(:effective_cwd, session_data.effective_cwd)
      |> assign(:mcp_server_ids, session_data.mcp_server_ids)
      |> assign(:model_options, session_data.model_options)
      |> assign(:pending_user_questions, session_data.pending_user_questions)
      |> assign(:pending_mcp_elicitations, session_data.pending_mcp_elicitations)
      |> assign(:sessions, session_data.sessions)
      |> assign(:session_ready, true)
      |> assign(:turn_in_flight, active_runtime_phase?(session_data.runtime_status))
      |> assign(:tool_call_to_msg, session_data.tool_call_to_msg)
      |> assign(:tool_results, session_data.tool_results)
      |> stream(:messages, session_data.stream_messages, reset: true)
      |> start_async(:agent_status, fn -> Sigma.Agent.status(agent) end)

    socket = initialize_terminals(socket, session_data.terminal_capability)

    {:noreply, socket}
  end

  def handle_async(:session_load, {:ok, {:error, {:provider_config, reason}}}, socket) do
    {:noreply,
     socket
     |> assign(:session_load, AsyncResult.failed(socket.assigns.session_load, reason))
     |> put_flash(:error, reason)
     |> push_navigate(to: ~p"/settings")}
  end

  def handle_async(:session_load, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:session_load, AsyncResult.failed(socket.assigns.session_load, reason))
     |> put_flash(:error, "Could not load session: #{format_load_error(reason)}")}
  end

  def handle_async(:session_load, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:session_load, AsyncResult.failed(socket.assigns.session_load, {:exit, reason}))
     |> put_flash(:error, "Could not load session: #{format_load_error(reason)}")}
  end

  def handle_async(:manual_compaction, {:ok, {:ok, _result}}, socket) do
    {:noreply,
     socket
     |> assign(pending_compaction: false, runtime_status: :idle)
     |> put_flash(:info, "Context compacted.")}
  end

  def handle_async(:manual_compaction, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(pending_compaction: false, runtime_status: :idle)
     |> put_flash(:error, compact_error_message(reason))}
  end

  def handle_async(:manual_compaction, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(pending_compaction: false, runtime_status: :idle)
     |> put_flash(:error, "Compaction failed: #{inspect(reason)}")}
  end

  def handle_async(:agent_status, {:ok, %{phase: phase} = status}, socket) do
    phase =
      if active_runtime_phase?(socket.assigns.runtime_status) and not active_runtime_phase?(phase),
        do: socket.assigns.runtime_status,
        else: phase

    {:noreply, apply_agent_status(socket, %{status | phase: phase})}
  end

  def handle_async(:agent_status, _result, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="sigma-session-shell relative flex h-[calc(100vh-64px)] overflow-hidden bg-surface text-on-surface font-sans">
      <aside class="sigma-session-sidebar hidden w-64 shrink-0 flex-col border-r border-outline-variant bg-secondary text-secondary-content md:flex">
        <div class="border-b border-secondary-content/10 p-4 text-on-secondary">
          <div class="mb-1 flex items-center gap-2">
            <.dm_mdi name="folder-outline" class="h-4 w-4 opacity-70" />
            <span class="text-xs font-bold uppercase tracking-widest opacity-70">Workspace</span>
          </div>
          <h2 class="truncate text-sm font-semibold" title={@workdir}>{Path.basename(@workdir)}</h2>
          <p class="mt-1 truncate font-mono text-[11px] opacity-60" title={@effective_cwd}>
            {short_path(@effective_cwd)}
          </p>

          <nav class="mt-4 flex flex-col gap-1.5">
            <.dm_link
              id="session-sidebar-settings"
              navigate={~p"/repository/#{@encoded_repository}/settings"}
              class="btn btn-ghost w-full justify-start"
            >
              <.dm_mdi name="cog-outline" class="mr-1 h-4 w-4" /> Settings
            </.dm_link>
            <.dm_link
              id="session-sidebar-skills"
              navigate={~p"/repository/#{@encoded_repository}/skills"}
              class="btn btn-ghost w-full justify-start"
            >
              <.dm_mdi name="auto-fix" class="mr-1 h-4 w-4" /> Skills
            </.dm_link>
            <.dm_link
              id="session-sidebar-new-session"
              navigate={~p"/repository/#{@encoded_repository}/sessions/new"}
              class="btn btn-primary w-full justify-start"
            >
              <.dm_mdi name="plus" class="mr-1 h-4 w-4" /> New Session
            </.dm_link>
            <.dm_link
              id="session-sidebar-session-list"
              navigate={~p"/repository/#{@encoded_repository}"}
              class="btn btn-ghost w-full justify-start"
            >
              <.dm_mdi name="format-list-bulleted" class="mr-1 h-4 w-4" /> Session List
            </.dm_link>
            <.dm_btn
              id="session-terminal-sidebar-open-btn"
              type="button"
              phx-click="terminal_open"
              phx-hook="WebComponentHook"
              variant="ghost"
              class="w-full justify-start"
            >
              <.dm_mdi name="console-line" class="mr-1 h-4 w-4" /> Terminal
            </.dm_btn>
          </nav>
        </div>

        <div class="flex-1 overflow-y-auto">
          <div class="px-4 py-3 text-xs font-bold uppercase tracking-widest text-secondary-content opacity-60">
            Sessions
          </div>
          <ul class="flex flex-col gap-0.5 px-2">
            <li :for={s <- @sessions} class="group relative flex items-center rounded-xl">
              <% session_id = s.session_id %>
              <% is_renaming = @renaming_session == session_id %>
              <% menu_button_id = session_menu_button_id(session_id) %>
              <% menu_id = session_menu_id(session_id) %>
              <form :if={is_renaming} phx-submit="rename_session" class="flex-1 flex items-center gap-1 px-2 py-1">
                <input type="hidden" name="old_id" value={session_id} />
                <input
                  type="text"
                  name="new_name"
                  value={session_id}
                  autofocus
                  class="flex-1 text-sm bg-surface text-on-surface rounded px-2 py-1 border border-primary focus:outline-none"
                />
              </form>
              <.dm_link
                :if={not is_renaming and session_id == @session_id}
                navigate={~p"/repository/#{@encoded_repository}/sessions/#{session_id}"}
                class={["flex min-w-0 flex-1 items-center gap-2 truncate rounded-lg px-3 py-2 text-secondary-content transition-colors",
                  "bg-primary text-primary-content font-bold"]}
              >
                <.dm_mdi name="chat-outline" class="h-4 w-4 shrink-0 opacity-70" />
                <span class="truncate text-xs font-mono" title={session_id}>{s.title}</span>
                <.dm_mdi
                  :if={s[:parent_session_id]}
                  name="source-branch"
                  class="h-3 w-3 shrink-0 opacity-70"
                  title={"Forked from #{s.parent_session_id}"}
                />
              </.dm_link>
              <.dm_btn
                :if={not is_renaming and session_id != @session_id}
                id={"switch-session-#{session_dom_id(session_id)}"}
                type="button"
                phx-click="switch_session"
                phx-value-session={session_id}
                phx-hook="WebComponentHook"
                variant="ghost"
                class="flex min-w-0 flex-1 items-center justify-start gap-2 truncate rounded-lg px-3 py-2 text-secondary-content transition-colors hover:bg-secondary-content/10"
              >
                <.dm_mdi name="chat-outline" class="h-4 w-4 shrink-0 opacity-70" />
                <span class="truncate text-xs font-mono" title={session_id}>{s.title}</span>
                <.dm_mdi
                  :if={s[:parent_session_id]}
                  name="source-branch"
                  class="h-3 w-3 shrink-0 opacity-70"
                  title={"Forked from #{s.parent_session_id}"}
                />
              </.dm_btn>
              <.dm_btn
                :if={not is_renaming}
                id={menu_button_id}
                type="button"
                variant="ghost"
                size="xs"
                class="mr-1 shrink-0 opacity-0 transition-opacity group-hover:opacity-60"
              >
                <.dm_mdi name="dots-vertical" class="h-4 w-4" />
              </.dm_btn>
              <.dm_menu
                :if={not is_renaming}
                id={menu_id}
                anchor={"##{menu_button_id}"}
                placement="bottom-end"
                phx-hook="SessionMenuHook"
                data-session={session_id}
              >
                <.dm_menu_item value="rename" icon="pencil-outline">Rename</.dm_menu_item>
                <.dm_menu_item value="fork" icon="source-branch">Fork</.dm_menu_item>
                <.dm_menu_item value="archive" icon="archive-outline">Archive</.dm_menu_item>
                <.dm_menu_item value="delete" icon="delete-outline">Delete</.dm_menu_item>
              </.dm_menu>
            </li>
          </ul>
        </div>

        <div class="border-t border-secondary-content/10 p-4">
          <p class="mb-2 text-[10px] font-bold uppercase tracking-widest opacity-50">Project root</p>
          <code class="block break-all font-mono text-[10px] leading-tight opacity-70">{@workdir}</code>
        </div>
      </aside>

      <section class="sigma-session-main grid min-w-0 flex-1 grid-rows-[auto_minmax(0,1fr)_auto] bg-surface-container-lowest">
        <header class="sigma-session-header border-b border-outline-variant bg-surface px-4 py-2">
          <div class="flex min-w-0 flex-wrap items-center justify-between gap-3">
            <div class="flex min-w-0 items-center gap-3">
              <span class={["sigma-session-status-dot", session_status_class(@session_ready, @turn_in_flight)]} />
              <div class="min-w-0">
                <p class="text-[10px] font-bold uppercase tracking-widest text-on-surface-variant">
                  Active Session
                </p>
                <h1 class="truncate text-sm font-semibold text-on-surface" title={@session_id}>
                  {@session_id}
                </h1>
              </div>
              <span class="hidden max-w-[28rem] truncate font-mono text-[11px] text-on-surface-variant lg:inline" title={@effective_cwd}>
                {short_path(@effective_cwd)}
              </span>
            </div>

            <div class="flex min-w-0 flex-wrap items-center justify-end gap-2">
              <span
                :if={@active_provider_id}
                class="sigma-session-chip"
                title={"Provider: #{@active_provider_id}"}
              >
                Provider: {@active_provider_id}
              </span>

              <form id="model-select-form" phx-change="select_model" class="sigma-session-model-select">
                <.dm_select
                  id="model-select"
                  name="model"
                  value={@current_model_value}
                  size="xs"
                  disabled={not @session_ready or @turn_in_flight}
                >
                  <option
                    :for={option <- @model_options}
                    value={option.value}
                    selected={option.value == @current_model_value}
                  >{option.label}</option>
                </.dm_select>
              </form>

              <span
                :if={is_integer(@context_window) and @context_window > 0}
                id="session-context-size"
                class={["sigma-context-gauge", context_usage_class(@context_token_count, @context_window)]}
                title={format_context_size_title(@context_token_count, @context_window)}
                aria-label={"Context #{format_context_size_title(@context_token_count, @context_window)}"}
              >
                <span class="sigma-context-gauge-track">
                  <span
                    class="sigma-context-gauge-fill"
                    style={"width: #{context_usage_width(@context_token_count, @context_window)}"}
                  />
                </span>
                <span class="sigma-context-gauge-label">
                  Context: {format_context_size(@context_token_count, @context_window)}
                </span>
              </span>
              <span
                :if={not (is_integer(@context_window) and @context_window > 0)}
                id="session-context-size-unknown"
                class="sigma-session-chip"
                title="The selected model does not report a context window"
              >
                Context: unknown
              </span>

              <SessionTerminalComponents.terminal_trigger
                catalog={@terminal_catalog}
                panel_open?={@terminal_panel_open}
              />

              <.dm_btn
                id="compact-session-btn"
                type="button"
                phx-click="compact_session"
                phx-hook="WebComponentHook"
                variant="ghost"
                size="sm"
                shape="circle"
                disabled={not @session_ready or @turn_in_flight or @pending_compaction}
                title="Compact context"
                aria-label="Compact context"
              >
                <.dm_mdi name="arrow-collapse-vertical" class="h-4 w-4" />
                <span class="sr-only">Compact context</span>
              </.dm_btn>

              <.dm_btn
                id="session-observability-open-btn"
                type="button"
                phx-click="toggle_observability"
                phx-hook="WebComponentHook"
                variant="ghost"
                size="sm"
                shape="circle"
                class="xl:hidden"
                title="Session observability"
                aria-label="Open session observability"
              >
                <.dm_mdi name="chart-box-outline" class="h-4 w-4" />
                <span class="sr-only">Open session observability</span>
              </.dm_btn>
            </div>
          </div>
        </header>

        <div
          id="messages"
          phx-update="stream"
          phx-hook="ScrollBottom"
          class="sigma-session-transcript space-y-2 overflow-y-auto px-4 py-5 md:px-6"
        >
          <div :for={{id, message} <- @streams.messages} id={id} class="mx-auto w-full max-w-4xl">
            <.message_bubble
              message={message}
              tool_results={@tool_results}
              streaming_message_id={@streaming_message_id}
              session_ready={@session_ready}
              turn_in_flight={@turn_in_flight}
              session_metrics={@session_metrics}
            />
          </div>
        </div>

        <footer class="sigma-session-composer border-t border-outline-variant bg-surface px-4 py-3 md:px-6">
          <div
            id="chat-input-area"
            phx-hook="ChatInputHook"
            data-slash-commands={
              Jason.encode!(slash_commands(assigns[:effective_cwd]))
            }
            class="relative mx-auto max-w-4xl"
          >
            <div :if={not @session_ready} class="mb-3 flex items-center gap-3 text-sm text-on-surface-variant">
              <.dm_loading_spinner size="sm" />
              <span>Loading session...</span>
            </div>

            <.pending_user_questions questions={@pending_user_questions} />
            <.pending_mcp_elicitations elicitations={@pending_mcp_elicitations} />

            <details
              :if={@context_diagnostics != []}
              id="context-rule-diagnostics"
              class="mb-3 rounded-lg border border-warning/30 bg-warning/5 px-3 py-2 text-xs text-on-surface-variant"
            >
              <summary class="cursor-pointer font-semibold text-warning">
                Context rules: {length(@context_diagnostics)} diagnostic(s)
              </summary>
              <ul class="mt-2 space-y-1 font-mono">
                <li :for={diagnostic <- @context_diagnostics}>
                  {context_diagnostic_label(diagnostic)}
                </li>
              </ul>
              <details :if={@context_trace != []} id="context-rule-trace" class="mt-2">
                <summary class="cursor-pointer">Composition trace</summary>
                <ol class="mt-1 space-y-1 font-mono">
                  <li :for={entry <- @context_trace}>{context_trace_label(entry)}</li>
                </ol>
              </details>
            </details>

            <div :if={@turn_in_flight} class="mb-3 flex items-center justify-between gap-3">
              <div class="flex items-center gap-3 text-sm text-on-surface-variant">
                <.dm_chat_typing />
                <span>{runtime_phase_label(@runtime_status)}</span>
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
              <%!-- # TODO(upstream): duskmoon-dev/duskmoon-elements#77 --%>
              <.dm_chat_input
                id="prompt-input"
                phx-update="ignore"
                placeholder="Ask ∑ anything…"
                disabled={false}
                clear_on_send={false}
              />
            </div>

            <div class="mt-3 flex items-center justify-end text-[11px] text-on-surface-variant">
              <p class="opacity-60 text-right">
                ∑ is an AI agent. Review its work carefully.
              </p>
            </div>
          </div>
        </footer>
      </section>

      <aside class="sigma-session-rail hidden w-72 shrink-0 flex-col border-l border-outline-variant bg-surface-container-low p-4 xl:flex">
        <div class="mb-4">
          <p class="text-[10px] font-bold uppercase tracking-widest text-on-surface-variant">
            Runtime
          </p>
          <h2 class="mt-1 text-sm font-semibold text-on-surface">Session State</h2>
        </div>

        <div class="grid gap-3 text-sm">
          <div class="rounded-md border border-outline-variant bg-surface-container p-3">
            <p class="text-[10px] font-bold uppercase tracking-widest text-on-surface-variant">
              Working Directory
            </p>
            <p class="mt-1 break-all font-mono text-xs text-on-surface" title={@effective_cwd}>
              {@effective_cwd}
            </p>
          </div>

          <div class="rounded-md border border-outline-variant bg-surface-container p-3">
            <p class="text-[10px] font-bold uppercase tracking-widest text-on-surface-variant">
              Model
            </p>
            <p
              class="mt-1 truncate font-mono text-xs text-on-surface"
              title={assigns[:current_model] || "Loading"}
            >
              {assigns[:current_model] || "Loading"}
            </p>
          </div>

          <div class="rounded-md border border-outline-variant bg-surface-container p-3">
            <p class="text-[10px] font-bold uppercase tracking-widest text-on-surface-variant">
              Context
            </p>
            <p class="mt-1 font-mono text-xs text-on-surface">
              {format_context_size(@context_token_count, @context_window)}
            </p>
          </div>

          <div class="rounded-md border border-outline-variant bg-surface-container p-3">
            <p class="text-[10px] font-bold uppercase tracking-widest text-on-surface-variant">
              MCP Servers
            </p>
            <p class="mt-1 font-mono text-xs text-on-surface">
              {length(assigns[:mcp_server_ids] || [])}
            </p>
          </div>
        </div>

        <SessionObservability.session_overview_rail snapshot={session_observability_snapshot(assigns)} />
        <SessionObservability.context_budget_card policy={context_budget_view(assigns)} />
        <SessionObservability.branch_alternatives branches={@branch_summaries} />
      </aside>

      <button
        :if={@show_observability}
        id="session-observability-backdrop"
        type="button"
        phx-click="toggle_observability"
        class="absolute inset-0 z-20 bg-scrim/40 xl:hidden"
        aria-label="Close session observability"
      />
      <aside
        :if={@show_observability}
        id="session-observability-drawer"
        class="absolute inset-y-0 right-0 z-30 flex w-[min(22rem,calc(100vw-2rem))] flex-col overflow-y-auto border-l border-outline-variant bg-surface-container-high p-4 text-on-surface shadow-xl xl:hidden"
        aria-label="Session observability drawer"
      >
        <header class="mb-4 flex items-center justify-between gap-3 border-b border-outline-variant pb-3">
          <h2 class="text-sm font-semibold">Session observability</h2>
          <.dm_btn
            id="session-observability-close-btn"
            type="button"
            phx-click="toggle_observability"
            phx-hook="WebComponentHook"
            variant="ghost"
            size="sm"
            shape="circle"
            aria-label="Close session observability"
          >
            <.dm_mdi name="close" class="h-4 w-4" />
            <span class="sr-only">Close session observability</span>
          </.dm_btn>
        </header>
        <SessionObservability.session_overview_rail snapshot={session_observability_snapshot(assigns)} />
        <div class="mt-4">
          <SessionObservability.context_budget_card policy={context_budget_view(assigns)} />
        </div>
        <div class="mt-4">
          <SessionObservability.branch_alternatives branches={@branch_summaries} />
        </div>
      </aside>

      <.dm_modal :if={@pending_retry} id="retry-turn-modal" phx-hook="ModalHook">
        <:title>
          <div class="flex items-center gap-2">
            <.dm_mdi name="backup-restore" class="h-5 w-5" />
            <span>Retry turn</span>
          </div>
        </:title>
        <:body>
          <p class="text-sm text-on-surface">
            Start one replacement turn from the selected prompt checkpoint? The original branch remains in the journal.
          </p>
          <div class="mt-3">
            <SessionObservability.side_effect_warning />
          </div>
        </:body>
        <:footer>
          <.dm_btn
            id="cancel-retry-turn-btn"
            type="button"
            phx-click="cancel_retry"
            phx-hook="WebComponentHook"
            variant="ghost"
          >
            Cancel
          </.dm_btn>
          <.dm_btn
            id="confirm-retry-turn-btn"
            type="button"
            phx-click="confirm_retry"
            phx-hook="WebComponentHook"
            variant="primary"
          >
            Retry once
          </.dm_btn>
        </:footer>
      </.dm_modal>

      <.dm_modal :if={@pending_fork} id="fork-session-modal" phx-hook="ModalHook">
        <:title>
          <div class="flex items-center gap-2">
            <.dm_mdi name="source-branch" class="h-5 w-5" />
            <span>Fork session</span>
          </div>
        </:title>
        <:body>
          <form id="fork-session-form" phx-submit="confirm_fork" class="space-y-4">
            <dl class="grid grid-cols-[auto_minmax(0,1fr)] gap-x-3 gap-y-2 text-xs">
              <dt class="text-on-surface-variant">Source</dt>
              <dd class="truncate font-mono" title={@pending_fork.source_session_id}>
                {@pending_fork.source_session_id}
              </dd>
              <dt class="text-on-surface-variant">Boundary</dt>
              <dd class="break-all font-mono">{fork_boundary_label(@pending_fork)}</dd>
              <dt class="text-on-surface-variant">Model</dt>
              <dd class="break-all font-mono">{display_model(@pending_fork.provider_id, @pending_fork.model_id)}</dd>
              <dt class="text-on-surface-variant">Workdir</dt>
              <dd class="break-all font-mono">{@pending_fork.cwd}</dd>
            </dl>

            <label class="block text-sm font-medium text-on-surface" for="fork-target-title">
              Target title
            </label>
            <input
              id="fork-target-title"
              name="title"
              value={@pending_fork.target_title}
              maxlength="120"
              required
              class="w-full rounded-md border border-outline-variant bg-surface-container-low px-3 py-2 text-sm text-on-surface focus:border-primary focus:outline-none"
            />

            <label class="flex items-center gap-2 text-sm text-on-surface" for="fork-switch">
              <input id="fork-switch" type="checkbox" name="switch" value="true" checked />
              Switch to the new session after creating it
            </label>

            <SessionObservability.side_effect_warning />

            <div class="flex justify-end gap-2">
              <.dm_btn
                id="cancel-fork-session-btn"
                type="button"
                phx-click="cancel_fork"
                phx-hook="WebComponentHook"
                variant="ghost"
              >
                Cancel
              </.dm_btn>
              <.dm_btn
                id="confirm-fork-session-btn"
                type="submit"
                phx-hook="WebComponentHook"
                variant="primary"
              >
                Create fork
              </.dm_btn>
            </div>
          </form>
        </:body>
      </.dm_modal>

      <SessionTerminalComponents.terminal_panel
        :if={@terminal_panel_open}
        catalog={terminal_catalog_view(assigns)}
        session={@terminal_session}
        panel_open?={@terminal_panel_open}
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
              id={"ask-user-question-cancel-#{question.id}"}
              type="button"
              phx-click="cancel_user_question"
              phx-value-question-id={question.id}
              phx-hook="WebComponentHook"
              variant="ghost"
              size="sm"
            >
              Cancel
            </.dm_btn>
            <.dm_btn
              id={"ask-user-question-submit-#{question.id}"}
              type="submit"
              phx-hook="WebComponentHook"
              variant="primary"
              size="sm"
            >
              Send answer
            </.dm_btn>
          </div>
        </form>
      </div>
    </div>
    """
  end

  defp pending_mcp_elicitations(assigns) do
    ~H"""
    <div
      :if={@elicitations != []}
      id="mcp-elicitations"
      class="mb-4 space-y-3"
      role="group"
      aria-label="MCP elicitation requests"
    >
      <div
        :for={elicitation <- @elicitations}
        id={"mcp-elicitation-#{elicitation.id}"}
        class="rounded-lg border border-primary/30 bg-primary/5 p-4 shadow-sm"
      >
        <div class="mb-3 flex items-start gap-3">
          <div class="mt-0.5 flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-primary text-primary-content">
            <.dm_mdi name="form-textbox" class="h-4 w-4" />
          </div>
          <div class="min-w-0">
            <p class="text-xs font-semibold uppercase text-on-surface-variant">MCP request</p>
            <p class="text-sm font-medium text-on-surface">{elicitation.message}</p>
          </div>
        </div>

        <form
          id={"mcp-elicitation-form-#{elicitation.id}"}
          phx-submit="answer_mcp_elicitation"
          class="space-y-3"
        >
          <input type="hidden" name="elicitation_id" value={elicitation.id} />

          <div :for={field <- elicitation.fields} class="space-y-1">
            <label class="block text-xs font-medium text-on-surface-variant" for={"mcp-field-#{elicitation.id}-#{field.name}"}>
              {field.title}
            </label>
            <p :if={field.description} class="text-xs text-on-surface-variant">{field.description}</p>

            <input
              :if={field.type in ["string", "number", "integer"]}
              id={"mcp-field-#{elicitation.id}-#{field.name}"}
              type={if field.type == "string", do: "text", else: "number"}
              name={"fields[#{field.name}]"}
              class="w-full rounded-md border border-outline-variant bg-surface-container-low px-3 py-2 text-sm text-on-surface focus:border-primary focus:outline-none"
            />

            <label
              :if={field.type == "boolean"}
              class="flex items-center gap-2 text-sm text-on-surface"
            >
              <input
                id={"mcp-field-#{elicitation.id}-#{field.name}"}
                type="checkbox"
                name={"fields[#{field.name}]"}
                value="true"
              />
              {field.title}
            </label>
          </div>

          <div class="flex justify-end gap-2">
            <.dm_btn
              id={"mcp-elicitation-decline-#{elicitation.id}"}
              type="button"
              phx-click="decline_mcp_elicitation"
              phx-value-elicitation-id={elicitation.id}
              phx-hook="WebComponentHook"
              variant="ghost"
              size="sm"
            >
              Decline
            </.dm_btn>
            <.dm_btn
              id={"mcp-elicitation-submit-#{elicitation.id}"}
              type="submit"
              phx-hook="WebComponentHook"
              variant="primary"
              size="sm"
            >
              Submit
            </.dm_btn>
          </div>
        </form>
      </div>
    </div>
    """
  end

  defp message_bubble(%{message: %{role: :user}} = assigns) do
    assigns =
      assigns
      |> assign(:user_text, user_content(assigns.message.content))
      |> assign(:user_images, user_images(assigns.message.content))

    ~H"""
    <.dm_chat
      id={@message.id}
      class="sigma-chat-with-actions"
      align="start"
      color="secondary"
      avatar="You"
      author="You"
      content={if @user_images == [], do: @user_text, else: nil}
    >
      <:header><.local_time id={@message.id} timestamp={@message.timestamp} /></:header>

      <.dm_markdown :if={@user_text != "" and @user_images != []} content={@user_text} />
      <div :if={@user_images != []} class="grid gap-2 sm:grid-cols-2">
        <img
          :for={src <- @user_images}
          src={src}
          alt="Attached image"
          loading="lazy"
          decoding="async"
          class="max-h-96 w-full rounded-lg border border-outline-variant bg-surface-container-low object-contain"
        />
      </div>

      <:actions_slot>
        <SessionObservability.side_effect_warning />
        <.dm_btn
          :if={retryable_message?(@message)}
          id={"retry-turn-#{@message.id}"}
          phx-click="prepare_retry"
          phx-value-msg-id={@message.id}
          phx-hook="WebComponentHook"
          variant="ghost"
          size="xs"
          disabled={not @session_ready or @turn_in_flight}
          title="Retry from this turn checkpoint"
        >
          <:prefix><.dm_mdi name="backup-restore" class="w-3 h-3" /></:prefix>
          Retry
        </.dm_btn>
        <.dm_btn
          id={"retry-#{@message.id}"}
          phx-click="retry_message"
          phx-value-msg-id={@message.id}
          phx-hook="WebComponentHook"
          variant="ghost"
          size="xs"
          disabled={not @session_ready or @turn_in_flight}
          title="Resend as new turn"
        >
          <:prefix><.dm_mdi name="refresh" class="w-3 h-3" /></:prefix>
          Resend
        </.dm_btn>
      </:actions_slot>
    </.dm_chat>
    """
  end

  defp message_bubble(%{message: %{role: :assistant}} = assigns) do
    content = assistant_content_blocks(assigns.message.content)

    assigns =
      assigns
      |> assign(:thinking, Enum.find(content, &(&1.type == :thinking)))
      |> assign(:texts, Enum.filter(content, &(&1.type == :text)))
      |> assign(:tool_calls, Enum.filter(content, &(&1.type == :tool_call)))
      |> assign(
        :request_metrics,
        request_metrics_for(assigns.message, assigns[:session_metrics])
      )
      |> assign(:turn_summary, turn_summary_for(assigns.message, assigns[:session_metrics]))

    ~H"""
    <.dm_chat
      id={@message.id}
      class="sigma-chat-with-actions"
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

      <:footer :if={@request_metrics != [] or not is_nil(@turn_summary)}>
        <SessionObservability.message_metrics_footer
          :for={request <- @request_metrics}
          metrics={request}
          elapsed_ms={request[:elapsed_ms]}
          status={request[:status]}
        />
        <SessionObservability.turn_summary :if={not is_nil(@turn_summary)} summary={@turn_summary} />
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
          aria-label="Fork session from here"
        >
          <.dm_mdi name="source-branch" class="w-3 h-3" />
          <span class="sr-only">Fork session from here</span>
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

  defp assistant_content_blocks(content) when is_binary(content),
    do: [%{type: :text, text: content}]

  defp assistant_content_blocks(content) when is_list(content), do: content

  defp turn_summary_for(%{stop_reason: :tool_use}, _session_metrics), do: nil

  defp turn_summary_for(%{metadata: metadata}, session_metrics)
       when is_map(metadata) and is_map(session_metrics) do
    turn_id = metadata[:turn_id] || metadata["turn_id"]
    turns = session_metrics[:turns] || session_metrics["turns"] || %{}
    Map.get(turns, turn_id)
  end

  defp turn_summary_for(_message, _session_metrics), do: nil

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

  defp user_images(content) when is_list(content) do
    images = Enum.filter(content, &match?(%{type: :image}, &1))

    case ImageAttachments.data_urls(images) do
      {:ok, urls} -> urls
      {:error, _reason} -> []
    end
  end

  defp user_images(_), do: []

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

  defp message_metrics(usage) when is_map(usage) do
    %{
      input_tokens_total: Map.get(usage, :input) || Map.get(usage, "input"),
      output_tokens_total: Map.get(usage, :output) || Map.get(usage, "output")
    }
  end

  defp request_metrics_for(message, session_metrics) when is_map(session_metrics) do
    requests = session_metrics[:requests] || session_metrics["requests"] || %{}

    durable =
      requests
      |> Map.values()
      |> Enum.filter(&(&1.message_id == message.id))
      |> Enum.sort_by(&{&1.started_at || "", &1.request_id})

    case {durable, message.usage} do
      {[], usage} when is_map(usage) ->
        [
          message_metrics(usage)
          |> Map.put(:status, :unknown)
          |> Map.put(:usage_status, :legacy)
        ]

      _ ->
        durable
    end
  end

  defp request_metrics_for(_message, _session_metrics), do: []

  defp format_context_size(count, nil),
    do: "#{format_token_count(non_negative_integer(count) || 0)} tokens"

  defp format_context_size(count, context_window) do
    "#{format_token_count(non_negative_integer(count) || 0)} / #{format_token_count(context_window)} tokens"
  end

  defp format_context_size_title(count, context_window) do
    "#{format_integer(non_negative_integer(count) || 0)} / #{format_integer(context_window)} tokens"
  end

  defp context_usage_width(count, context_window) do
    "#{context_usage_percent(count, context_window)}%"
  end

  defp context_usage_class(count, context_window) do
    if context_usage_percent(count, context_window) >= 80 do
      "is-warning"
    else
      nil
    end
  end

  defp context_usage_percent(count, context_window) do
    count = non_negative_integer(count) || 0

    case positive_integer(context_window) do
      nil -> 0
      window -> count |> Kernel.*(100) |> Kernel./(window) |> min(100) |> max(0) |> round()
    end
  end

  defp runtime_phase_label(:waiting_provider), do: "Waiting for provider…"
  defp runtime_phase_label(:streaming_provider), do: "Receiving model output…"
  defp runtime_phase_label(:running_tools), do: "Running tools…"
  defp runtime_phase_label(:waiting_permission), do: "Waiting for approval…"
  defp runtime_phase_label(:waiting_elicitation), do: "Waiting for input…"
  defp runtime_phase_label(:cancelling), do: "Cancelling…"
  defp runtime_phase_label(:compacting), do: "Compacting context…"
  defp runtime_phase_label(:queued), do: "Queued…"
  defp runtime_phase_label(_phase), do: "Agent is working…"

  defp fork_boundary_label(%{message_id: :all}), do: "latest completed turn"

  defp fork_boundary_label(%{message_id: message_id, boundary_turn_id: turn_id}) do
    if is_binary(turn_id), do: "turn #{turn_id}", else: "message #{message_id}"
  end

  defp display_model(provider_id, model_id) when is_binary(provider_id) and is_binary(model_id),
    do: "#{provider_id}/#{model_id}"

  defp display_model(_provider_id, _model_id), do: "unknown"

  defp fork_boundary_turn_id(_messages, :all), do: nil

  defp fork_boundary_turn_id(messages, message_id) do
    Enum.find_value(messages, fn message ->
      if message.id == message_id and is_map(message.metadata) do
        message.metadata[:turn_id] || message.metadata["turn_id"]
      end
    end)
  end

  defp session_status_class(false, _turn_in_flight), do: "is-loading"
  defp session_status_class(true, true), do: "is-running"
  defp session_status_class(true, false), do: "is-ready"

  defp short_path(path) when is_binary(path) do
    path
    |> Path.split()
    |> compact_path_segments()
    |> Path.join()
  end

  defp short_path(_path), do: ""

  defp compact_path_segments(segments) when length(segments) > 4 do
    [first | rest] = segments
    [first, "…"] ++ Enum.take(rest, -3)
  end

  defp compact_path_segments(segments), do: segments

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

    with {:ok, command} <-
           Sigma.Protocol.Envelope.command("prompt.submit", socket.assigns.session_id, %{
             "content" => prompt
           }),
         {:ok, %{payload: payload}} <-
           Sigma.Agent.PublicRuntime.execute(command, %{
             repo_path: socket.assigns.workdir,
             sessions_dir: socket.assigns.sessions_dir,
             interactive_approvals: true,
             question_resolver: fn request, tool_opts ->
               Sigma.Agent.ask_user_question(agent, request, tool_opts)
             end
           }) do
      protocol_admission(payload)
    else
      {:error, %{error: error}} -> {:rejected, error.code}
      {:error, reason} -> {:rejected, reason}
    end
  end

  defp protocol_admission(%{
         "status" => status,
         "messageId" => message_id,
         "turnId" => turn_id
       })
       when status in ["accepted", "queued_as_steering", "queued_as_follow_up"] do
    {String.to_existing_atom(status), %{message_id: message_id, turn_id: turn_id}}
  end

  defp protocol_admission(_payload), do: {:rejected, :invalid_protocol_admission}

  defp retry_message(socket, msg_id) do
    with {:ok, messages} <- Sigma.Session.Log.replay(socket.assigns.storage_path),
         {:ok, prompt} <- find_retry_prompt(messages, msg_id) do
      submit_prompt(socket, prompt)
      {:noreply, assign(socket, :turn_in_flight, true)}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Could not find that message to retry.")}

      {:error, :not_retryable} ->
        {:noreply, put_flash(socket, :error, "Only text or image messages can be retried.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not retry that message.")}
    end
  end

  defp find_retry_prompt(messages, msg_id) do
    case Enum.find(messages, &(&1.id == msg_id)) do
      %{role: :user, content: content} ->
        retry_prompt_content(content)

      nil ->
        {:error, :not_found}

      _message ->
        {:error, :not_retryable}
    end
  end

  defp retryable_message?(%{role: :user, metadata: metadata}) when is_map(metadata) do
    turn_id = metadata[:turn_id] || metadata["turn_id"]
    is_binary(turn_id) and turn_id != ""
  end

  defp retryable_message?(_message), do: false

  defp retry_prompt_content(content) when is_binary(content) do
    case String.trim(content) do
      "" -> {:error, :not_retryable}
      prompt -> {:ok, prompt}
    end
  end

  defp retry_prompt_content(content) when is_list(content) do
    text_and_images =
      Enum.filter(content, fn
        %{type: :text, text: text} when is_binary(text) -> String.trim(text) != ""
        %{type: :image} -> true
        _ -> false
      end)

    images = Enum.filter(text_and_images, &match?(%{type: :image}, &1))

    with :ok <- if(images == [], do: :ok, else: validate_retry_images(images)),
         false <- text_and_images == [] do
      {:ok, text_and_images}
    else
      _ -> {:error, :not_retryable}
    end
  end

  defp retry_prompt_content(_content), do: {:error, :not_retryable}

  defp validate_retry_images(images) do
    case ImageAttachments.validate_images(images) do
      {:ok, _images} -> :ok
      {:error, _reason} -> {:error, :not_retryable}
    end
  end

  @impl true
  def handle_event("theme_changed", _, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("fork_session", _, socket) do
    prepare_fork(socket, socket.assigns.session_id, :all)
  end

  @impl true
  def handle_event("fork_at", %{"msg-id" => msg_id}, socket) do
    prepare_fork(socket, socket.assigns.session_id, {:at, msg_id})
  end

  def handle_event("cancel_fork", _params, socket) do
    {:noreply, assign(socket, :pending_fork, nil)}
  end

  def handle_event("confirm_fork", _params, %{assigns: %{pending_fork: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("confirm_fork", params, socket) do
    pending = socket.assigns.pending_fork
    title = params |> Map.get("title", "") |> String.trim()

    if title == "" do
      {:noreply, put_flash(socket, :error, "Enter a title for the new session.")}
    else
      opts = [
        operation_id: pending.operation_id,
        expected_source_revision: pending.expected_source_revision,
        expected_source_leaf: pending.expected_source_leaf,
        title: title
      ]

      case fork_with_new_id(socket, pending.source_session_id, pending.message_id, opts) do
        {:ok, new_id} ->
          socket = assign(socket, :pending_fork, nil)

          if params["switch"] == "true" do
            {:noreply, handle_fork_result(socket, {:ok, new_id})}
          else
            {:ok, sessions} =
              Sigma.Session.Log.list_session_summaries(socket.assigns.sessions_dir)

            {:noreply,
             socket
             |> assign(:sessions, sessions)
             |> put_flash(:info, "Fork created without starting a model request.")}
          end

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:pending_fork, nil)
           |> handle_fork_result({:error, reason})}
      end
    end
  end

  @impl true
  def handle_event("switch_session", %{"session" => target_session_id}, socket) do
    result =
      Sigma.Agent.Runtime.switch_session(
        socket.assigns.workdir,
        socket.assigns.session_id,
        target_session_id,
        socket.assigns.sessions_dir
      )

    case result do
      {:ok, %{session_id: session_id}} ->
        {:noreply,
         push_navigate(socket,
           to: ~p"/repository/#{socket.assigns.encoded_repository}/sessions/#{session_id}"
         )}

      {:error, :session_busy} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Wait for the active turn to finish before switching sessions."
         )}

      {:error, :invalid_session_id} ->
        {:noreply, put_flash(socket, :error, "Invalid session id")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Unable to switch session")}
    end
  end

  @impl true
  def handle_event("session_menu_action", %{"value" => action, "session" => s}, socket) do
    case action do
      "rename" ->
        {:noreply, assign(socket, :renaming_session, s)}

      "fork" ->
        prepare_fork(socket, s, :all)

      "archive" ->
        {:noreply, put_flash(socket, :info, "Archive not yet implemented")}

      "delete" ->
        case Sigma.Agent.Runtime.delete_session(
               socket.assigns.workdir,
               s,
               socket.assigns.sessions_dir
             ) do
          {:ok, _deleted} ->
            {:ok, sessions} =
              Sigma.Session.Log.list_session_summaries(socket.assigns.sessions_dir)

            socket = assign(socket, :sessions, sessions)

            if s == socket.assigns.session_id do
              {:noreply,
               push_navigate(socket, to: ~p"/repository/#{socket.assigns.encoded_repository}")}
            else
              {:noreply, socket}
            end

          {:error, :invalid_session_id} ->
            {:noreply, put_flash(socket, :error, "Invalid session id")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Unable to delete session")}
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
      case Sigma.Agent.Runtime.rename_session(
             socket.assigns.workdir,
             old_id,
             new_name,
             socket.assigns.sessions_dir
           ) do
        {:ok, _renamed} ->
          {:ok, sessions} =
            Sigma.Session.Log.list_session_summaries(socket.assigns.sessions_dir)

          socket = assign(socket, :sessions, sessions)

          if old_id == socket.assigns.session_id do
            {:noreply,
             push_navigate(socket,
               to: ~p"/repository/#{socket.assigns.encoded_repository}/sessions/#{new_name}"
             )}
          else
            {:noreply, socket}
          end

        {:error, :invalid_session_id} ->
          {:noreply, put_flash(socket, :error, "Invalid session id")}

        {:error, :session_busy} ->
          {:noreply, put_flash(socket, :error, "Wait for the active turn to finish first.")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Unable to rename session")}
      end
    end
  end

  @impl true
  def handle_event("cancel_rename", _, socket) do
    {:noreply, assign(socket, :renaming_session, nil)}
  end

  @impl true
  def handle_event("cancel_turn", _, socket) do
    with true <- is_pid(socket.assigns.agent),
         {:ok, command} <-
           Sigma.Protocol.Envelope.command("turn.cancel", socket.assigns.session_id),
         {_status, _event} <-
           Sigma.Agent.PublicRuntime.execute(command, %{
             repo_path: socket.assigns.workdir,
             sessions_dir: socket.assigns.sessions_dir
           }) do
      :ok
    end

    {:noreply, assign(socket, :runtime_status, :cancelling)}
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
  def handle_event("answer_mcp_elicitation", params, socket) do
    elicitation_id = params["elicitation_id"]
    content = coerce_mcp_elicitation_fields(params["fields"] || %{})

    reply_to_mcp_elicitation(socket, elicitation_id, {:accept, content})
  end

  @impl true
  def handle_event("decline_mcp_elicitation", %{"elicitation-id" => elicitation_id}, socket) do
    reply_to_mcp_elicitation(socket, elicitation_id, :decline)
  end

  @impl true
  def handle_event("attachment_error", %{"code" => code}, socket) do
    case ImageAttachments.client_error(code) do
      {:ok, message} -> {:noreply, put_flash(socket, :error, message)}
      :error -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("send_prompt", %{"value" => prompt} = params, socket) do
    cond do
      not session_ready?(socket) ->
        {:reply, %{status: "rejected"}, put_flash(socket, :info, "Session is still loading.")}

      true ->
        case ImageAttachments.normalize(prompt, Map.get(params, "images", [])) do
          {:ok, :empty} ->
            {:reply, %{status: "accepted"}, socket}

          {:ok, content} ->
            case handle_prompt(content, socket) do
              {:accepted, status, socket} -> {:reply, %{status: status}, socket}
              {:rejected, socket} -> {:reply, %{status: "rejected"}, socket}
            end

          {:error, reason} ->
            {:reply, %{status: "rejected"},
             put_flash(socket, :error, ImageAttachments.error_message(reason))}
        end
    end
  end

  @impl true
  def handle_event("retry_message", %{"msg-id" => msg_id}, socket) do
    cond do
      not session_ready?(socket) ->
        {:noreply, put_flash(socket, :info, "Session is still loading.")}

      socket.assigns.turn_in_flight ->
        {:noreply, put_flash(socket, :info, "Agent is still working.")}

      true ->
        retry_message(socket, msg_id)
    end
  end

  @impl true
  def handle_event("prepare_retry", %{"msg-id" => msg_id}, socket) do
    cond do
      not session_ready?(socket) ->
        {:noreply, put_flash(socket, :info, "Session is still loading.")}

      socket.assigns.turn_in_flight ->
        {:noreply, put_flash(socket, :info, "Agent is still working.")}

      true ->
        case Sigma.Session.Log.retry_checkpoint(socket.assigns.storage_path, msg_id) do
          {:ok, checkpoint} ->
            pending = %{
              message_id: msg_id,
              operation_id: new_operation_id("retry"),
              expected_source_revision: checkpoint.source_revision,
              expected_source_leaf: checkpoint.source_leaf_id
            }

            {:noreply, assign(socket, :pending_retry, pending)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, retry_error_message(reason))}
        end
    end
  end

  def handle_event("cancel_retry", _params, socket) do
    {:noreply, assign(socket, :pending_retry, nil)}
  end

  def handle_event("confirm_retry", _params, %{assigns: %{pending_retry: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("confirm_retry", _params, socket) do
    pending = socket.assigns.pending_retry

    result =
      Sigma.Agent.Runtime.retry_turn(
        socket.assigns.workdir,
        socket.assigns.session_id,
        socket.assigns.sessions_dir,
        pending.message_id,
        operation_id: pending.operation_id,
        expected_source_revision: pending.expected_source_revision,
        expected_source_leaf: pending.expected_source_leaf
      )

    case result do
      {:ok, _retry} ->
        {:noreply,
         socket
         |> assign(:pending_retry, nil)
         |> put_flash(:info, "Retry started from the selected checkpoint.")
         |> push_navigate(
           to:
             ~p"/repository/#{socket.assigns.encoded_repository}/sessions/#{socket.assigns.session_id}"
         )}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:pending_retry, nil)
         |> put_flash(:error, retry_error_message(reason))}
    end
  end

  @impl true
  def handle_event("terminal_open", _params, socket) do
    socket = assign(socket, :terminal_panel_open, true)

    case terminal_entries(socket) do
      [] -> terminal_create(socket, :ensure_initial)
      [entry | _] -> {:noreply, select_terminal(socket, entry.terminal_id)}
    end
  end

  def handle_event("terminal_create", _params, socket), do: terminal_create(socket, :create)

  def handle_event("terminal_collapse", _params, socket) do
    {:noreply, socket |> detach_all_terminals() |> assign(:terminal_panel_open, false)}
  end

  def handle_event("terminal_select", %{"terminal_id" => terminal_id}, socket),
    do: {:noreply, select_terminal(socket, terminal_id)}

  def handle_event("terminal_take_control", %{"terminal_id" => terminal_id}, socket) do
    with {:ok, attachment} <- terminal_attachment(socket, terminal_id),
         {:ok, control} <-
           TerminalBinding.acquire_control(
             socket.assigns.workdir,
             socket.assigns.session_id,
             attachment,
             true
           ) do
      {:noreply,
       put_terminal_attachment(socket, terminal_id, control_attachment(attachment, control))}
    else
      {:error, error} ->
        {:noreply,
         socket
         |> revoke_terminal_authority(terminal_id, error)
         |> terminal_error(error)}
    end
  end

  def handle_event("terminal_input", params, socket) do
    with {:ok, attachment} <- terminal_request_attachment(socket, params),
         :ok <-
           TerminalBinding.input(
             socket.assigns.workdir,
             socket.assigns.session_id,
             socket.assigns.terminal_session,
             attachment,
             socket.assigns.terminal_catalog.revision,
             params["data_base64"]
           ) do
      {:noreply, socket}
    else
      {:error, error} ->
        {:noreply,
         socket
         |> revoke_terminal_authority(params["terminal_id"], error)
         |> terminal_error(error)}
    end
  end

  def handle_event("terminal_resize", %{"cols" => cols, "rows" => rows} = params, socket) do
    with {:ok, attachment} <- terminal_request_attachment(socket, params),
         :ok <-
           TerminalBinding.resize(
             socket.assigns.workdir,
             socket.assigns.session_id,
             socket.assigns.terminal_session,
             attachment,
             socket.assigns.terminal_catalog.revision,
             parse_integer(cols),
             parse_integer(rows)
           ) do
      {:noreply, socket}
    else
      {:error, error} ->
        {:noreply,
         socket
         |> revoke_terminal_authority(params["terminal_id"], error)
         |> terminal_error(error)}
    end
  end

  def handle_event("terminal_rendered", %{"sequence" => sequence} = params, socket) do
    with {:ok, attachment} <- terminal_request_attachment(socket, params),
         :ok <-
           TerminalBinding.acknowledge(
             socket.assigns.workdir,
             socket.assigns.session_id,
             attachment,
             parse_integer(sequence)
           ) do
      {:noreply,
       put_terminal_attachment(socket, attachment.terminal_id, %{
         attachment
         | rendered_sequence: parse_integer(sequence)
       })}
    else
      {:error, error} ->
        {:noreply, revoke_terminal_authority(socket, params["terminal_id"], error)}
    end
  end

  def handle_event("terminal_heartbeat", params, socket) do
    with {:ok, attachment} <- terminal_request_attachment(socket, params),
         :ok <-
           TerminalBinding.touch(socket.assigns.workdir, socket.assigns.session_id, attachment),
         {:ok, control} <- maybe_renew_terminal(socket, attachment) do
      {:noreply, put_terminal_attachment(socket, attachment.terminal_id, control)}
    else
      {:error, error} ->
        {:noreply, revoke_terminal_authority(socket, params["terminal_id"], error)}
    end
  end

  def handle_event("terminal_rename", %{"terminal_id" => terminal_id}, socket),
    do:
      {:noreply, update_terminal_attachment(socket, terminal_id, &Map.put(&1, :renaming?, true))}

  def handle_event("terminal_rename_validate", %{"terminal_id" => id, "label" => label}, socket) do
    error =
      if String.trim(label) == "" or byte_size(String.trim(label)) > 80,
        do: "Name must be 1 to 80 bytes",
        else: nil

    {:noreply,
     update_terminal_attachment(
       socket,
       id,
       &Map.merge(&1, %{rename_value: label, rename_error: error})
     )}
  end

  def handle_event("terminal_rename_cancel", %{"terminal_id" => id}, socket),
    do:
      {:noreply,
       update_terminal_attachment(
         socket,
         id,
         &Map.drop(&1, [:renaming?, :rename_value, :rename_error])
       )}

  def handle_event("terminal_rename_submit", %{"terminal_id" => id, "label" => label}, socket) do
    case TerminalBinding.rename(
           socket.assigns.workdir,
           socket.assigns.session_id,
           id,
           label,
           socket.assigns.terminal_catalog.revision
         ) do
      {:ok, _terminal} ->
        {:noreply,
         socket
         |> update_terminal_attachment(
           id,
           &Map.drop(&1, [:renaming?, :rename_value, :rename_error])
         )
         |> refresh_terminal_catalog()}

      {:error, error} ->
        {:noreply, terminal_error(socket, error)}
    end
  end

  def handle_event("terminal_restart", %{"terminal_id" => id}, socket) do
    with {:ok, entry} <- terminal_entry(socket, id),
         {:ok, _terminal} <-
           TerminalBinding.restart(
             socket.assigns.workdir,
             socket.assigns.session_id,
             entry,
             socket.assigns.effective_cwd,
             self()
           ) do
      {:noreply, socket |> detach_terminal(id) |> refresh_terminal_catalog()}
    else
      {:error, error} -> {:noreply, terminal_error(socket, error)}
    end
  end

  def handle_event("terminal_close", %{"terminal_id" => id}, socket),
    do: terminal_close(socket, id, false)

  def handle_event("terminal_cleanup_retry", %{"terminal_id" => id}, socket),
    do: terminal_close(socket, id, true)

  @impl true
  def handle_event("toggle_logs", _params, socket) do
    {:noreply, assign(socket, :show_logs, !socket.assigns.show_logs)}
  end

  def handle_event("toggle_observability", _params, socket) do
    {:noreply, assign(socket, :show_observability, !socket.assigns.show_observability)}
  end

  def handle_event("compact_session", _params, socket) do
    cond do
      not socket.assigns.session_ready ->
        {:noreply, put_flash(socket, :error, "Wait for the session to finish loading.")}

      socket.assigns.turn_in_flight or socket.assigns.pending_compaction ->
        {:noreply, put_flash(socket, :error, "Wait for the active operation to finish first.")}

      true ->
        operation_id = new_operation_id("compact")
        workdir = socket.assigns.workdir
        session_id = socket.assigns.session_id
        sessions_dir = socket.assigns.sessions_dir

        case Sigma.Session.Log.snapshot(socket.assigns.storage_path) do
          {:ok, snapshot} ->
            expected_revision =
              length(snapshot.branch_entry_ids) + if(is_map(snapshot.header), do: 1, else: 0)

            socket =
              socket
              |> assign(pending_compaction: true, runtime_status: :compacting)
              |> start_async(:manual_compaction, fn ->
                Sigma.Agent.Runtime.compact_session(
                  workdir,
                  session_id,
                  sessions_dir,
                  operation_id: operation_id,
                  expected_source_revision: expected_revision,
                  expected_source_leaf: snapshot.active_leaf_id
                )
              end)

            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, compact_error_message(reason))}
        end
    end
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
      Sigma.Logs.search(socket.assigns.log_session_id,
        category: category,
        text: socket.assigns.log_search
      )
      |> Enum.reverse()

    {:noreply, socket |> assign(:log_filter, category) |> assign(:log_entries, entries)}
  end

  @impl true
  def handle_event("set_log_search", %{"value" => q}, socket) do
    entries =
      Sigma.Logs.search(socket.assigns.log_session_id,
        category: socket.assigns.log_filter,
        text: q
      )
      |> Enum.reverse()

    {:noreply, socket |> assign(:log_search, q) |> assign(:log_entries, entries)}
  end

  @impl true
  def handle_event("select_model", %{"model" => selected}, socket) do
    if session_ready?(socket) do
      select_model(selected, socket)
    else
      {:noreply, put_flash(socket, :info, "Session is still loading.")}
    end
  end

  defp select_model(selected, socket) do
    with {:ok, provider_id, model_id} <- parse_model_option_value(selected),
         provider_config when is_map(provider_config) <-
           ConfigManager.get_provider_config(provider_id),
         selected_config = Map.put(provider_config, "model", model_id),
         selected_agent_model = agent_model(selected_config, provider_id, model_id),
         {:ok, {provider_mod, _model_id, _provider_id, provider_options}} <-
           resolve_provider(selected_config),
         {:ok, _entry_id} <-
           persist_selected_model(
             socket,
             provider_id,
             model_id,
             provider_mod,
             selected_agent_model,
             provider_options
           ) do
      ConfigManager.set_active_provider(provider_id)
      ConfigManager.update_provider(provider_id, %{"model" => model_id})

      socket =
        assign(socket,
          active_provider_id: provider_id,
          current_model: model_id,
          current_model_value: selected,
          context_window: model_context_window(selected_agent_model),
          context_token_count: nil
        )

      agent = socket.assigns.agent
      {:noreply, start_async(socket, :agent_status, fn -> Sigma.Agent.status(agent) end)}
    else
      {:error, {:model_change_persistence_failed, _reason}} ->
        {:noreply, put_flash(socket, :error, "Could not persist model selection.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Unknown model selection.")}
    end
  end

  defp persist_selected_model(
         socket,
         provider_id,
         model_id,
         provider_mod,
         selected_agent_model,
         provider_options
       ) do
    case Sigma.Agent.Runtime.change_model(
           socket.assigns.workdir,
           socket.assigns.session_id,
           provider_id,
           model_id,
           provider_mod,
           selected_agent_model,
           provider_options
         ) do
      {:ok, _entry_id} = success -> success
      {:error, reason} -> {:error, {:model_change_persistence_failed, reason}}
    end
  end

  defp handle_prompt(cmd, socket) when cmd in ["/reload-tools", "/reload_tools"] do
    case Sigma.Agent.reload_mcp_tools(socket.assigns.agent) do
      {:ok, count} ->
        {:accepted, "accepted",
         put_flash(socket, :info, "Reloaded MCP tools (#{count} available).")}

      _ ->
        {:rejected, put_flash(socket, :error, "Failed to reload MCP tools.")}
    end
  end

  defp handle_prompt(content, socket) when is_list(content) do
    prompt_admission(socket, submit_prompt(socket, content))
  end

  defp handle_prompt(prompt, socket) do
    case SlashCommands.expand(prompt, cwd: socket.assigns.effective_cwd) do
      :not_command ->
        prompt_admission(socket, submit_prompt(socket, prompt))

      {:ok, expanded_prompt} ->
        prompt_admission(socket, submit_prompt(socket, expanded_prompt))

      {:error, reason} ->
        {:rejected, put_flash(socket, :error, reason)}
    end
  end

  defp prompt_admission(socket, {:accepted, _info}) do
    {:accepted, "accepted", assign(socket, :turn_in_flight, true)}
  end

  defp prompt_admission(socket, {:queued_as_steering, _info}) do
    {:accepted, "queued_as_steering",
     socket
     |> assign(:turn_in_flight, true)
     |> put_flash(:info, "Prompt queued as steering input.")}
  end

  defp prompt_admission(socket, {:queued_as_follow_up, _info}) do
    {:accepted, "queued_as_follow_up",
     socket
     |> assign(:turn_in_flight, true)
     |> put_flash(:info, "Prompt queued as follow-up.")}
  end

  defp prompt_admission(socket, {:rejected, reason}) do
    {:rejected, put_flash(socket, :error, "Prompt rejected: #{inspect(reason)}")}
  end

  @impl true
  def handle_info({:agent_start, _cwd}, socket) do
    {:noreply, assign(socket, turn_in_flight: true, runtime_status: :streaming_provider)}
  end

  @impl true
  def handle_info({:turn_start}, socket) do
    {:noreply, assign(socket, turn_in_flight: true, runtime_status: :streaming_provider)}
  end

  @impl true
  def handle_info({:tool_execution_start, _id, _name, _arguments}, socket) do
    {:noreply, assign(socket, :runtime_status, :running_tools)}
  end

  @impl true
  def handle_info({:approval_required, _id, _name}, socket) do
    {:noreply, assign(socket, :runtime_status, :waiting_permission)}
  end

  @impl true
  def handle_info({:agent_end, _}, socket) do
    {:noreply, assign(socket, turn_in_flight: false, streaming_message_id: nil)}
  end

  @impl true
  def handle_info({:turn_completed, _turn_id}, socket) do
    {:noreply,
     assign(socket, turn_in_flight: false, streaming_message_id: nil, runtime_status: :completed)}
  end

  @impl true
  def handle_info({:turn_failed, _turn_id}, socket) do
    {:noreply,
     assign(socket, turn_in_flight: false, streaming_message_id: nil, runtime_status: :failed)}
  end

  @impl true
  def handle_info({:turn_cancelled}, socket) do
    {:noreply,
     assign(socket, turn_in_flight: false, streaming_message_id: nil, runtime_status: :cancelled)}
  end

  @impl true
  def handle_info({:turn_error, reason}, socket) do
    msg = if is_binary(reason), do: reason, else: inspect(reason)

    {:noreply,
     socket
     |> put_flash(:error, "Turn failed: #{msg}")
     |> assign(turn_in_flight: false, streaming_message_id: nil, runtime_status: :failed)}
  end

  @impl true
  def handle_info({:ask_user_question, question_id, request}, socket) do
    question =
      request
      |> normalize_user_question_request()
      |> Map.put(:id, question_id)

    {:noreply,
     socket
     |> assign(:runtime_status, :waiting_permission)
     |> update(:pending_user_questions, &upsert_user_question(&1, question))}
  end

  @impl true
  def handle_info({:ask_user_question_resolved, question_id}, socket) do
    {:noreply,
     socket
     |> assign(:runtime_status, resumed_runtime_status(socket))
     |> update(:pending_user_questions, &remove_user_question(&1, question_id))}
  end

  @impl true
  def handle_info({:mcp_elicitation, elicitation_id, request}, socket) do
    elicitation = Map.put(request, :id, elicitation_id)

    {:noreply,
     socket
     |> assign(:runtime_status, :waiting_elicitation)
     |> update(:pending_mcp_elicitations, &upsert_mcp_elicitation(&1, elicitation))}
  end

  @impl true
  def handle_info({:mcp_elicitation_resolved, elicitation_id}, socket) do
    {:noreply,
     socket
     |> assign(:runtime_status, resumed_runtime_status(socket))
     |> update(:pending_mcp_elicitations, &remove_mcp_elicitation(&1, elicitation_id))}
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
  def handle_info({:message_end, %{role: :assistant} = message}, socket) do
    {:noreply, stream_insert(socket, :messages, message)}
  end

  @impl true
  def handle_info({:message_end, message}, socket) do
    {:noreply, stream_insert(socket, :messages, message)}
  end

  @impl true
  def handle_info({:metrics, fact, attrs}, socket) when is_map(attrs) do
    metrics_state =
      case socket.assigns[:session_metrics_state] do
        %Sigma.Session.Metrics{} = state ->
          ensure_metrics_session(state, socket.assigns[:session_id])

        _ ->
          Sigma.Session.Metrics.new(socket.assigns[:session_id])
      end

    metrics_state = Sigma.Session.Metrics.reduce(metrics_state, {fact, attrs})
    runtime_status = metrics_runtime_status(fact, attrs, socket)

    socket =
      socket
      |> assign(:session_metrics_state, metrics_state)
      |> assign(:session_metrics, Sigma.Session.Metrics.snapshot(metrics_state))
      |> assign(:runtime_status, runtime_status)

    socket =
      if fact in [:request_finished, :request_usage, :turn_finished, :compaction] and
           is_pid(socket.assigns.agent) do
        agent = socket.assigns.agent
        start_async(socket, :agent_status, fn -> Sigma.Agent.status(agent) end)
      else
        socket
      end

    {:noreply, socket}
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
  def handle_info({:terminal_catalog_changed, session, _revision}, socket) do
    if session == socket.assigns.terminal_session do
      socket = refresh_terminal_catalog(socket)

      socket =
        if socket.assigns.terminal_panel_open do
          case selected_terminal_after_refresh(socket) do
            nil ->
              socket

            terminal_id ->
              if MapSet.member?(socket.assigns.terminal_pending_creators, terminal_id),
                do: socket,
                else: select_terminal(socket, terminal_id)
          end
        else
          socket
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:terminal_creator_attachment, run, {:ok, result}}, socket) do
    if run.terminal.session == socket.assigns.terminal_session do
      attachment = TerminalBinding.attachment(result, socket.assigns.effective_cwd)

      {:noreply,
       socket
       |> put_terminal_attachment(attachment.terminal_id, attachment)
       |> assign(
         :terminal_pending_creators,
         MapSet.delete(socket.assigns.terminal_pending_creators, attachment.terminal_id)
       )
       |> assign(:terminal_selected_id, attachment.terminal_id)
       |> push_terminal_authority(attachment)
       |> refresh_terminal_catalog()}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:terminal_creator_attachment, _run, {:error, error}}, socket),
    do: {:noreply, terminal_error(socket, error)}

  def handle_info({:terminal_stream, attachment_id, {:snapshot, snapshot}}, socket),
    do: {:noreply, push_terminal_frame(socket, attachment_id, snapshot, "terminal_snapshot")}

  def handle_info({:terminal_stream, attachment_id, {:event, event}}, socket),
    do: {:noreply, push_terminal_frame(socket, attachment_id, event, "terminal_output")}

  def handle_info({:terminal_stream, attachment_id, {:resync_required, reason}}, socket) do
    case attachment_by_id(socket, attachment_id) do
      {:ok, attachment} ->
        socket =
          socket
          |> put_terminal_attachment(attachment.terminal_id, %{attachment | resynced?: false})
          |> push_event("terminal_resync", %{
            terminal_id: attachment.terminal_id,
            generation: attachment.generation,
            resynced: false,
            reason: terminal_reason(reason)
          })

        case TerminalBinding.resync(
               socket.assigns.workdir,
               socket.assigns.session_id,
               attachment,
               attachment.rendered_sequence
             ) do
          {:ok, _delivery} ->
            attachment = %{attachment | resynced?: true}

            {:noreply,
             socket
             |> put_terminal_attachment(attachment.terminal_id, attachment)
             |> push_event("terminal_resync", %{
               terminal_id: attachment.terminal_id,
               generation: attachment.generation,
               resynced: true
             })}

          {:error, error} ->
            {:noreply, terminal_error(socket, error)}
        end

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, socket) do
    cond do
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

  defp prepare_fork(socket, source_session_id, mode) do
    message_id = if mode == :all, do: :all, else: elem(mode, 1)

    cond do
      not session_ready?(socket) ->
        {:noreply, put_flash(socket, :info, "Session is still loading.")}

      socket.assigns.turn_in_flight ->
        {:noreply, put_flash(socket, :info, "Wait for the active turn to finish before forking.")}

      true ->
        with {:ok, source_path} <-
               Sigma.Session.SessionFiles.jsonl_path(
                 socket.assigns.sessions_dir,
                 source_session_id
               ),
             {:ok, snapshot} <- Sigma.Session.Log.snapshot(source_path) do
          boundary_turn_id = fork_boundary_turn_id(snapshot.messages, message_id)

          pending = %{
            source_session_id: source_session_id,
            message_id: message_id,
            boundary_turn_id: boundary_turn_id,
            target_title: "Fork of #{source_session_id}",
            provider_id: snapshot.provider_id,
            model_id: snapshot.model_id,
            cwd: snapshot.cwd || socket.assigns.workdir,
            operation_id: new_operation_id("fork"),
            expected_source_revision:
              length(snapshot.branch_entry_ids) + if(is_map(snapshot.header), do: 1, else: 0),
            expected_source_leaf: snapshot.active_leaf_id
          }

          {:noreply, assign(socket, :pending_fork, pending)}
        else
          {:error, reason} ->
            {:noreply, put_flash(socket, :error, fork_error_message(reason))}
        end
    end
  end

  defp fork_with_new_id(socket, source_id, message_id, opts) do
    fork_with_new_id(socket, source_id, message_id, opts, @fork_id_attempts)
  end

  defp fork_with_new_id(_socket, _source_id, _message_id, _opts, 0),
    do: {:error, :already_exists}

  defp fork_with_new_id(socket, source_id, message_id, opts, attempts_left) do
    new_id = new_fork_id()
    checkpoint_opts = if opts == [], do: fork_checkpoint_opts(socket, source_id), else: opts
    operation_id = Keyword.get(checkpoint_opts, :operation_id, "fork-#{source_id}")
    attempt_opts = Keyword.put(checkpoint_opts, :operation_id, "#{operation_id}-target-#{new_id}")

    case Sigma.Agent.Runtime.fork_session(
           socket.assigns.workdir,
           source_id,
           new_id,
           socket.assigns.sessions_dir,
           message_id,
           Keyword.merge(
             [fallback_cwd: socket.assigns.workdir],
             attempt_opts
           )
         ) do
      {:ok, %{session_id: ^new_id}} ->
        {:ok, new_id}

      {:error, :already_exists} ->
        fork_with_new_id(socket, source_id, message_id, opts, attempts_left - 1)

      {:error, _reason} = error ->
        error
    end
  end

  defp fork_checkpoint_opts(socket, source_id) do
    with {:ok, source_path} <-
           Sigma.Session.SessionFiles.jsonl_path(socket.assigns.sessions_dir, source_id),
         {:ok, snapshot} <- Sigma.Session.Log.snapshot(source_path) do
      [
        expected_source_revision:
          length(snapshot.branch_entry_ids) + if(is_map(snapshot.header), do: 1, else: 0),
        expected_source_leaf: snapshot.active_leaf_id
      ]
    else
      _ -> []
    end
  end

  defp new_fork_id do
    case Application.get_env(:sigma_web, :session_live_fork_id_generator) do
      generator when is_function(generator, 0) ->
        generator.()

      _ ->
        "fork_#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
    end
  end

  defp new_operation_id(prefix) do
    suffix = :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
    "#{prefix}-#{suffix}"
  end

  defp retry_error_message(:message_not_found),
    do: "The original prompt is no longer available."

  defp retry_error_message(:missing_retry_history),
    do: "This legacy turn has no retry checkpoint. Use Resend or Fork instead."

  defp retry_error_message(:retry_attachments_unavailable),
    do: "The original attachments are no longer available. Use Resend or Fork instead."

  defp retry_error_message(:session_busy),
    do: "Wait for the active turn to finish before retrying."

  defp retry_error_message({:revision_conflict, _details}),
    do: "The session changed before retrying. Refresh and choose Retry again."

  defp retry_error_message({:leaf_conflict, _details}),
    do: "The conversation branch changed before retrying. Refresh and choose Retry again."

  defp retry_error_message(_reason), do: "Unable to retry from that checkpoint."

  defp fork_error_message(:invalid_fork_boundary),
    do: "Choose a completed turn boundary before forking."

  defp fork_error_message(:unpaired_tool_exchange),
    do: "That boundary splits a tool call from its result. Choose a completed turn instead."

  defp fork_error_message(:message_not_found),
    do: "The selected fork boundary is no longer available."

  defp fork_error_message(_reason), do: "Unable to prepare that fork."

  defp handle_fork_result(socket, {:ok, new_id}) do
    push_navigate(socket,
      to: ~p"/repository/#{socket.assigns.encoded_repository}/sessions/#{new_id}"
    )
  end

  defp handle_fork_result(socket, {:error, :invalid_session_id}) do
    put_flash(socket, :error, "Invalid session id")
  end

  defp handle_fork_result(socket, {:error, :session_busy}) do
    put_flash(socket, :error, "Wait for the active turn to finish before forking this session.")
  end

  defp handle_fork_result(socket, {:error, {:revision_conflict, _details}}) do
    put_flash(
      socket,
      :error,
      "The session changed before forking. Refresh and choose Fork again."
    )
  end

  defp handle_fork_result(socket, {:error, {:leaf_conflict, _details}}) do
    put_flash(
      socket,
      :error,
      "The conversation branch changed before forking. Refresh and try again."
    )
  end

  defp handle_fork_result(socket, {:error, _reason}) do
    put_flash(socket, :error, "Unable to fork session")
  end

  defp session_dom_id(session_id) do
    Base.url_encode64(session_id, padding: false)
  end

  defp initialize_terminals(socket, capability) do
    case TerminalBinding.subscribe_and_list(
           socket.assigns.workdir,
           socket.assigns.session_id,
           capability
         ) do
      {:ok, catalog, session} ->
        socket
        |> assign(:terminal_capability, capability)
        |> assign(:terminal_catalog, catalog)
        |> assign(:terminal_session, session)

      {:unavailable, catalog, nil} ->
        socket
        |> assign(:terminal_capability, capability)
        |> assign(:terminal_catalog, catalog)
    end
  end

  defp terminal_create(socket, kind) do
    if socket.assigns.terminal_capability.status == :available do
      case TerminalBinding.create(
             socket.assigns.workdir,
             socket.assigns.session_id,
             kind,
             socket.assigns.effective_cwd,
             self()
           ) do
        {:ok, terminal} ->
          {:noreply,
           socket
           |> assign(:terminal_selected_id, terminal.identity.terminal_id)
           |> assign(
             :terminal_pending_creators,
             MapSet.put(socket.assigns.terminal_pending_creators, terminal.identity.terminal_id)
           )
           |> refresh_terminal_catalog()}

        {:error, error} ->
          {:noreply, terminal_error(socket, error)}
      end
    else
      {:noreply, terminal_error(socket, socket.assigns.terminal_capability.reason)}
    end
  end

  defp terminal_close(socket, terminal_id, retry?) do
    with {:ok, entry} <- terminal_entry(socket, terminal_id),
         {:ok, _result} <-
           TerminalBinding.close(
             socket.assigns.workdir,
             socket.assigns.session_id,
             entry,
             retry?
           ) do
      {:noreply, socket |> detach_terminal(terminal_id) |> refresh_terminal_catalog()}
    else
      {:error, error} -> {:noreply, terminal_error(socket, error)}
    end
  end

  defp select_terminal(socket, terminal_id) do
    socket =
      case socket.assigns.terminal_selected_id do
        nil -> socket
        ^terminal_id -> socket
        previous -> detach_terminal(socket, previous)
      end

    socket = assign(socket, :terminal_selected_id, terminal_id)

    case {terminal_attachment(socket, terminal_id), terminal_entry(socket, terminal_id)} do
      {{:ok, _attachment}, _entry} ->
        socket

      {{:error, _}, {:ok, %{state: state} = entry}} when state in [:running, :stopping] ->
        case TerminalBinding.attach(
               socket.assigns.workdir,
               socket.assigns.session_id,
               entry,
               self()
             ) do
          {:ok, result} ->
            attachment = TerminalBinding.attachment(result, socket.assigns.effective_cwd)

            socket
            |> put_terminal_attachment(terminal_id, attachment)
            |> push_terminal_authority(attachment)

          {:error, error} ->
            terminal_error(socket, error)
        end

      _other ->
        socket
    end
  end

  defp detach_all_terminals(socket) do
    Enum.reduce(Map.keys(socket.assigns.terminal_attachments), socket, &detach_terminal(&2, &1))
  end

  defp detach_terminal(socket, terminal_id) do
    case terminal_attachment(socket, terminal_id) do
      {:ok, attachment} ->
        _ =
          TerminalBinding.release_control(
            socket.assigns.workdir,
            socket.assigns.session_id,
            attachment
          )

        _ = TerminalBinding.detach(socket.assigns.workdir, socket.assigns.session_id, attachment)

        assign(
          socket,
          :terminal_attachments,
          Map.delete(socket.assigns.terminal_attachments, terminal_id)
        )

      {:error, _reason} ->
        socket
    end
  end

  defp refresh_terminal_catalog(socket) do
    case TerminalBinding.refresh(
           socket.assigns.workdir,
           socket.assigns.session_id,
           socket.assigns.terminal_attachments,
           socket.assigns.terminal_capability
         ) do
      {:ok, catalog} -> assign(socket, :terminal_catalog, catalog)
      {:error, catalog} -> assign(socket, :terminal_catalog, catalog)
    end
  end

  defp terminal_catalog_view(assigns) do
    selected_id =
      if Enum.any?(
           assigns.terminal_catalog.entries,
           &(&1.terminal_id == assigns.terminal_selected_id)
         ),
         do: assigns.terminal_selected_id,
         else: assigns.terminal_catalog.selected_id

    Map.put(assigns.terminal_catalog, :selected_id, selected_id)
  end

  defp terminal_entries(socket), do: socket.assigns.terminal_catalog.entries

  defp selected_terminal_after_refresh(socket) do
    ids = Enum.map(terminal_entries(socket), & &1.terminal_id)

    if socket.assigns.terminal_selected_id in ids,
      do: socket.assigns.terminal_selected_id,
      else: List.first(ids)
  end

  defp terminal_entry(socket, terminal_id) do
    case Enum.find(terminal_entries(socket), &(&1.terminal_id == terminal_id)) do
      nil -> {:error, Sigma.Agent.Terminals.Error.new(:terminal_not_found)}
      entry -> {:ok, entry}
    end
  end

  defp terminal_attachment(socket, terminal_id) do
    case socket.assigns.terminal_attachments[terminal_id] do
      %{attachment_id: attachment_id} = attachment when is_binary(attachment_id) ->
        {:ok, attachment}

      _missing ->
        {:error, Sigma.Agent.Terminals.Error.new(:not_controller)}
    end
  end

  defp attachment_by_id(socket, attachment_id) do
    case Enum.find(socket.assigns.terminal_attachments, fn {_terminal_id, attachment} ->
           attachment.attachment_id == attachment_id
         end) do
      {_terminal_id, attachment} -> {:ok, attachment}
      nil -> :error
    end
  end

  defp terminal_request_attachment(socket, params) do
    with true <- params["repository_id"] == socket.assigns.terminal_session.repository_id,
         true <- params["session_id"] == socket.assigns.terminal_session.session_id,
         true <- params["incarnation_id"] == socket.assigns.terminal_session.incarnation_id,
         {:ok, attachment} <- terminal_attachment(socket, params["terminal_id"]),
         true <- parse_integer(params["generation"]) == attachment.generation,
         true <- params["attachment_id"] == attachment.attachment_id,
         true <- parse_integer(params["control_epoch"]) == attachment.control_epoch,
         true <-
           parse_integer(params["catalog_revision"]) == socket.assigns.terminal_catalog.revision do
      {:ok, attachment}
    else
      _invalid -> {:error, Sigma.Agent.Terminals.Error.new(:session_scope_mismatch)}
    end
  end

  defp put_terminal_attachment(socket, terminal_id, attachment) do
    socket
    |> assign(
      :terminal_attachments,
      Map.put(socket.assigns.terminal_attachments, terminal_id, attachment)
    )
    |> refresh_terminal_catalog()
  end

  defp update_terminal_attachment(socket, terminal_id, update) do
    attachment = Map.get(socket.assigns.terminal_attachments, terminal_id, %{})

    assign(
      socket,
      :terminal_attachments,
      Map.put(socket.assigns.terminal_attachments, terminal_id, update.(attachment))
    )
  end

  defp control_attachment(attachment, control) do
    %{attachment | controller?: control.controller, control_epoch: control.control_epoch}
  end

  defp maybe_renew_terminal(socket, %{controller?: true} = attachment) do
    case TerminalBinding.renew(socket.assigns.workdir, socket.assigns.session_id, attachment) do
      {:ok, control} -> {:ok, control_attachment(attachment, control)}
      error -> error
    end
  end

  defp maybe_renew_terminal(_socket, attachment), do: {:ok, attachment}

  defp push_terminal_authority(socket, attachment) do
    socket
    |> push_event("terminal_control", %{
      terminal_id: attachment.terminal_id,
      generation: attachment.generation,
      attachment_id: attachment.attachment_id,
      control_epoch: attachment.control_epoch,
      controller: attachment.controller?
    })
    |> push_event("terminal_resync", %{
      terminal_id: attachment.terminal_id,
      generation: attachment.generation,
      resynced: attachment.resynced?
    })
  end

  defp push_terminal_frame(socket, attachment_id, frame, event) do
    case attachment_by_id(socket, attachment_id) do
      {:ok, attachment} ->
        data = Map.get(frame, :bytes)

        if is_binary(data) do
          push_event(socket, event, %{
            terminal_id: attachment.terminal_id,
            generation: attachment.generation,
            sequence: frame.sequence,
            data_base64: Base.encode64(data)
          })
        else
          socket
        end

      :error ->
        socket
    end
  end

  defp terminal_error(socket, %Sigma.Agent.Terminals.Error{code: code}),
    do: put_flash(socket, :error, "Terminal request failed: #{code}")

  defp terminal_error(socket, reason),
    do: put_flash(socket, :error, "Terminal is unavailable: #{terminal_reason(reason)}")

  defp terminal_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp terminal_reason(_reason), do: "unknown"

  defp revoke_terminal_authority(socket, terminal_id, %Sigma.Agent.Terminals.Error{
         code: code
       })
       when code in [
              :control_conflict,
              :controller_lease_expired,
              :not_controller,
              :stale_catalog_revision,
              :stale_control_epoch,
              :stale_run_generation,
              :stale_session_incarnation
            ] do
    case terminal_attachment(socket, terminal_id) do
      {:ok, attachment} ->
        attachment = %{attachment | controller?: false, resynced?: false}

        socket
        |> put_terminal_attachment(terminal_id, attachment)
        |> push_terminal_authority(attachment)

      {:error, _missing} ->
        socket
    end
  end

  defp revoke_terminal_authority(socket, _terminal_id, _error), do: socket

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp assign_session_defaults(
         socket,
         session_id,
         encoded_repository,
         workdir,
         sessions_dir,
         meta_path,
         log_session_id
       ) do
    socket
    |> assign(:active_tab, :repository)
    |> assign(:session_id, session_id)
    |> assign(:log_session_id, log_session_id)
    |> assign(:meta_path, meta_path)
    |> assign(:workdir, workdir)
    |> assign(:effective_cwd, workdir)
    |> assign(:encoded_repository, encoded_repository)
    |> assign(:sessions_dir, sessions_dir)
    |> assign(:agent, nil)
    |> assign(:agent_ref, nil)
    |> assign(:turn_in_flight, false)
    |> assign(:streaming_message_id, nil)
    |> assign(:tool_results, %{})
    |> assign(:tool_call_to_msg, %{})
    |> assign(:sessions, [])
    |> assign(:renaming_session, nil)
    |> assign(:pending_retry, nil)
    |> assign(:pending_fork, nil)
    |> assign(:pending_compaction, false)
    |> assign(:parent_session_id, nil)
    |> assign(:runtime_status, :loading)
    |> assign(:active_provider_id, nil)
    |> assign(:current_model, nil)
    |> assign(:current_model_value, nil)
    |> assign(:model_options, [])
    |> assign(:context_token_count, nil)
    |> assign(:context_window, nil)
    |> assign(:context_snapshot, nil)
    |> assign(:current_request_id, nil)
    |> assign(:branch_summaries, [])
    |> assign(:session_metrics, %{})
    |> assign(:session_metrics_state, Sigma.Session.Metrics.new(session_id))
    |> assign(:context_policy, %{})
    |> assign(:context_diagnostics, [])
    |> assign(:context_trace, [])
    |> assign(:pending_user_questions, [])
    |> assign(:pending_mcp_elicitations, [])
    |> assign(:logs_available, true)
    |> assign(:mcp_server_ids, [])
    |> assign(:show_logs, false)
    |> assign(:show_observability, false)
    |> assign(:log_entries, [])
    |> assign(:log_filter, nil)
    |> assign(:log_search, "")
    |> assign(:terminal_capability, %{status: :loading, reason: nil, details: %{}})
    |> assign(:terminal_catalog, %{
      status: :unavailable,
      reason: :loading,
      entries: [],
      retained_count: nil,
      state_counts: %{},
      revision: 0,
      selected_id: nil
    })
    |> assign(
      :terminal_session,
      Sigma.Agent.Terminals.Identity.session(
        Sigma.Agent.Runtime.normalize_repo_path(workdir),
        session_id,
        "loading"
      )
    )
    |> assign(:terminal_attachments, %{})
    |> assign(:terminal_pending_creators, MapSet.new())
    |> assign(:terminal_selected_id, nil)
    |> assign(:terminal_panel_open, false)
    |> assign(:session_ready, false)
    |> assign(:session_load, AsyncResult.loading())
  end

  defp session_observability_snapshot(assigns) do
    status =
      cond do
        not assigns[:session_ready] -> :loading
        true -> assigns[:runtime_status] || :idle
      end

    (assigns[:session_metrics] || %{})
    |> Map.put(:status, status)
    |> Map.put(:model, assigns[:current_model])
    |> Map.put(:context, assigns[:context_token_count])
    |> Map.put(:parent_session_id, assigns[:parent_session_id])
    |> Map.put(:parent_path, parent_session_path(assigns))
    |> Map.put(:current_request, current_request(assigns))
  end

  defp load_branch_summaries(%{header: header}, storage_path) when is_map(header) do
    case Sigma.Session.Log.branch_summaries(storage_path) do
      {:ok, summaries} -> summaries
      {:error, _reason} -> []
    end
  end

  defp load_branch_summaries(_snapshot, _storage_path), do: []

  defp context_budget_view(assigns) do
    snapshot = assigns[:context_snapshot]

    (assigns[:context_policy] || %{})
    |> Map.put(:estimate, snapshot && snapshot.next_request_estimated_input_tokens)
    |> Map.put(:last_measured, snapshot && snapshot.last_request_input_tokens)
    |> Map.put(:estimate_source, snapshot && snapshot.source)
    |> Map.put(:measurement_source, snapshot && snapshot.last_measurement_source)
    |> Map.put(:context_revision, snapshot && snapshot.context_revision)
    |> Map.put(:active_leaf, snapshot && snapshot.active_leaf)
    |> Map.put(:model, snapshot && snapshot.model)
    |> Map.put(:generated_at, snapshot && snapshot.generated_at)
  end

  defp apply_agent_status(socket, status) do
    context_snapshot = status[:context_snapshot]
    context_policy = status[:context_policy] || %{}

    assign(socket,
      runtime_status: status.phase,
      turn_in_flight: active_runtime_phase?(status.phase),
      context_snapshot: context_snapshot,
      current_request_id: status[:current_request_id],
      context_policy: context_policy,
      context_token_count: context_display_tokens(context_snapshot),
      context_window: context_policy[:context_window]
    )
  end

  defp context_display_tokens(%{next_request_estimated_input_tokens: estimate})
       when is_integer(estimate),
       do: estimate

  defp context_display_tokens(%{last_request_input_tokens: measured}) when is_integer(measured),
    do: measured

  defp context_display_tokens(_snapshot), do: nil

  defp runtime_phase(phase, _fallback) when is_atom(phase), do: phase
  defp runtime_phase(_phase, fallback), do: fallback

  defp current_request(assigns) do
    requests = get_in(assigns, [:session_metrics, :requests]) || %{}
    Map.get(requests, assigns[:current_request_id])
  end

  defp parent_session_path(%{parent_session_id: parent_id, encoded_repository: repository})
       when is_binary(parent_id),
       do: "/repository/#{repository}/sessions/#{URI.encode(parent_id)}"

  defp parent_session_path(_assigns), do: nil

  defp active_runtime_phase?(phase),
    do:
      phase in [
        :streaming_provider,
        :running_tools,
        :waiting_permission,
        :waiting_elicitation,
        :cancelling,
        :session_operation,
        :compacting
      ]

  defp session_process_runtime_status(:turn_running), do: :streaming_provider
  defp session_process_runtime_status(:starting), do: :loading
  defp session_process_runtime_status(:stopped), do: :interrupted
  defp session_process_runtime_status(_status), do: :idle

  defp resumed_runtime_status(socket) do
    if socket.assigns.turn_in_flight, do: :running_tools, else: :idle
  end

  defp metrics_runtime_status(:compaction, attrs, socket) do
    case attrs[:status] || attrs["status"] do
      status when status in [:started, "started"] -> :compacting
      _terminal -> resumed_runtime_status(socket)
    end
  end

  defp metrics_runtime_status(_fact, _attrs, socket), do: socket.assigns.runtime_status

  defp compact_error_message(:session_busy),
    do: "The session became busy before compaction started."

  defp compact_error_message(:session_not_running),
    do: "The session is not available for compaction."

  defp compact_error_message(reason), do: "Compaction failed: #{inspect(reason)}"

  defp ensure_metrics_session(%Sigma.Session.Metrics{} = state, session_id),
    do: %{state | session_id: session_id}

  defp session_event_handler(repo_key, session_id) do
    fn event ->
      Phoenix.PubSub.broadcast(Sigma.Web.PubSub, session_topic(repo_key, session_id), event)
    end
  end

  defp context_diagnostic_label(diagnostic) do
    kind = diagnostic.kind |> to_string() |> String.replace("_", " ")
    source = diagnostic.source || "unknown source"
    "#{kind}: #{source}"
  end

  defp context_trace_label(entry) do
    "#{entry.action} #{entry.kind}: #{entry.source} (#{entry.reason})"
  end

  defp session_ready?(socket), do: Map.get(socket.assigns, :session_ready, false)

  defp format_load_error(reason) when is_binary(reason), do: reason
  defp format_load_error(reason), do: inspect(reason)

  defp load_pending_user_questions(agent) do
    Sigma.Agent.pending_user_questions(agent, 100)
  catch
    :exit, _reason -> []
  end

  defp load_agent_status(agent) do
    GenServer.call(agent, :status, @session_start_timeout_ms)
  end

  defp load_pending_mcp_elicitations(agent) do
    Sigma.Agent.pending_mcp_elicitations(agent, 100)
  catch
    :exit, _reason -> []
  end

  defp upsert_mcp_elicitation(elicitations, elicitation) do
    elicitations
    |> remove_mcp_elicitation(elicitation.id)
    |> Kernel.++([elicitation])
  end

  defp remove_mcp_elicitation(elicitations, elicitation_id) do
    Enum.reject(elicitations, &(&1.id == elicitation_id))
  end

  defp reply_to_mcp_elicitation(socket, elicitation_id, reply) do
    Sigma.Agent.answer_mcp_elicitation(socket.assigns.agent, elicitation_id, reply)

    {:noreply,
     update(socket, :pending_mcp_elicitations, &remove_mcp_elicitation(&1, elicitation_id))}
  end

  defp coerce_mcp_elicitation_fields(fields) when is_map(fields) do
    Map.new(fields, fn {key, value} ->
      {to_string(key), coerce_mcp_field_value(value)}
    end)
  end

  defp coerce_mcp_elicitation_fields(_), do: %{}

  defp coerce_mcp_field_value("true"), do: true
  defp coerce_mcp_field_value("false"), do: false

  defp coerce_mcp_field_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} ->
        int

      _ ->
        case Float.parse(value) do
          {float, ""} -> float
          _ -> value
        end
    end
  end

  defp coerce_mcp_field_value(value), do: value

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
        "openai" -> Sigma.Ai.Providers.OpenAIResponses
        "openai-responses" -> Sigma.Ai.Providers.OpenAIResponses
        "openai-completions" -> Sigma.Ai.Providers.OpenAI
        _ -> Application.get_env(:sigma_web, :mock_provider_module)
      end

    cond do
      is_nil(provider_mod) ->
        {:error, "Unknown provider type: #{config["api_type"]}"}

      config["model"] in [nil, ""] ->
        {:error,
         "No model configured for provider #{config["name"]}. Go to Settings to configure one."}

      true ->
        {:ok, {provider_mod, config["model"], config["id"], provider_options(config)}}
    end
  end

  defp provider_options(config) do
    api_type = config["api_type"] || "anthropic"

    [
      api_key: config["resolved_key"] || "",
      base_url: config["base_url"] || "",
      auth_type: config["auth_type"] || default_auth_type(api_type),
      auth_header_name: config["auth_header_name"] || ""
    ]
  end

  defp default_auth_type(api_type)
       when api_type in ["openai", "openai-responses", "openai-completions"], do: "bearer"

  defp default_auth_type(_api_type), do: "x-api-key"

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
    ConfigManager.ensure_sessions_dir(workdir)
  end

  defp fetch_registered_repo(encoded_repository) do
    with {:ok, workdir} <- Base.url_decode64(encoded_repository, padding: false),
         %{} = repo <- RepoManager.get_repo(workdir) do
      {:ok, Path.expand(repo["path"]), repo}
    else
      _ -> {:error, :unknown_repository}
    end
  end

  defp redirect_unknown_repository(socket) do
    socket
    |> put_flash(:error, "Repository is not registered.")
    |> redirect(to: ~p"/")
  end

  defp redirect_invalid_session(socket, encoded_repository) do
    socket
    |> put_flash(:error, "Invalid session id.")
    |> redirect(to: ~p"/repository/#{encoded_repository}")
  end

  defp session_topic(repo_key, session_id), do: "session:#{repo_key}:#{session_id}"
  defp logs_topic(repo_key, session_id), do: "sigma:logs:#{repo_key}:#{session_id}"

  defp session_skills_context(effective_cwd) do
    Skills.Catalog.build(effective_cwd).skills
  end

  defp slash_commands(cwd) do
    builtins = [
      %{value: "/init", label: "/init", description: "Create or update AGENTS.md"},
      %{
        value: "/reload-tools",
        label: "/reload-tools",
        description: "Reconnect MCP servers and refresh their tools"
      }
    ]

    skills =
      cwd
      |> Kernel.||(".")
      |> Skills.Catalog.build()
      |> Map.get(:skills, [])
      |> Enum.filter(& &1.enabled?)
      |> Enum.map(fn skill ->
        %{value: "/#{skill.name}", label: "/#{skill.name}", description: skill.description}
      end)

    builtins ++ skills
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

  defp session_provider_config(%{"provider_id" => provider_id, "model_id" => model_id})
       when is_binary(provider_id) and is_binary(model_id) do
    with provider when is_map(provider) <- ConfigManager.get_provider_config(provider_id),
         true <- provider_has_model?(provider, model_id) do
      Map.put(provider, "model", model_id)
    else
      _ -> ConfigManager.get_active_provider_config()
    end
  end

  defp session_provider_config(_session_meta), do: ConfigManager.get_active_provider_config()

  defp session_provider_config(
         %{model_source: :journal, provider_id: provider_id, model_id: model_id},
         _session_meta
       )
       when is_binary(provider_id) and is_binary(model_id) do
    session_provider_config(%{"provider_id" => provider_id, "model_id" => model_id})
  end

  defp session_provider_config(%{model_source: :journal}, _session_meta),
    do: ConfigManager.get_active_provider_config()

  defp session_provider_config(_snapshot, session_meta),
    do: session_provider_config(session_meta)

  defp provider_has_model?(provider, model_id) do
    provider
    |> Map.get("models", [])
    |> List.wrap()
    |> Enum.map(&to_model_id/1)
    |> Enum.any?(&(&1 == model_id))
  end

  defp entry_matches?(_entry, nil, ""), do: true

  defp entry_matches?(entry, category, "") when not is_nil(category),
    do: entry.category == category

  defp entry_matches?(entry, nil, text), do: String.contains?(inspect(entry.metadata), text)

  defp entry_matches?(entry, category, text),
    do: entry.category == category and String.contains?(inspect(entry.metadata), text)

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:log_session_id] do
      Sigma.Logs.stop_session(socket.assigns.log_session_id)
    end

    :ok
  end
end
