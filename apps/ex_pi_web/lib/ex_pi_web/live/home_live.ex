defmodule ExPiWeb.HomeLive do
  use ExPiWeb, :live_view

  alias ExPiSession.RepoManager

  @impl true
  def mount(_params, _session, socket) do
    repos = RepoManager.list_repos()

    socket =
      socket
      |> assign(:active_tab, :home)
      |> assign(:repos, repos)
      |> assign(:show_add_modal, false)
      |> assign(:workdir, "")
      |> assign(:error, nil)
      |> assign(:browsing_path, System.user_home!())
      |> assign(:browser_entries, [])
      |> assign(:show_browser, true)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto py-12 px-6 text-on-surface">
      <div class="mb-12 flex justify-between items-end">
        <div>
          <h1 class="font-display text-5xl font-bold mb-2 tracking-tight text-primary">Repositories</h1>
          <p class="text-on-surface-variant text-lg">Select a project directory to start an agent session.</p>
        </div>
        <.dm_btn phx-click="show_add_modal" variant="primary" size="lg" id="add-repo-btn">
          <:prefix><.dm_mdi name="plus" class="w-5 h-5" /></:prefix>
          Add Repository
        </.dm_btn>
      </div>

      <div :if={Enum.empty?(@repos)} class="text-center py-24 bg-surface-container-low rounded-3xl border-2 border-dashed border-outline-variant">
        <.dm_mdi name="folder-open-outline" class="w-16 h-12 mx-auto text-on-surface-variant mb-4 opacity-40" />
        <h3 class="text-2xl font-semibold text-on-surface">No repositories added</h3>
        <p class="text-on-surface-variant mt-2 max-w-sm mx-auto">
          Add your first project directory to begin collaborating with π.
        </p>
        <.dm_btn phx-click="show_add_modal" variant="primary" size="lg" class="mt-8" id="add-first-repo-btn">
          Add First Repository
        </.dm_btn>
      </div>

      <div :if={!Enum.empty?(@repos)} class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
        <.dm_card :for={repo <- @repos} variant="bordered" class="group interactive hover:shadow-xl transition-all duration-300">
          <:title>
            <div class="flex items-center gap-3 overflow-hidden text-on-surface">
              <div class="p-2 bg-secondary/10 rounded-lg text-secondary">
                <.dm_mdi name={if is_git_repo?(repo["path"]), do: "git", else: "folder-sync"} class="w-5 h-5" />
              </div>
              <span class="truncate font-bold text-lg">{repo["name"]}</span>
            </div>
          </:title>
          
          <div class="py-4 px-1">
            <code class="text-[10px] opacity-60 break-all leading-tight font-mono">{repo["path"]}</code>
          </div>

          <:action>
            <div class="flex gap-2 w-full">
              <.dm_link navigate={~p"/workdir/#{Base.url_encode64(repo["path"], padding: false)}"} class="dm-btn dm-btn--outline flex-1 text-center">
                Open
              </.dm_link>
              <.dm_btn phx-click="remove_repo" phx-value-path={repo["path"]} variant="error" shape="circle" size="sm">
                <.dm_mdi name="delete-outline" class="w-4 h-4" />
              </.dm_btn>
            </div>
          </:action>
        </.dm_card>
      </div>

      <!-- Add Project Modal -->
      <.dm_modal :if={@show_add_modal} id="add-project-modal">
        <:title>Add Project Repository</:title>
        <:body>
          <div class="flex flex-col h-[500px]">
            <div class="flex items-center gap-2 mb-4 p-2 bg-surface-container-high rounded-lg border border-outline-variant">
              <.dm_btn phx-click="browser_up" variant="ghost" size="xs" id="browser-up-btn">
                <.dm_mdi name="arrow-up" class="w-4 h-4" />
              </.dm_btn>
              <div class="text-xs font-mono truncate flex-1 text-on-surface-variant">{@browsing_path}</div>
              <.dm_btn :if={is_git_repo?(@browsing_path)} variant="success" size="xs" disabled>
                 <.dm_mdi name="git" class="w-4 h-4" />
              </.dm_btn>
            </div>
            
            <div class="flex-1 overflow-y-auto border border-outline-variant rounded-xl divide-y divide-outline-variant bg-surface-container-low">
              <div :for={entry <- @browser_entries} 
                   phx-click="browser_select" 
                   phx-value-name={entry.name}
                   class="flex items-center gap-3 p-3 hover:bg-primary/5 cursor-pointer group transition-colors text-on-surface">
                <.dm_mdi name={if entry.is_dir, do: "folder", else: "file-outline"} 
                         class={if entry.is_dir, do: "text-secondary", else: "text-on-surface-variant opacity-40"} />
                <span class={"text-sm truncate flex-1 #{if !entry.is_dir, do: "opacity-60"}"}>{entry.name}</span>
                <.dm_mdi :if={entry.is_dir} name="chevron-right" class="w-4 h-4 opacity-0 group-hover:opacity-40 transition-opacity" />
              </div>
            </div>

            <div class="mt-6 pt-4 border-t border-outline-variant">
              <p class="text-[10px] opacity-40 text-on-surface mb-2 uppercase tracking-widest font-bold">Selected Path</p>
              <div class="p-3 bg-surface-container rounded-xl border border-outline-variant text-xs font-mono break-all text-on-surface">
                 {@browsing_path}
              </div>
              <div :if={@error} class="text-error text-sm mt-2 flex items-center gap-1 font-medium">
                <.dm_mdi name="alert-circle" class="w-4 h-4" />
                {@error}
              </div>
            </div>
          </div>
        </:body>
        <:footer>
           <.dm_btn phx-click="hide_add_modal" variant="ghost">Cancel</.dm_btn>
           <.dm_btn phx-click="browser_confirm" variant="primary">
             Add This Directory
           </.dm_btn>
        </:footer>
      </.dm_modal>
    </div>
    """
  end

  @impl true
  def handle_event("show_add_modal", _, socket) do
    socket = 
      socket 
      |> assign(show_add_modal: true, error: nil)
      |> update_browser()
    {:noreply, socket}
  end

  @impl true
  def handle_event("hide_add_modal", _, socket) do
    {:noreply, assign(socket, show_add_modal: false)}
  end

  @impl true
  def handle_event("browser_up", _, socket) do
    parent = Path.dirname(socket.assigns.browsing_path)
    {:noreply, socket |> assign(browsing_path: parent) |> update_browser()}
  end

  @impl true
  def handle_event("browser_select", %{"name" => name}, socket) do
    new_path = Path.join(socket.assigns.browsing_path, name)
    if File.dir?(new_path) do
      {:noreply, socket |> assign(browsing_path: new_path) |> update_browser()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("browser_confirm", _, socket) do
    path = socket.assigns.browsing_path
    IO.inspect(path, label: "HomeLive: Confirming directory")
    case RepoManager.add_repo(path) do
      {:ok, entry} ->
        IO.inspect(entry, label: "HomeLive: Repository added")
        {:noreply, 
         socket 
         |> assign(show_add_modal: false)
         |> assign(repos: RepoManager.list_repos())
         |> put_flash(:info, "Repository added successfully.")}
      error ->
        IO.inspect(error, label: "HomeLive: Error adding repository")
        {:noreply, assign(socket, error: "Could not add repository: #{inspect(error)}")}
    end
  end

  @impl true
  def handle_event("remove_repo", %{"path" => path}, socket) do
    RepoManager.remove_repo(path)
    {:noreply, assign(socket, repos: RepoManager.list_repos())}
  end

  defp update_browser(socket) do
    path = socket.assigns.browsing_path
    entries = 
      case File.ls(path) do
        {:ok, files} ->
          files
          |> Enum.reject(&String.starts_with?(&1, ".")) # Hide hidden files by default for cleaner UI
          |> Enum.map(fn f -> 
            %{name: f, is_dir: File.dir?(Path.join(path, f))}
          end)
          |> Enum.sort_by(fn e -> {!e.is_dir, e.name} end)
        _ ->
          []
      end
    assign(socket, browser_entries: entries)
  end

  defp is_git_repo?(path) do
    File.dir?(Path.join(path, ".git"))
  end
end
