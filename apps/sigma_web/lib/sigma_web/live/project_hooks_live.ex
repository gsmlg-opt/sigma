defmodule Sigma.Web.ProjectHooksLive do
  use Sigma.Web, :live_view

  alias Sigma.Session.{ConfigManager, RepoManager}
  import Sigma.Web.ProjectSidebar

  @impl true
  def mount(%{"repository" => encoded_repository}, _session, socket) do
    case fetch_registered_repo(encoded_repository) do
      {:ok, workdir, _repo} ->
        socket =
          socket
          |> assign(:active_tab, :repository)
          |> assign(:workdir, workdir)
          |> assign(:encoded_repository, encoded_repository)

        {:ok, socket}

      {:error, :unknown_repository} ->
        {:ok, redirect_unknown_repository(socket)}
    end
  end

  @impl true
  def handle_params(_params, _url, %{assigns: %{workdir: workdir}} = socket) do
    path = ConfigManager.project_hooks_file(workdir)

    socket =
      socket
      |> assign(:hooks_file, path)

    {:noreply, socket}
  end

  def handle_params(_params, _url, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex min-h-[calc(100vh-64px)]">
      <.project_sidebar
        workdir={@workdir}
        encoded_repository={@encoded_repository}
        active_item={:hooks}
      />

      <main class="flex-1 p-8 bg-surface text-on-surface font-sans">
        <div class="max-w-3xl mx-auto space-y-6">
          <div class="flex justify-between items-end border-b border-outline-variant pb-6">
            <div>
              <h1 class="font-display text-4xl font-bold">Project Hooks</h1>
              <p class="text-on-surface-variant mt-2 text-lg">
                Lifecycle hooks for this repository.
              </p>
            </div>

            <.dm_link navigate={~p"/settings/hooks"} class="btn btn-ghost btn-sm shrink-0">
              <div class="flex items-center gap-2">
                <.dm_mdi name="hook" class="w-4 h-4" />
                <span>Global Hooks</span>
              </div>
            </.dm_link>
          </div>

          <.live_component
            module={Sigma.Web.HooksSettingsComponent}
            id="project-hooks"
            path={@hooks_file}
            form_id="project-hooks-form"
            editor_id="project-hooks-editor"
          />
        </div>
      </main>
    </div>
    """
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
