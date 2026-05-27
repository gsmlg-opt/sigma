defmodule PiWeb.ProjectSidebar do
  use PiWeb, :html

  attr(:workdir, :string, required: true)
  attr(:encoded_repository, :string, required: true)
  attr(:active_item, :atom, default: :sessions)

  def project_sidebar(assigns) do
    ~H"""
    <aside class="w-80 bg-secondary text-secondary-content border-r border-outline-variant p-6 shrink-0 flex flex-col">
      <div class="flex items-center gap-2 mb-1 text-on-secondary">
        <.dm_mdi name="folder-outline" class="w-4 h-4 opacity-70" />
        <span class="text-xs uppercase tracking-widest font-bold opacity-70">Workspace</span>
      </div>
      <h2 class="font-semibold truncate text-on-secondary mb-6" title={@workdir}>
        {Path.basename(@workdir)}
      </h2>

      <nav class="flex flex-col gap-2">
        <.dm_link
          id="project-sidebar-settings"
          navigate={~p"/repository/#{@encoded_repository}/settings"}
          class={nav_item_class(@active_item == :settings)}
        >
          <div class="flex items-center gap-2">
            <.dm_mdi name="cog-outline" class="w-4 h-4" />
            <span>Settings</span>
          </div>
        </.dm_link>

        <.dm_link
          id="project-sidebar-skills"
          navigate={~p"/repository/#{@encoded_repository}/skills"}
          class={nav_item_class(@active_item == :skills)}
        >
          <div class="flex items-center gap-2">
            <.dm_mdi name="auto-fix" class="w-4 h-4" />
            <span>Skills</span>
          </div>
        </.dm_link>

        <.dm_link
          id="project-sidebar-hooks"
          navigate={~p"/repository/#{@encoded_repository}/hooks"}
          class={nav_item_class(@active_item == :hooks)}
        >
          <div class="flex items-center gap-2">
            <.dm_mdi name="hook" class="w-4 h-4" />
            <span>Hooks</span>
          </div>
        </.dm_link>

        <.dm_link
          id="project-sidebar-new-session"
          navigate={~p"/repository/#{@encoded_repository}/sessions/new"}
          class={nav_item_class(@active_item == :new_session)}
        >
          <div class="flex items-center gap-2">
            <.dm_mdi name="plus" class="w-4 h-4" />
            <span>New Session</span>
          </div>
        </.dm_link>

        <.dm_link
          id="project-sidebar-session-list"
          navigate={~p"/repository/#{@encoded_repository}"}
          class={nav_item_class(@active_item == :sessions)}
        >
          <div class="flex items-center gap-2">
            <.dm_mdi name="format-list-bulleted" class="w-4 h-4" />
            <span>Session List</span>
          </div>
        </.dm_link>
      </nav>

      <div class="mt-auto pt-6 border-t border-secondary-content/20 text-on-secondary">
        <p class="text-xs opacity-60 mb-2 uppercase tracking-wider font-bold">Full Path</p>
        <code class="text-[10px] break-all opacity-80 leading-tight font-mono">{@workdir}</code>
      </div>
    </aside>
    """
  end

  defp nav_item_class(true), do: "btn btn-primary w-full justify-start"
  defp nav_item_class(false), do: "btn btn-ghost w-full justify-start"
end
