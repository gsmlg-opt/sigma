defmodule PiWeb.RepositoryLive do
  use PiWeb, :live_view

  alias PiSession.Skills

  @impl true
  def mount(%{"repository" => encoded_repository}, _session, socket) do
    workdir = Base.url_decode64!(encoded_repository, padding: false)
    sessions_dir = get_sessions_dir(workdir)
    File.mkdir_p!(sessions_dir)

    {:ok, sessions} = PiSession.Log.list_sessions(sessions_dir)
    skills_result = Skills.list_repository(workdir)

    socket =
      socket
      |> assign(:active_tab, :repository)
      |> assign(:workdir, workdir)
      |> assign(:encoded_repository, encoded_repository)
      |> assign(:sessions_dir, sessions_dir)
      |> assign(:sessions, sessions)
      |> assign(:skills_result, skills_result)
      |> assign(:deleting_session, nil)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex min-h-[calc(100vh-64px)]">
      <!-- Sidebar -->
      <aside class="w-80 bg-secondary text-secondary-content border-r border-outline-variant p-6 shrink-0 flex flex-col">
        <div class="flex items-center justify-between gap-2 mb-6 text-on-secondary">
          <div class="flex items-center gap-2 min-w-0">
            <.dm_mdi name="folder-sync" class="w-5 h-5 shrink-0" />
            <h2 class="font-semibold truncate" title={@workdir}>{Path.basename(@workdir)}</h2>
          </div>
          <.dm_link
            navigate={~p"/repository/#{@encoded_repository}/settings"}
            class="btn btn-ghost btn-sm btn-circle shrink-0"
            id="project-settings-btn"
            title="Repository settings"
          >
            <.dm_mdi name="cog-outline" class="w-4 h-4" />
          </.dm_link>
        </div>

        <.dm_btn
          id="new-session-btn"
          phx-click="new_session"
          phx-hook="WebComponentHook"
          variant="primary"
          class="w-full mb-6"
        >
          <:prefix><.dm_mdi name="plus" class="w-4 h-4" /></:prefix>
          New Session
        </.dm_btn>

        <.dm_link
          navigate={~p"/"}
          class="btn btn-ghost w-full justify-start"
        >
          <div class="flex items-center gap-2">
            <.dm_mdi name="folder-multiple-outline" class="w-4 h-4" />
            <span>All Repositories</span>
          </div>
        </.dm_link>

        <div class="mt-auto pt-6 border-t border-secondary-content/20 text-on-secondary">
          <p class="text-xs opacity-60 mb-2 uppercase tracking-wider font-bold">Full Path</p>
          <code class="text-[10px] break-all opacity-80 leading-tight font-mono">{@workdir}</code>
        </div>
      </aside>

      <!-- Content -->
      <main class="flex-1 p-8 bg-surface text-on-surface font-sans">
        <div class="max-w-5xl mx-auto">
          <div class="flex justify-between items-end mb-8 border-b border-outline-variant pb-6">
            <div>
              <h1 class="font-display text-4xl font-bold">Sessions</h1>
              <p class="text-on-surface-variant mt-2 text-lg">Manage your active coding sessions for this repository.</p>
            </div>
          </div>

          <section class="mb-10">
            <div class="flex items-center justify-between gap-4 mb-4">
              <div>
                <h2 class="font-display text-2xl font-bold">Repository Skills</h2>
                <p class="text-sm text-on-surface-variant font-mono mt-1">{@skills_result.dir}</p>
              </div>
              <.dm_link navigate={~p"/settings/skills"} class="btn btn-ghost btn-sm shrink-0">
                <div class="flex items-center gap-2">
                  <.dm_mdi name="auto-fix" class="w-4 h-4" />
                  <span>Global Skills</span>
                </div>
              </.dm_link>
            </div>

            <div
              :if={Enum.empty?(@skills_result.skills)}
              class="rounded-2xl border border-dashed border-outline-variant bg-surface-container-low p-6 text-center"
            >
              <p class="font-semibold text-on-surface">No repository skills found</p>
            </div>

            <div :if={!Enum.empty?(@skills_result.skills)} class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <.dm_card :for={skill <- @skills_result.skills} variant="bordered" class="bg-surface-container-low">
                <:title>
                  <div class="flex items-center gap-3 py-1 min-w-0">
                    <div class="p-2 bg-primary/10 rounded-lg text-primary shrink-0">
                      <.dm_mdi name="auto-fix" class="w-5 h-5" />
                    </div>
                    <div class="min-w-0">
                      <div class="font-bold truncate">{skill.name}</div>
                      <div :if={skill.disable_model_invocation?} class="text-[10px] opacity-50 uppercase tracking-widest">
                        Manual invocation
                      </div>
                    </div>
                  </div>
                </:title>

                <div class="space-y-3">
                  <p class="text-sm text-on-surface-variant leading-relaxed">{skill.description}</p>
                  <code class="block text-[11px] font-mono text-on-surface-variant break-all bg-surface-container-high rounded-lg p-3">
                    {skill.path}
                  </code>
                </div>
              </.dm_card>
            </div>

            <div :if={!Enum.empty?(@skills_result.diagnostics)} class="mt-4 rounded-2xl border border-warning/30 bg-warning/10 p-4 text-warning">
              <div class="flex items-center gap-2 font-bold mb-2">
                <.dm_mdi name="alert-outline" class="w-5 h-5" />
                <span>Some repository skills could not be loaded</span>
              </div>
              <ul class="space-y-1 text-sm">
                <li :for={diagnostic <- @skills_result.diagnostics}>
                  <code class="font-mono break-all">{diagnostic.path}</code>: {diagnostic.message}
                </li>
              </ul>
            </div>
          </section>

          <div
            :if={Enum.empty?(@sessions)}
            class="text-center py-20 bg-surface-container-low rounded-3xl border-2 border-dashed border-outline-variant"
          >
            <.dm_mdi name="message-off-outline" class="w-12 h-12 mx-auto text-on-surface-variant mb-4 opacity-40" />
            <h3 class="text-xl font-semibold text-on-surface">No sessions yet</h3>
            <p class="text-on-surface-variant mt-2 max-w-sm mx-auto">
              Start your first session to begin collaborating with π on this project.
            </p>
            <.dm_btn
              id="start-first-session-btn"
              phx-click="new_session"
              phx-hook="WebComponentHook"
              variant="primary"
              size="lg"
              class="mt-8"
            >
              Start First Session
            </.dm_btn>
          </div>

          <div :if={!Enum.empty?(@sessions)} class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-8">
            <.dm_card
              :for={s <- @sessions}
              variant="bordered"
              class="group interactive hover:shadow-xl transition-all duration-300 bg-surface-container-low"
            >
              <:title>
                <div class="flex items-center justify-between gap-3 overflow-hidden text-on-surface py-1">
                  <div class="flex items-center gap-3 truncate min-w-0">
                    <div class="p-2 bg-primary/10 rounded-lg text-primary group-hover:bg-primary group-hover:text-primary-content transition-colors duration-300 shrink-0">
                      <.dm_mdi name="chat-processing-outline" class="w-5 h-5" />
                    </div>
                    <span class="truncate font-bold text-lg">{s}</span>
                  </div>
                  <.dm_btn
                    id={"delete-session-#{s}"}
                    phx-click="delete_session"
                    phx-value-id={s}
                    phx-hook="WebComponentHook"
                    variant="ghost"
                    size="sm"
                    shape="circle"
                    class="shrink-0 opacity-0 group-hover:opacity-100 transition-opacity"
                    title="Delete session"
                  >
                    <.dm_mdi name="delete-outline" class="w-4 h-4 text-error" />
                  </.dm_btn>
                </div>
              </:title>

              <div class="py-6 px-1">
                <p class="text-on-surface-variant text-sm italic opacity-60">
                   Session log available
                </p>
              </div>

              <:action>
                <.dm_link
                  navigate={~p"/repository/#{@encoded_repository}/sessions/#{s}"}
                  class="btn btn-primary w-full"
                >
                  Open Session
                </.dm_link>
              </:action>
            </.dm_card>
          </div>
        </div>
      </main>

      <!-- Delete Confirmation Modal -->
      <.dm_modal :if={@deleting_session} id="delete-session-modal" phx-hook="ModalHook">
        <:title>
          <div class="flex items-center gap-2 text-error">
            <.dm_mdi name="alert-circle-outline" class="w-6 h-6" />
            <span>Delete Session</span>
          </div>
        </:title>
        <:body>
          <p class="text-on-surface">
            Are you sure you want to delete the session <span class="font-bold">"{@deleting_session}"</span>?
            This action cannot be undone and all chat history will be permanently lost.
          </p>
        </:body>
        <:footer>
          <.dm_btn
            id="cancel-delete-btn"
            phx-click="cancel_delete"
            phx-hook="WebComponentHook"
            variant="ghost"
          >
            Cancel
          </.dm_btn>
          <.dm_btn
            id="confirm-delete-btn"
            phx-click="confirm_delete"
            phx-hook="WebComponentHook"
            variant="error"
          >
            Delete Permanently
          </.dm_btn>
        </:footer>
      </.dm_modal>
    </div>
    """
  end

  @impl true
  def handle_event("theme_changed", _, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("delete_session", %{"id" => id}, socket) do
    {:noreply, assign(socket, deleting_session: id)}
  end

  @impl true
  def handle_event("cancel_delete", _, socket) do
    {:noreply, assign(socket, deleting_session: nil)}
  end

  @impl true
  def handle_event("confirm_delete", _, socket) do
    session_id = socket.assigns.deleting_session
    file_path = Path.join(socket.assigns.sessions_dir, "#{session_id}.jsonl")

    case File.rm(file_path) do
      :ok ->
        {:ok, sessions} = PiSession.Log.list_sessions(socket.assigns.sessions_dir)

        {:noreply,
         socket
         |> assign(sessions: sessions, deleting_session: nil)
         |> put_flash(:info, "Session deleted successfully.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(deleting_session: nil)
         |> put_flash(:error, "Could not delete session: #{reason}")}
    end
  end

  @impl true
  def handle_event("new_session", _, socket) do
    {:noreply,
     push_navigate(socket,
       to: ~p"/repository/#{socket.assigns.encoded_repository}/sessions/new"
     )}
  end

  @impl true
  def handle_event("open_session", %{"id" => id}, socket) do
    {:noreply,
     push_navigate(socket,
       to: ~p"/repository/#{socket.assigns.encoded_repository}/sessions/#{id}"
     )}
  end

  defp get_sessions_dir(workdir) do
    PiSession.ConfigManager.sessions_dir(workdir)
  end
end
