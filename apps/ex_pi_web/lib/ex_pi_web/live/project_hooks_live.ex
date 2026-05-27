defmodule PiWeb.ProjectHooksLive do
  use PiWeb, :live_view

  alias PiSession.ConfigManager
  import PiWeb.ProjectSidebar

  @impl true
  def mount(%{"repository" => encoded_repository}, _session, socket) do
    workdir = Base.url_decode64!(encoded_repository, padding: false)

    socket =
      socket
      |> assign(:active_tab, :repository)
      |> assign(:workdir, workdir)
      |> assign(:encoded_repository, encoded_repository)
      |> assign(:hooks_error, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    path = ConfigManager.project_hooks_file(socket.assigns.workdir)

    socket =
      socket
      |> assign(:hooks_json, ConfigManager.get_hooks_json(path))
      |> assign(:hooks_file, path)

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :hooks_example,
        ~S"""
        {
          "hooks": {
            "SessionStart": [
              {
                "hooks": [{ "type": "command", "command": "echo session started" }]
              }
            ],
            "PreToolUse": [
              {
                "matcher": "Bash",
                "hooks": [{ "type": "command", "command": "echo running bash" }]
              }
            ]
          }
        }
        """
      )

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

          <.dm_card variant="bordered" class="bg-surface-container-low">
            <form phx-submit="save_hooks" phx-change="change_hooks" class="space-y-4">
              <div class="flex items-center gap-2 text-on-surface">
                <.dm_mdi name="hook" class="w-5 h-5 text-primary" />
                <h3 class="text-lg font-bold">hooks.json</h3>
              </div>
              <code class="block text-[11px] font-mono text-on-surface-variant bg-surface-container rounded-lg px-3 py-2">
                {@hooks_file}
              </code>

              <div :if={@hooks_error} class="flex items-center gap-2 rounded-xl bg-error/10 text-error p-3 text-sm">
                <.dm_mdi name="alert-circle-outline" class="w-4 h-4 shrink-0" />
                <span>{@hooks_error}</span>
              </div>

              <textarea
                id="project-hooks-editor"
                name="hooks_json"
                phx-update="ignore"
                class="w-full font-mono text-sm bg-surface-container-high rounded-xl p-4 min-h-96 text-on-surface resize-y border border-outline-variant focus:outline-none focus:border-primary"
                spellcheck="false"
              >{@hooks_json}</textarea>

              <div class="flex justify-between pt-4 border-t border-outline-variant">
                <.dm_btn
                  id="project-hooks-format-btn"
                  type="button"
                  phx-click="format_hooks"
                  phx-hook="WebComponentHook"
                  variant="outline"
                  size="sm"
                >
                  <:prefix><.dm_mdi name="code-json" class="w-4 h-4" /></:prefix>
                  Format JSON
                </.dm_btn>
                <.dm_btn type="submit" phx-hook="WebComponentHook" variant="primary" size="md">
                  Save hooks.json
                </.dm_btn>
              </div>
            </form>
          </.dm_card>

          <div class="bg-primary/5 rounded-2xl p-6 border border-primary/10 text-sm space-y-3">
            <div class="flex items-center gap-2 text-primary font-bold">
              <.dm_mdi name="information-outline" class="w-5 h-5" />
              <span>About Hooks</span>
            </div>
            <p class="text-on-surface-variant leading-relaxed">
              Hooks run shell commands at key points in the agent lifecycle — before/after tool calls,
              on session start, and more. Project-level hooks apply only to sessions in this repository.
              The format is a JSON object with a top-level
              <code class="font-mono text-xs bg-surface-container px-1 py-0.5 rounded">hooks</code>
              key mapping event names to arrays of matcher groups.
            </p>
            <pre class="font-mono text-xs bg-surface-container rounded-xl p-4 text-on-surface-variant overflow-x-auto"><code>{@hooks_example}</code></pre>
          </div>
        </div>
      </main>
    </div>
    """
  end

  @impl true
  def handle_event("change_hooks", %{"hooks_json" => json}, socket) do
    {:noreply, assign(socket, hooks_json: json, hooks_error: nil)}
  end

  @impl true
  def handle_event("format_hooks", _, socket) do
    case Jason.decode(socket.assigns.hooks_json) do
      {:ok, data} ->
        {:noreply,
         assign(socket, hooks_json: Jason.encode!(data, pretty: true), hooks_error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, hooks_error: "Cannot format: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("save_hooks", %{"hooks_json" => json}, socket) do
    path = ConfigManager.project_hooks_file(socket.assigns.workdir)

    case ConfigManager.save_hooks_json(path, json) do
      :ok ->
        {:noreply,
         socket
         |> assign(hooks_json: json, hooks_error: nil)
         |> put_flash(:info, "hooks.json saved")}

      {:error, msg} ->
        {:noreply, assign(socket, hooks_error: msg)}
    end
  end
end
