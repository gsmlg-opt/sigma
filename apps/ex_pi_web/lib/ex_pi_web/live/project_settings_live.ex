defmodule PiWeb.ProjectSettingsLive do
  use PiWeb, :live_view

  alias PiSession.RepoManager

  @impl true
  def mount(%{"repository" => encoded_repository}, _session, socket) do
    workdir = Base.url_decode64!(encoded_repository, padding: false)
    repo = Enum.find(RepoManager.list_repos(), &(&1["path"] == workdir))

    socket =
      socket
      |> assign(:active_tab, :repository)
      |> assign(:encoded_repository, encoded_repository)
      |> assign(:workdir, workdir)
      |> assign(:repo, repo)
      |> assign(:name_input, (repo && repo["name"]) || Path.basename(workdir))
      |> assign(:path_input, workdir)
      |> assign(:error, nil)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex min-h-[calc(100vh-64px)]">
      <aside class="w-80 bg-secondary text-secondary-content border-r border-outline-variant p-6 shrink-0 flex flex-col">
        <div class="flex items-center gap-2 mb-8 text-on-secondary">
          <.dm_mdi name="cog-outline" class="w-5 h-5" />
          <h2 class="font-semibold truncate" title={@workdir}>Project Settings</h2>
        </div>

        <.dm_link
          navigate={~p"/repository/#{@encoded_repository}"}
          class="dm-btn dm-btn--ghost w-full justify-start"
        >
          <div class="flex items-center gap-2">
            <.dm_mdi name="arrow-left" class="w-4 h-4" />
            <span>Back to Sessions</span>
          </div>
        </.dm_link>

        <.dm_link
          navigate={~p"/"}
          class="dm-btn dm-btn--ghost w-full justify-start mt-2"
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

      <main class="flex-1 p-8 bg-surface text-on-surface font-sans">
        <div class="max-w-2xl mx-auto">
          <div class="mb-8 border-b border-outline-variant pb-6">
            <h1 class="font-display text-4xl font-bold">Project Settings</h1>
            <p class="text-on-surface-variant mt-2 text-lg">
              Rename this project or update its directory if you moved it on disk.
            </p>
          </div>

          <div :if={@repo == nil} class="bg-error/10 border border-error rounded-xl p-4 mb-6">
            <p class="text-error font-medium">
              This workspace is not in the repository list. Settings cannot be edited.
            </p>
          </div>

          <.dm_card :if={@repo} variant="bordered" class="mb-8 bg-surface-container-low">
            <:title>
              <div class="flex items-center gap-3 py-1">
                <.dm_mdi name="folder-edit-outline" class="w-5 h-5 text-primary" />
                <span class="font-bold text-lg">General</span>
              </div>
            </:title>

            <form phx-submit="save" class="space-y-6 p-2">
              <div>
                <label class="block text-sm font-medium mb-2">Display Name</label>
                <input
                  type="text"
                  name="name"
                  value={@name_input}
                  required
                  class="w-full px-3 py-2 rounded-lg border border-outline-variant bg-surface-container focus:border-primary focus:outline-none"
                />
                <p class="text-xs text-on-surface-variant mt-1 opacity-70">
                  Shown in the sidebar and on the repository card.
                </p>
              </div>

              <div>
                <label class="block text-sm font-medium mb-2">Directory Path</label>
                <input
                  type="text"
                  name="path"
                  value={@path_input}
                  required
                  class="w-full px-3 py-2 rounded-lg border border-outline-variant bg-surface-container focus:border-primary focus:outline-none font-mono text-sm"
                />
                <p class="text-xs text-on-surface-variant mt-1 opacity-70">
                  Use this when you have moved the project to a new location on disk. Existing sessions will be relocated to follow the new path.
                </p>
              </div>

              <div :if={@error} class="bg-error/10 border border-error rounded-lg p-3 text-error text-sm flex items-center gap-2">
                <.dm_mdi name="alert-circle" class="w-4 h-4" />
                {@error}
              </div>

              <div class="flex justify-end gap-3 pt-2">
                <.dm_link navigate={~p"/repository/#{@encoded_repository}"} class="dm-btn dm-btn--ghost">
                  Cancel
                </.dm_link>
                <.dm_btn type="submit" variant="primary">
                  Save Changes
                </.dm_btn>
              </div>
            </form>
          </.dm_card>

          <.dm_card :if={@repo} variant="bordered" class="bg-surface-container-low border-error/40">
            <:title>
              <div class="flex items-center gap-3 py-1">
                <.dm_mdi name="alert-octagon-outline" class="w-5 h-5 text-error" />
                <span class="font-bold text-lg">Danger Zone</span>
              </div>
            </:title>

            <div class="p-2">
              <p class="text-sm text-on-surface-variant mb-4">
                Remove this repository from the list. Existing session files on disk are kept; you can re-add the directory later to get back to them.
              </p>
              <.dm_btn
                phx-click="remove"
                phx-hook="WebComponentHook"
                id="remove-repo-btn"
                variant="error"
                confirm="Remove this repository from the list? Session files will be kept on disk."
                confirm_title="Remove Repository"
              >
                <:prefix><.dm_mdi name="delete-outline" class="w-4 h-4" /></:prefix>
                Remove Repository
              </.dm_btn>
            </div>
          </.dm_card>
        </div>
      </main>
    </div>
    """
  end

  @impl true
  def handle_event("save", %{"name" => name, "path" => raw_path}, socket) do
    old_path = socket.assigns.workdir
    new_path = Path.expand(String.trim(raw_path))
    new_name = String.trim(name)

    cond do
      new_name == "" ->
        {:noreply, assign(socket, :error, "Display name cannot be empty.")}

      !File.dir?(new_path) ->
        {:noreply, assign(socket, :error, "Directory does not exist: #{new_path}")}

      true ->
        case apply_changes(old_path, new_path, new_name) do
          {:ok, new_encoded} ->
            {:noreply,
             socket
             |> put_flash(:info, "Project settings saved.")
             |> push_navigate(to: ~p"/repository/#{new_encoded}/settings")}

          {:error, :path_conflict} ->
            {:noreply,
             assign(
               socket,
               :error,
               "Another repository already uses this directory."
             )}

          {:error, :not_found} ->
            {:noreply, assign(socket, :error, "This repository is no longer in the list.")}

          {:error, reason} ->
            {:noreply, assign(socket, :error, "Could not save: #{inspect(reason)}")}
        end
    end
  end

  @impl true
  def handle_event("remove", _, socket) do
    RepoManager.remove_repo(socket.assigns.workdir)
    {:noreply, socket |> put_flash(:info, "Repository removed.") |> push_navigate(to: ~p"/")}
  end

  defp apply_changes(old_path, new_path, new_name) do
    with :ok <- rename_sessions_dir(old_path, new_path),
         {:ok, _entry} <-
           RepoManager.update_repo(old_path, %{"name" => new_name, "path" => new_path}) do
      {:ok, Base.url_encode64(new_path, padding: false)}
    end
  end

  defp rename_sessions_dir(same, same), do: :ok

  defp rename_sessions_dir(old_path, new_path) do
    root = PiWeb.get_sessions_root()
    old_dir = Path.join(root, Base.url_encode64(old_path, padding: false))
    new_dir = Path.join(root, Base.url_encode64(new_path, padding: false))

    cond do
      not File.dir?(old_dir) -> :ok
      File.exists?(new_dir) -> {:error, :sessions_dir_conflict}
      true -> File.rename(old_dir, new_dir)
    end
  end
end
