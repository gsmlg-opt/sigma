defmodule PiWeb.ProjectSkillsLive do
  use PiWeb, :live_view

  alias PiSession.Skills
  import PiWeb.ProjectSidebar

  @impl true
  def mount(%{"repository" => encoded_repository}, _session, socket) do
    workdir = Base.url_decode64!(encoded_repository, padding: false)
    skills_result = Skills.list_repository(workdir)

    socket =
      socket
      |> assign(:active_tab, :repository)
      |> assign(:workdir, workdir)
      |> assign(:encoded_repository, encoded_repository)
      |> assign(:skills_result, skills_result)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex min-h-[calc(100vh-64px)]">
      <.project_sidebar
        workdir={@workdir}
        encoded_repository={@encoded_repository}
        active_item={:skills}
      />

      <main class="flex-1 p-8 bg-surface text-on-surface font-sans">
        <div class="max-w-5xl mx-auto">
          <div class="flex justify-between items-end mb-8 border-b border-outline-variant pb-6">
            <div>
              <h1 class="font-display text-4xl font-bold">Repository Skills</h1>
              <p class="text-on-surface-variant mt-2 text-lg">
                Skills available from this repository.
              </p>
              <p class="text-sm text-on-surface-variant font-mono mt-2">{@skills_result.dir}</p>
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
        </div>
      </main>
    </div>
    """
  end
end
