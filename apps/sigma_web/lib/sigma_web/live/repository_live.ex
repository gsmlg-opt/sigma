defmodule Sigma.Web.RepositoryLive do
  use Sigma.Web, :live_view

  import Sigma.Web.ProjectSidebar

  alias Sigma.Session.{ConfigManager, RepoManager, SessionFiles}
  alias Sigma.Web.OperationError

  @impl true
  def mount(%{"repository" => encoded_repository}, _session, socket) do
    case fetch_registered_repo(encoded_repository) do
      {:ok, workdir, _repo} ->
        sessions_dir = get_sessions_dir(workdir)

        {:ok, sessions} = Sigma.Session.Log.list_session_summaries(sessions_dir)

        socket =
          socket
          |> assign(:active_tab, :repository)
          |> assign(:workdir, workdir)
          |> assign(:encoded_repository, encoded_repository)
          |> assign(:sessions_dir, sessions_dir)
          |> assign(:sessions, sessions)
          |> assign(:deleting_session, nil)
          |> assign(:renaming_session, nil)
          |> assign(:renaming_title, nil)

        {:ok, socket}

      {:error, :unknown_repository} ->
        {:ok, redirect_unknown_repository(socket)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex min-h-[calc(100vh-64px)]">
      <!-- Sidebar -->
      <.project_sidebar
        workdir={@workdir}
        encoded_repository={@encoded_repository}
        active_item={:sessions}
      />

      <!-- Content -->
      <main class="flex-1 p-8 bg-surface text-on-surface font-sans">
        <div class="max-w-5xl mx-auto">
          <div class="flex justify-between items-end mb-8 border-b border-outline-variant pb-6">
            <div>
              <h1 class="font-display text-4xl font-bold">Sessions</h1>
              <p class="text-on-surface-variant mt-2 text-lg">Manage your active coding sessions for this repository.</p>
            </div>
          </div>

          <div
            :if={Enum.empty?(@sessions)}
            class="text-center py-20 bg-surface-container-low rounded-3xl border-2 border-dashed border-outline-variant"
          >
            <.dm_mdi name="message-off-outline" class="w-12 h-12 mx-auto text-on-surface-variant mb-4 opacity-40" />
            <h3 class="text-xl font-semibold text-on-surface">No sessions yet</h3>
            <p class="text-on-surface-variant mt-2 max-w-sm mx-auto">
              Start your first session to begin collaborating with ∑ on this project.
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
              class="grid-stretch h-full group interactive hover:shadow-xl transition-all duration-300 bg-surface-container-low"
            >
              <:title class="min-w-0 flex-1 overflow-hidden">
                <form
                  :if={@renaming_session == s.session_id}
                  id={"rename-form-#{s.session_id}"}
                  phx-submit="save_rename_title"
                  class="flex w-full min-w-0 items-center gap-2 py-1"
                >
                  <input type="hidden" name="_id" value={s.session_id} />
                  <input
                    type="text"
                    name="title"
                    id={"rename-input-#{s.session_id}"}
                    value={@renaming_title}
                    maxlength="120"
                    autofocus
                    phx-blur="save_rename_title"
                    phx-value-id={s.session_id}
                    phx-keydown="rename_keydown"
                    phx-key="Escape"
                    class="flex-1 min-w-0 px-2 py-1 text-base font-semibold bg-surface text-on-surface rounded-lg border border-primary focus:outline-none focus:ring-2 focus:ring-primary/40"
                  />
                  <div class="flex items-center gap-1 shrink-0">
                    <.dm_btn
                      id={"save-title-#{s.session_id}"}
                      type="submit"
                      variant="primary"
                      size="sm"
                      shape="circle"
                      title="Save title"
                      phx-hook="WebComponentHook"
                    >
                      <.dm_mdi name="check" class="w-4 h-4" />
                    </.dm_btn>
                    <.dm_btn
                      id={"cancel-title-#{s.session_id}"}
                      type="button"
                      phx-click="cancel_rename_title"
                      variant="ghost"
                      size="sm"
                      shape="circle"
                      title="Cancel"
                      phx-hook="WebComponentHook"
                    >
                      <.dm_mdi name="close" class="w-4 h-4" />
                    </.dm_btn>
                  </div>
                </form>

                <div
                  :if={@renaming_session != s.session_id}
                  class="flex w-full min-w-0 max-w-full items-center justify-between gap-3 overflow-hidden py-1 text-on-surface"
                >
                  <div
                    class="flex min-w-0 flex-1 items-center gap-3 overflow-hidden cursor-pointer"
                    id={"session-title-container-#{s.session_id}"}
                    phx-hook="SessionTitleDblClick"
                    data-session-id={s.session_id}
                    title="Double-click to rename"
                  >
                    <div class="p-2 bg-primary/10 rounded-lg text-primary group-hover:bg-primary group-hover:text-primary-content transition-colors duration-300 shrink-0">
                      <.dm_mdi name="chat-processing-outline" class="w-5 h-5" />
                    </div>
                    <span class="block min-w-0 truncate font-bold text-lg" title={s.session_id}>{s.title}</span>
                  </div>
                  <div class="flex items-center gap-1 shrink-0">
                    <.dm_btn
                      id={"rename-session-#{s.session_id}"}
                      phx-click="start_rename_title"
                      phx-value-id={s.session_id}
                      phx-hook="WebComponentHook"
                      variant="ghost"
                      size="sm"
                      shape="circle"
                      class="shrink-0 opacity-0 group-hover:opacity-100 transition-opacity"
                      title="Rename session"
                    >
                      <.dm_mdi name="pencil-outline" class="w-4 h-4 text-on-surface-variant" />
                    </.dm_btn>
                    <.dm_btn
                      id={"delete-session-#{s.session_id}"}
                      phx-click="delete_session"
                      phx-value-id={s.session_id}
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
                </div>
              </:title>

              <div class="py-6 px-1">
                <p class="text-on-surface-variant text-sm italic opacity-60">
                  {s.latest_user_preview || "Session log available"}
                </p>
                <p :if={s.cwd_missing?} class="mt-2 text-xs text-warning">
                  Recorded working directory is missing; this session can be adopted.
                </p>
                <.dm_btn
                  :if={s.cwd_missing?}
                  id={"adopt-session-#{s.session_id}"}
                  phx-click="adopt_session"
                  phx-value-id={s.session_id}
                  phx-hook="WebComponentHook"
                  variant="ghost"
                  size="sm"
                  class="mt-3"
                >
                  Adopt into this repository
                </.dm_btn>
              </div>

              <:action>
                <.dm_link
                  navigate={~p"/repository/#{@encoded_repository}/sessions/#{s.session_id}"}
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
  def handle_event("delete_session", params, socket) do
    id = Map.get(params, "id")

    if SessionFiles.valid_session_id?(id) do
      {:noreply, assign(socket, deleting_session: id)}
    else
      {:noreply, put_flash(socket, :error, OperationError.message(:invalid_session_id))}
    end
  end

  @impl true
  def handle_event("cancel_delete", _, socket) do
    {:noreply, assign(socket, deleting_session: nil)}
  end

  @impl true
  def handle_event("confirm_delete", _, socket) do
    session_id = socket.assigns.deleting_session

    if SessionFiles.valid_session_id?(session_id) do
      case Sigma.Agent.Runtime.delete_session(
             socket.assigns.workdir,
             session_id,
             socket.assigns.sessions_dir
           ) do
        {:ok, _deleted} ->
          {:ok, sessions} = Sigma.Session.Log.list_session_summaries(socket.assigns.sessions_dir)

          {:noreply,
           socket
           |> assign(sessions: sessions, deleting_session: nil)
           |> put_flash(:info, "Session deleted successfully.")}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(deleting_session: nil)
           |> put_flash(:error, OperationError.message(reason))}
      end
    else
      {:noreply,
       socket
       |> assign(deleting_session: nil)
       |> put_flash(:error, OperationError.message(:invalid_session_id))}
    end
  end

  @impl true
  def handle_event("start_rename_title", params, socket) do
    id = Map.get(params, "id")

    if SessionFiles.valid_session_id?(id) do
      session = Enum.find(socket.assigns.sessions, &(&1.session_id == id))
      current_title = (session && session.title) || id

      {:noreply,
       socket
       |> assign(renaming_session: id, renaming_title: current_title)}
    else
      {:noreply, put_flash(socket, :error, OperationError.message(:invalid_session_id))}
    end
  end

  @impl true
  def handle_event("cancel_rename_title", _, socket) do
    {:noreply, assign(socket, renaming_session: nil, renaming_title: nil)}
  end

  @impl true
  def handle_event("rename_keydown", %{"key" => "Escape"}, socket) do
    {:noreply, assign(socket, renaming_session: nil, renaming_title: nil)}
  end

  @impl true
  def handle_event("rename_keydown", _, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("save_rename_title", params, socket) do
    id = Map.get(params, "id") || Map.get(params, "_id") || socket.assigns.renaming_session
    raw_title = Map.get(params, "title") || Map.get(params, "value") || ""
    new_title = raw_title |> String.trim() |> String.slice(0, 120)

    session = Enum.find(socket.assigns.sessions, &(&1.session_id == id))
    current_title = (session && session.title) || id

    cond do
      not SessionFiles.valid_session_id?(id) ->
        {:noreply,
         socket
         |> assign(renaming_session: nil, renaming_title: nil)
         |> put_flash(:error, OperationError.message(:invalid_session_id))}

      new_title == "" or new_title == current_title ->
        {:noreply, assign(socket, renaming_session: nil, renaming_title: nil)}

      true ->
        case SessionFiles.update_metadata(socket.assigns.sessions_dir, id, %{"title" => new_title}) do
          :ok ->
            updated_sessions =
              Enum.map(socket.assigns.sessions, fn
                %{session_id: ^id} = s -> %{s | title: new_title}
                s -> s
              end)

            {:ok, fresh_sessions} =
              Sigma.Session.Log.list_session_summaries(socket.assigns.sessions_dir)

            sessions = if fresh_sessions != [], do: fresh_sessions, else: updated_sessions

            {:noreply,
             socket
             |> assign(sessions: sessions, renaming_session: nil, renaming_title: nil)
             |> put_flash(:info, "Session title updated.")}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(renaming_session: nil, renaming_title: nil)
             |> put_flash(:error, OperationError.message(reason))}
        end
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
  def handle_event("adopt_session", params, socket) do
    session_id = Map.get(params, "id")

    if SessionFiles.valid_session_id?(session_id) do
      result =
        Sigma.Agent.Runtime.adopt_session(
          socket.assigns.workdir,
          session_id,
          socket.assigns.sessions_dir,
          socket.assigns.sessions_dir,
          socket.assigns.workdir
        )

      case result do
        {:ok, _adopted} ->
          {:ok, sessions} =
            Sigma.Session.Log.list_session_summaries(socket.assigns.sessions_dir)

          {:noreply,
           socket
           |> assign(:sessions, sessions)
           |> put_flash(:info, "Session adopted into this repository.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, OperationError.message(reason))}
      end
    else
      {:noreply, put_flash(socket, :error, OperationError.message(:invalid_session_id))}
    end
  end

  @impl true
  def handle_event("open_session", %{"id" => id}, socket) do
    {:noreply,
     push_navigate(socket,
       to: ~p"/repository/#{socket.assigns.encoded_repository}/sessions/#{id}"
     )}
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
end
