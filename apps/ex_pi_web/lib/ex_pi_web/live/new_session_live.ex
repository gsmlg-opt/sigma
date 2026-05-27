defmodule PiWeb.NewSessionLive do
  use PiWeb, :live_view

  alias PiSession.{ConfigManager, Log, RepoManager}
  import PiWeb.ProjectSidebar

  @impl true
  def mount(%{"repository" => encoded_repository}, _session, socket) do
    workdir = Base.url_decode64!(encoded_repository, padding: false)
    sessions_dir = get_sessions_dir(workdir)
    File.mkdir_p!(sessions_dir)

    branches = list_git_branches(workdir)
    worktrees = list_existing_worktrees(workdir)
    mcp_servers = ConfigManager.list_mcp_servers()

    selected_mcp_server_ids =
      RepoManager.mcp_server_ids(workdir) |> filter_mcp_server_ids(mcp_servers)

    socket =
      socket
      |> assign(:active_tab, :repository)
      |> assign(:workdir, workdir)
      |> assign(:encoded_repository, encoded_repository)
      |> assign(:sessions_dir, sessions_dir)
      |> assign(:branches, branches)
      |> assign(:worktrees, worktrees)
      |> assign(:selected_branch, List.first(branches))
      |> assign(:mode, :project_dir)
      |> assign(:selected_worktree, List.first(worktrees))
      |> assign(:worktree_name, "")
      |> assign(:mcp_servers, mcp_servers)
      |> assign(:selected_mcp_server_ids, selected_mcp_server_ids)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex min-h-[calc(100vh-64px)]">
      <!-- Sidebar -->
      <.project_sidebar
        workdir={@workdir}
        encoded_repository={@encoded_repository}
        active_item={:new_session}
      />

      <!-- Content -->
      <main class="flex-1 p-8 bg-surface text-on-surface font-sans">
        <div class="max-w-2xl mx-auto">
          <div class="mb-8 border-b border-outline-variant pb-6">
            <h1 class="font-display text-4xl font-bold">New Session</h1>
            <p class="text-on-surface-variant mt-2 text-lg">
              Configure your working environment for this session.
            </p>
          </div>

          <div class="space-y-6">
            <!-- Branch selection (searchable) -->
            <.dm_card :if={!Enum.empty?(@branches)} variant="bordered" class="bg-surface-container-low">
              <:title>
                <div class="flex items-center gap-2 text-on-surface py-1">
                  <.dm_mdi name="source-branch" class="w-5 h-5 text-primary" />
                  <span class="font-semibold">Branch</span>
                </div>
              </:title>
              <div class="py-4 px-1">
                <.dm_autocomplete
                  id="branch-autocomplete"
                  name="branch"
                  value={@selected_branch}
                  placeholder="Search branches…"
                  options={Enum.map(@branches, &%{value: &1, label: &1})}
                  clearable={false}
                  class="w-full"
                  phx-hook="AutocompleteHook"
                  data-event="select_branch"
                />
              </div>
            </.dm_card>

            <!-- Working directory mode -->
            <.dm_card variant="bordered" class="bg-surface-container-low">
              <:title>
                <div class="flex items-center gap-2 text-on-surface py-1">
                  <.dm_mdi name="folder-cog-outline" class="w-5 h-5 text-primary" />
                  <span class="font-semibold">Working Directory</span>
                </div>
              </:title>
              <div class="py-4 px-1 space-y-3">
                <.mode_option
                  id="mode-project-dir"
                  value={:project_dir}
                  current_mode={@mode}
                  label="Use project directory"
                  description={@workdir}
                  icon="folder-outline"
                />

                <.mode_option
                  :if={!Enum.empty?(@branches)}
                  id="mode-create-worktree"
                  value={:create_worktree}
                  current_mode={@mode}
                  label="Create new worktree"
                  description={worktree_preview_path(assigns)}
                  icon="folder-plus-outline"
                />

                <.mode_option
                  :if={!Enum.empty?(@worktrees)}
                  id="mode-existing-worktree"
                  value={:existing_worktree}
                  current_mode={@mode}
                  label="Use existing worktree"
                  description="Select from existing worktrees below"
                  icon="folder-sync-outline"
                />

                <!-- Worktree name input (when creating a new worktree) -->
                <div :if={@mode == :create_worktree} class="mt-2 pl-4 border-l-2 border-primary space-y-3">
                  <div>
                    <label class="text-sm font-medium mb-2 block text-on-surface">
                      Worktree directory name
                    </label>
                    <form phx-change="update_worktree_name">
                      <input
                        type="text"
                        name="worktree_name"
                        value={@worktree_name}
                        class="input input-bordered w-full"
                        placeholder="worktree-xxxxxx (auto-generated)"
                        phx-debounce="200"
                      />
                    </form>
                    <p class="text-xs text-on-surface-variant mt-1">
                      Leave empty to auto-generate a name like
                      <code class="font-mono">worktree-a1b2c3</code>
                    </p>
                  </div>
                </div>

                <!-- Existing worktree selector -->
                <div
                  :if={@mode == :existing_worktree and !Enum.empty?(@worktrees)}
                  class="mt-2 pl-4 border-l-2 border-primary"
                >
                  <form phx-change="select_worktree">
                    <.dm_select
                      id="worktree-select"
                      name="worktree"
                      value={@selected_worktree && @selected_worktree.path}
                      class="w-full"
                    >
                      <option
                        :for={wt <- @worktrees}
                        value={wt.path}
                        selected={@selected_worktree && wt.path == @selected_worktree.path}
                      >
                        {wt.branch} — {wt.path}
                      </option>
                    </.dm_select>
                  </form>
                </div>
              </div>
            </.dm_card>

            <!-- MCP server overrides -->
            <.dm_card :if={map_size(@mcp_servers) > 0} variant="bordered" class="bg-surface-container-low">
              <:title>
                <div class="flex items-center gap-2 text-on-surface py-1">
                  <.dm_mdi name="server-network-outline" class="w-5 h-5 text-primary" />
                  <span class="font-semibold">MCP Servers</span>
                </div>
              </:title>
              <form id="session-mcp-form" phx-change="select_mcp_servers" class="py-4 px-1 space-y-2">
                <label
                  :for={{id, server} <- @mcp_servers}
                  class="flex items-start gap-3 p-3 rounded-xl border border-outline-variant hover:border-outline cursor-pointer"
                >
                  <input
                    type="checkbox"
                    name="mcp_server_ids[]"
                    value={id}
                    checked={id in @selected_mcp_server_ids}
                    class="checkbox checkbox-primary mt-1"
                  />
                  <div class="min-w-0">
                    <p class="font-semibold text-sm text-on-surface">{id}</p>
                    <p class="text-xs text-on-surface-variant font-mono break-all">
                      {mcp_server_summary(server)}
                    </p>
                  </div>
                </label>
              </form>
            </.dm_card>

            <!-- Path preview -->
            <div class="bg-surface-container rounded-xl p-4 border border-outline-variant">
              <p class="text-xs text-on-surface-variant uppercase tracking-wider font-bold mb-2">
                Session working directory
              </p>
              <code class="text-sm font-mono break-all">{effective_path(assigns)}</code>
            </div>

            <!-- Actions -->
            <div class="flex gap-4 justify-end pt-2">
              <.dm_link navigate={~p"/repository/#{@encoded_repository}"} class="btn btn-ghost">
                Cancel
              </.dm_link>
              <.dm_btn
                id="create-session-btn"
                phx-click="create_session"
                phx-hook="WebComponentHook"
                variant="primary"
                size="lg"
              >
                <:prefix><.dm_mdi name="plus" class="w-5 h-5" /></:prefix>
                Create Session
              </.dm_btn>
            </div>
          </div>
        </div>
      </main>
    </div>
    """
  end

  defp mode_option(assigns) do
    assigns = assign(assigns, :selected, assigns.value == assigns.current_mode)

    ~H"""
    <button
      id={@id}
      type="button"
      phx-click="set_mode"
      phx-value-mode={@value}
      class={[
        "w-full text-left p-4 rounded-xl border-2 transition-all duration-200 cursor-pointer",
        if(@selected,
          do: "border-primary bg-primary/5",
          else: "border-outline-variant hover:border-outline bg-transparent"
        )
      ]}
    >
      <div class="flex items-start gap-3">
        <.dm_mdi
          name={@icon}
          class={[
            "w-5 h-5 mt-0.5 shrink-0",
            if(@selected, do: "text-primary", else: "text-on-surface-variant")
          ]}
        />
        <div class="min-w-0 flex-1">
          <p class={[
            "font-semibold text-sm",
            if(@selected, do: "text-primary", else: "text-on-surface")
          ]}>
            {@label}
          </p>
          <p class="text-xs text-on-surface-variant mt-0.5 break-all font-mono">{@description}</p>
        </div>
        <div class={[
          "ml-auto w-4 h-4 rounded-full border-2 shrink-0 mt-0.5 flex items-center justify-center",
          if(@selected, do: "border-primary", else: "border-outline")
        ]}>
          <div :if={@selected} class="w-2 h-2 rounded-full bg-primary"></div>
        </div>
      </div>
    </button>
    """
  end

  defp worktree_preview_path(assigns) do
    name =
      if assigns.worktree_name != "",
        do: assigns.worktree_name,
        else: "worktree-xxxxxx"

    if assigns.selected_branch,
      do: Path.join([assigns.workdir, ".trees", name]),
      else: "Select a branch first"
  end

  defp mcp_server_summary(%{"type" => "stdio", "command" => command, "args" => args}) do
    Enum.join([command | args], " ")
  end

  defp mcp_server_summary(%{"type" => type, "url" => url}), do: "#{type}: #{url}"
  defp mcp_server_summary(server), do: inspect(server)

  defp effective_path(assigns) do
    case assigns.mode do
      :project_dir ->
        assigns.workdir

      :create_worktree ->
        if assigns.selected_branch do
          name =
            if assigns.worktree_name != "",
              do: assigns.worktree_name,
              else: "worktree-xxxxxx"

          Path.join([assigns.workdir, ".trees", name])
        else
          assigns.workdir
        end

      :existing_worktree ->
        case assigns.selected_worktree do
          %{path: path} -> path
          _ -> assigns.workdir
        end
    end
  end

  @impl true
  def handle_event("theme_changed", _, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("select_branch", %{"branch" => branch}, socket) do
    {:noreply, assign(socket, :selected_branch, branch)}
  end

  @impl true
  def handle_event("set_mode", %{"mode" => mode}, socket) do
    mode_atom =
      case mode do
        "create_worktree" -> :create_worktree
        "existing_worktree" -> :existing_worktree
        _ -> :project_dir
      end

    {:noreply, assign(socket, :mode, mode_atom)}
  end

  @impl true
  def handle_event("update_worktree_name", %{"worktree_name" => name}, socket) do
    {:noreply, assign(socket, :worktree_name, String.trim(name))}
  end

  @impl true
  def handle_event("select_worktree", %{"worktree" => path}, socket) do
    worktree = Enum.find(socket.assigns.worktrees, fn wt -> wt.path == path end)
    {:noreply, assign(socket, :selected_worktree, worktree)}
  end

  @impl true
  def handle_event("select_mcp_servers", params, socket) do
    ids = params |> Map.get("mcp_server_ids", []) |> List.wrap()
    {:noreply, assign(socket, :selected_mcp_server_ids, ids)}
  end

  @impl true
  def handle_event("create_session", _, socket) do
    workdir = socket.assigns.workdir
    branch = socket.assigns.selected_branch
    mode = socket.assigns.mode
    session_id = "session_#{System.unique_integer([:positive])}"
    sessions_dir = socket.assigns.sessions_dir
    meta_path = Path.join(sessions_dir, "#{session_id}.meta.json")
    log_path = Path.join(sessions_dir, "#{session_id}.jsonl")

    {cwd, is_worktree} =
      case mode do
        :create_worktree when is_binary(branch) ->
          dir_name =
            if socket.assigns.worktree_name != "",
              do: socket.assigns.worktree_name,
              else: "worktree-#{:crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)}"

          worktree_path = Path.join([workdir, ".trees", dir_name])

          System.cmd("git", ["-C", workdir, "worktree", "add", worktree_path, branch],
            stderr_to_stdout: true
          )

          {worktree_path, true}

        :existing_worktree ->
          case socket.assigns.selected_worktree do
            %{path: path} -> {path, true}
            _ -> {workdir, false}
          end

        _ ->
          {workdir, false}
      end

    meta = %{
      cwd: cwd,
      branch: branch,
      worktree: is_worktree,
      mcp_server_ids: socket.assigns.selected_mcp_server_ids
    }

    File.write!(meta_path, Jason.encode!(meta))
    :ok = Log.persist_event(log_path, {:agent_start, cwd})

    {:noreply,
     push_navigate(socket,
       to: ~p"/repository/#{socket.assigns.encoded_repository}/sessions/#{session_id}"
     )}
  end

  defp get_sessions_dir(workdir) do
    PiSession.ConfigManager.sessions_dir(workdir)
  end

  defp list_git_branches(workdir) do
    case System.cmd("git", ["-C", workdir, "branch", "--format=%(refname:short)"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  defp list_existing_worktrees(workdir) do
    case System.cmd("git", ["-C", workdir, "worktree", "list", "--porcelain"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output
        |> String.split("\n\n", trim: true)
        |> Enum.map(&parse_worktree_entry/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.reject(fn wt -> wt.path == workdir end)

      _ ->
        []
    end
  end

  defp parse_worktree_entry(entry) do
    lines = String.split(entry, "\n", trim: true)

    path =
      Enum.find_value(lines, fn line ->
        case String.split(line, " ", parts: 2) do
          ["worktree", p] -> p
          _ -> nil
        end
      end)

    branch =
      Enum.find_value(lines, fn line ->
        case String.split(line, " ", parts: 2) do
          ["branch", b] -> Path.basename(b)
          _ -> nil
        end
      end)

    if path, do: %{path: path, branch: branch}, else: nil
  end

  defp filter_mcp_server_ids(ids, servers) do
    Enum.filter(ids, &Map.has_key?(servers, &1))
  end
end
