defmodule ExPiWeb.WorkdirLive do
  use ExPiWeb, :live_view

  @impl true
  def mount(%{"workdir" => encoded_workdir}, _session, socket) do
    workdir = Base.url_decode64!(encoded_workdir, padding: false)
    sessions_dir = get_sessions_dir(workdir)
    File.mkdir_p!(sessions_dir)

    {:ok, sessions} = ExPiSession.Log.list_sessions(sessions_dir)

    socket =
      socket
      |> assign(:active_tab, :workdir)
      |> assign(:workdir, workdir)
      |> assign(:encoded_workdir, encoded_workdir)
      |> assign(:sessions_dir, sessions_dir)
      |> assign(:sessions, sessions)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex min-h-[calc(100vh-64px)]">
      <!-- Sidebar -->
      <aside class="w-80 bg-secondary text-secondary-content border-r border-outline-variant p-6 shrink-0 flex flex-col">
        <div class="flex items-center gap-2 mb-8 text-secondary-content">
          <.dm_mdi name="folder-sync" class="w-5 h-5" />
          <h2 class="font-semibold truncate" title={@workdir}>{Path.basename(@workdir)}</h2>
        </div>

        <.dm_left_menu id="sidebar-menu">
          <:title>Navigation</:title>
          <.dm_left_menu_group id="actions">
            <:title>Actions</:title>
            <div class="p-2">
              <.dm_btn phx-click="new_session" variant="primary" class="w-full mb-4">
                <:prefix><.dm_mdi name="plus" /></:prefix>
                New Session
              </.dm_btn>
            </div>
          </.dm_left_menu_group>
        </.dm_left_menu>

        <div class="mt-auto pt-6 border-t border-secondary-content/20">
          <p class="text-xs opacity-60 mb-2 uppercase tracking-wider font-bold">Full Path</p>
          <code class="text-[10px] break-all opacity-80 leading-tight">{@workdir}</code>
        </div>
      </aside>

      <!-- Content -->
      <main class="flex-1 p-8 bg-surface text-on-surface">
        <div class="max-w-5xl mx-auto">
          <div class="flex justify-between items-end mb-8 border-b border-outline-variant pb-6">
            <div>
              <h1 class="font-display text-4xl font-bold">Sessions</h1>
              <p class="text-on-surface-variant mt-2">Manage your active coding sessions for this workspace.</p>
            </div>
          </div>

          <div :if={Enum.empty?(@sessions)} class="text-center py-20 bg-surface-container-low rounded-3xl border-2 border-dashed border-outline-variant">
            <.dm_mdi name="message-off-outline" class="w-12 h-12 mx-auto text-on-surface-variant mb-4 opacity-40" />
            <h3 class="text-xl font-semibold text-on-surface">No sessions yet</h3>
            <p class="text-on-surface-variant mt-2 max-w-sm mx-auto">
              Start your first session to begin collaborating with π on this project.
            </p>
            <.dm_btn phx-click="new_session" variant="primary" size="lg" class="mt-8">
              Start First Session
            </.dm_btn>
          </div>

          <div :if={!Enum.empty?(@sessions)} class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
            <.dm_card :for={s <- @sessions} variant="bordered" class="group interactive hover:shadow-lg transition-all duration-200">
              <:title>
                <div class="flex items-center gap-3">
                  <.dm_mdi name="chat-processing-outline" class="text-primary" />
                  <span class="truncate">{s}</span>
                </div>
              </:title>
              
              <div class="py-4">
                <p class="text-on-surface-variant text-sm line-clamp-2 italic">
                  Session replayed from log.
                </p>
              </div>

              <:action>
                <.dm_btn phx-click="open_session" phx-value-id={s} variant="outline" size="sm">
                  Open
                </.dm_btn>
              </:action>
            </.dm_card>
          </div>
        </div>
      </main>
    </div>
    """
  end

  @impl true
  def handle_event("new_session", _, socket) do
    session_id = "session_#{System.unique_integer([:positive])}"
    {:noreply, push_navigate(socket, to: ~p"/workdir/#{socket.assigns.encoded_workdir}/sessions/#{session_id}")}
  end

  @impl true
  def handle_event("open_session", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/workdir/#{socket.assigns.encoded_workdir}/sessions/#{id}")}
  end

  defp get_sessions_dir(workdir) do
    # Map workdir to a safe folder name
    encoded_cwd = Base.url_encode64(workdir, padding: false)
    Path.join([:code.priv_dir(:ex_pi_web), "sessions", encoded_cwd])
  end
end
