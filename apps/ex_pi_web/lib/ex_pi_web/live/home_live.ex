defmodule ExPiWeb.HomeLive do
  use ExPiWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    sessions_root = get_sessions_root()
    File.mkdir_p!(sessions_root)

    recent_workdirs =
      sessions_root
      |> File.ls!()
      |> Enum.filter(&File.dir?(Path.join(sessions_root, &1)))
      |> Enum.map(fn encoded ->
        case Base.url_decode64(encoded, padding: false) do
          {:ok, path} -> {encoded, path}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(fn {_, path} -> path end)

    {:ok, assign(socket, active_tab: :home, workdir: "", error: nil, recent_workdirs: recent_workdirs)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto py-12 px-6 text-on-surface">
      <div class="mb-12 text-center">
        <h1 class="font-display text-5xl font-bold mb-4 tracking-tight">Welcome to π</h1>
        <p class="text-on-surface-variant text-xl">The Elixir-powered autonomous coding agent.</p>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-3 gap-8">
        <div class="lg:col-span-2 space-y-8">
          <.dm_card variant="bordered" shadow="md" class="p-8">
            <:title>
              <div class="flex items-center gap-3">
                <.dm_mdi name="folder-open" class="w-6 h-6 text-primary" />
                <span class="text-xl">Open Project Directory</span>
              </div>
            </:title>

            <form phx-submit="open_workdir" class="mt-6">
              <div class="flex flex-col gap-4">
                <.dm_input
                  type="text"
                  name="workdir"
                  value={@workdir}
                  placeholder="e.g. /Users/gao/Workspace/my-project"
                  label="Local Absolute Path"
                  autocomplete="off"
                />
                <div :if={@error} class="text-error text-sm mt-1 flex items-center gap-1">
                  <.dm_mdi name="alert-circle-outline" class="w-4 h-4" />
                  {@error}
                </div>
                <div class="flex justify-end mt-4">
                  <.dm_btn type="submit" variant="primary" size="lg">
                    Initialize Workspace
                  </.dm_btn>
                </div>
              </div>
            </form>
          </.dm_card>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
            <.dm_card variant="bordered" class="bg-surface-container-low p-6">
              <h3 class="font-semibold text-lg mb-2 flex items-center gap-2">
                <.dm_mdi name="lightbulb-outline" class="text-warning" />
                New to π?
              </h3>
              <p class="text-on-surface-variant text-sm leading-relaxed">
                π can read files, execute shell commands, and edit your code. It follows a multi-turn loop to solve complex tasks autonomously.
              </p>
            </.dm_card>

            <.dm_card variant="bordered" class="bg-surface-container-low p-6">
              <h3 class="font-semibold text-lg mb-2 flex items-center gap-2">
                <.dm_mdi name="shield-check-outline" class="text-success" />
                Safe by Design
              </h3>
              <p class="text-on-surface-variant text-sm leading-relaxed">
                Security is built-in. π cannot escape the working directory you set, and sensitive commands always require your explicit approval.
              </p>
            </.dm_card>
          </div>
        </div>

        <div class="space-y-6">
          <h2 class="font-display text-2xl font-bold px-2">Recent Projects</h2>
          <div :if={Enum.empty?(@recent_workdirs)} class="p-6 bg-surface-container rounded-2xl border border-outline-variant text-center">
            <p class="text-on-surface-variant text-sm italic">No project history found yet.</p>
          </div>
          
          <div :for={{encoded, path} <- @recent_workdirs} class="group">
            <.dm_link navigate={~p"/workdir/#{encoded}"} class="block p-4 rounded-2xl border border-outline-variant bg-surface hover:bg-surface-container-high hover:border-primary transition-all duration-200 shadow-sm hover:shadow-md">
              <div class="flex items-center gap-3 overflow-hidden text-on-surface">
                <.dm_mdi name="folder-sync-outline" class="w-5 h-5 text-secondary shrink-0" />
                <div class="min-w-0">
                  <div class="font-bold truncate text-sm">{Path.basename(path)}</div>
                  <div class="text-[10px] opacity-60 truncate font-mono mt-0.5">{path}</div>
                </div>
              </div>
            </.dm_link>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("open_workdir", %{"workdir" => path}, socket) do
    path = String.trim(path)

    if File.dir?(path) do
      encoded_path = Base.url_encode64(path, padding: false)
      {:noreply, push_navigate(socket, to: ~p"/workdir/#{encoded_path}")}
    else
      {:noreply, assign(socket, workdir: path, error: "Directory does not exist or is not accessible.")}
    end
  end

  defp get_sessions_root do
    Path.join(:code.priv_dir(:ex_pi_web), "sessions")
  end
end
