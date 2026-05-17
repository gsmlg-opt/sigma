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

    socket = 
      if socket.assigns.live_action == :add do
        socket |> update_browser()
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto py-12 px-6 text-on-surface">
      <div :if={@live_action == :index} class="mb-12 flex justify-between items-end">
        <div>
          <h1 class="font-display text-5xl font-bold mb-2 tracking-tight text-primary">Repositories</h1>
          <p class="text-on-surface-variant text-lg">Select a project directory to start an agent session.</p>
        </div>
        <.dm_link navigate={~p"/workdir/new/project"} class="dm-btn dm-btn--primary dm-btn--lg" id="add-repo-btn">
          <div class="flex items-center gap-2">
            <.dm_mdi name="plus" class="w-5 h-5" />
            <span>Add Repository</span>
          </div>
        </.dm_link>
      </div>

      <div :if={@live_action == :index && Enum.empty?(@repos)} class="text-center py-24 bg-surface-container-low rounded-3xl border-2 border-dashed border-outline-variant">
        <.dm_mdi name="folder-open-outline" class="w-16 h-12 mx-auto text-on-surface-variant mb-4 opacity-40" />
        <h3 class="text-2xl font-semibold text-on-surface">No repositories added</h3>
        <p class="text-on-surface-variant mt-2 max-w-sm mx-auto">
          Add your first project directory to begin collaborating with π.
        </p>
        <.dm_link navigate={~p"/workdir/new/project"} class="dm-btn dm-btn--primary dm-btn--lg mt-8" id="add-first-repo-btn">
          <div class="flex items-center gap-2">
            <.dm_mdi name="plus" class="w-5 h-5" />
            <span>Add First Repository</span>
          </div>
        </.dm_link>
      </div>

      <div :if={@live_action == :index && !Enum.empty?(@repos)} class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6">
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
              <.dm_btn id={"remove-repo-#{Base.encode16(:crypto.hash(:md5, repo["path"]), case: :lower)}"} phx-click="remove_repo" phx-value-path={repo["path"]} phx-hook="WebComponentHook" variant="error" shape="circle" size="sm">
                <.dm_mdi name="delete-outline" class="w-4 h-4" />
              </.dm_btn>
            </div>
          </:action>
        </.dm_card>
      </div>

      <!-- Add Project View (New Page) -->
      <div :if={@live_action == :add} class="max-w-2xl mx-auto">
        <div class="mb-8 flex items-center gap-4 text-on-surface">
           <.dm_link navigate={~p"/"} class="dm-btn dm-btn--ghost dm-btn--sm shape-circle p-2">
             <.dm_mdi name="arrow-left" class="w-5 h-5" />
           </.dm_link>
           <h1 class="text-3xl font-bold font-display">Add Project Repository</h1>
        </div>

        <.dm_card variant="bordered" shadow="md" class="p-6">
          <div class="flex flex-col h-[500px]">
            <div class="flex items-center gap-2 mb-4 p-2 bg-surface-container-high rounded-lg border border-outline-variant">
              <.dm_btn id="browser-up-btn" phx-click="browser_up" phx-hook="WebComponentHook" variant="ghost" size="xs">
                <.dm_mdi name="arrow-up" class="w-4 h-4" />
              </.dm_btn>
              <div class="text-xs font-mono truncate flex-1 text-on-surface-variant">{@browsing_path}</div>
              <.dm_btn :if={is_git_repo?(@browsing_path)} id="is-git-badge" variant="success" size="xs" disabled>
                 <.dm_mdi name="git" class="w-4 h-4" />
              </.dm_btn>
            </div>
            
            <div class="flex-1 overflow-y-auto border border-outline-variant rounded-xl divide-y divide-outline-variant bg-surface-container-low">
              <div :for={entry <- @browser_entries} 
                   id={"entry-#{Base.encode16(:crypto.hash(:md5, entry.name), case: :lower)}"}
                   phx-click="browser_select" 
                   phx-hook="WebComponentHook"
                   phx-value-name={entry.name}
                   class="flex items-center gap-3 p-3 hover:bg-primary/5 cursor-pointer group transition-colors text-on-surface">
                <.dm_mdi name={if entry.is_dir, do: "folder", else: "file-outline"} 
                         class={if entry.is_dir, do: "text-secondary", else: "text-on-surface-variant opacity-40"} />
                <span class={"text-sm truncate flex-1 #{if !entry.is_dir, do: "opacity-60"}"}>{entry.name}</span>
                <.dm_mdi :if={entry.is_dir} name="chevron-right" class="w-4 h-4 opacity-0 group-hover:opacity-40 transition-opacity" />
              </div>
            </div>

            <div class="mt-6 pt-4 border-t border-outline-variant text-on-surface">
              <p class="text-[10px] opacity-40 mb-2 uppercase tracking-widest font-bold">Selected Path</p>
              <div class="p-3 bg-surface-container rounded-xl border border-outline-variant text-xs font-mono break-all">
                 {@browsing_path}
              </div>
              <div :if={@error} class="text-error text-sm mt-2 flex items-center gap-1 font-medium">
                <.dm_mdi name="alert-circle" class="w-4 h-4" />
                {@error}
              </div>
            </div>

            <div class="mt-6 flex justify-end gap-3">
               <.dm_link navigate={~p"/"} class="dm-btn dm-btn--ghost">Cancel</.dm_link>
               <.dm_btn id="confirm-add-btn" phx-click="browser_confirm" phx-hook="WebComponentHook" variant="primary">
                 Add This Directory
               </.dm_btn>
            </div>
          </div>
        </.dm_card>
      </div>

      <div :if={@live_action == :index} class="mt-16 grid grid-cols-1 md:grid-cols-3 gap-8 border-t border-outline-variant pt-12">
        <div class="flex flex-col items-center text-center p-6 bg-surface-container-low rounded-2xl">
          <.dm_mdi name="lightbulb-outline" class="w-8 h-8 text-warning mb-4" />
          <h3 class="font-bold text-lg mb-2">Multi-Turn Reasoner</h3>
          <p class="text-on-surface-variant text-sm leading-relaxed">
            π thinks in steps, explains its plan, and iterates until the task is complete.
          </p>
        </div>
        <div class="flex flex-col items-center text-center p-6 bg-surface-container-low rounded-2xl">
          <.dm_mdi name="shield-check-outline" class="w-8 h-8 text-success mb-4" />
          <h3 class="font-bold text-lg mb-2">Human-in-the-Loop</h3>
          <p class="text-on-surface-variant text-sm leading-relaxed">
            Restricted operations like bash commands or file edits require your explicit approval.
          </p>
        </div>
        <div class="flex flex-col items-center text-center p-6 bg-surface-container-low rounded-2xl">
          <.dm_mdi name="source-branch" class="w-8 h-8 text-primary mb-4" />
          <h3 class="font-bold text-lg mb-2">Time-Travel Debugging</h3>
          <p class="text-on-surface-variant text-sm leading-relaxed">
            Fork any session at any point to explore multiple solutions simultaneously.
          </p>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("show_add_modal", _, socket) do
    {:noreply, push_navigate(socket, to: ~p"/workdir/new/project")}
  end

  @impl true
  def handle_event("hide_add_modal", _, socket) do
    {:noreply, push_navigate(socket, to: ~p"/")}
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
    case RepoManager.add_repo(path) do
      {:ok, _entry} ->
        {:noreply, 
         socket 
         |> put_flash(:info, "Repository added successfully.")
         |> push_navigate(to: ~p"/")}
      _error ->
        {:noreply, assign(socket, error: "Could not add repository.")}
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
