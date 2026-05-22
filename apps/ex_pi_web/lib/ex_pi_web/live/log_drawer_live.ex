defmodule PiWeb.LogDrawerLive do
  use PiWeb, :live_component

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:selected_entry, fn -> nil end)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="fixed right-0 top-16 h-[calc(100vh-4rem)] w-[480px] z-50 bg-surface text-surface-content shadow-xl flex flex-col border-l border-outline/20"
    >
      <%!-- Header --%>
      <div class="flex items-center justify-between px-4 py-3 border-b border-outline/20 bg-surface-variant">
        <span class="font-semibold text-sm">Debug Logs</span>
        <button
          phx-click="toggle_logs"
          phx-target={@myself}
          class="text-surface-content/60 hover:text-surface-content"
        >
          <.dm_mdi name="close" class="w-5 h-5" />
        </button>
      </div>

      <%!-- Filters --%>
      <div class="flex items-center gap-2 px-4 py-2 border-b border-outline/20 flex-wrap">
        <button
          :for={{cat, label} <- [llm: "LLM", tool: "Tool", permission: "Permission"]}
          phx-click="set_log_filter"
          phx-value-category={if @filter == cat, do: "", else: cat}
          class={[
            "px-2 py-1 rounded text-xs font-medium transition-colors",
            @filter == cat && category_active_class(cat),
            @filter != cat && "bg-surface-variant text-surface-content/60 hover:text-surface-content"
          ]}
        >
          {label}
        </button>
        <input
          type="text"
          placeholder="Search…"
          value={@search}
          phx-keyup="set_log_search"
          phx-key="Enter"
          class="ml-auto text-xs px-2 py-1 rounded bg-surface-variant border border-outline/20 focus:outline-none focus:border-primary w-36"
        />
      </div>

      <%!-- Entry list --%>
      <div class="flex-1 overflow-y-auto divide-y divide-outline/10">
        <div
          :for={entry <- @entries}
          id={"log-entry-#{entry.id}"}
          class="px-4 py-2 hover:bg-surface-variant/50 cursor-pointer"
          phx-click="select_entry"
          phx-value-id={entry.id}
          phx-target={@myself}
        >
          <div class="flex items-center gap-2">
            <span class={["px-1.5 py-0.5 rounded text-[10px] font-bold uppercase", category_badge_class(entry.category)]}>
              {entry.category}
            </span>
            <span class="text-xs text-surface-content/50 font-mono">{entry.event}</span>
            <span
              id={"log-ts-#{entry.id}"}
              class="ml-auto text-[10px] text-surface-content/40 font-mono"
              phx-hook="LocalTime"
              data-ts={entry.timestamp}
            >{format_ts(entry.timestamp)}</span>
          </div>
          <p class="text-xs text-surface-content/60 mt-0.5 truncate">{summarize(entry)}</p>
        </div>
        <div :if={@entries == []} class="px-4 py-8 text-center text-sm text-surface-content/40">
          No log entries yet.
        </div>
      </div>

      <%!-- Entry detail popover --%>
      <div
        :if={@selected_entry}
        class="fixed inset-0 z-[100] flex items-center justify-center bg-black/50"
        phx-click="close_entry"
        phx-target={@myself}
      >
        <div
          class="bg-surface text-surface-content rounded-lg shadow-2xl w-[90vw] max-w-4xl max-h-[90vh] flex flex-col overflow-hidden"
          onclick="event.stopPropagation()"
        >
          <div class="flex items-center justify-between px-4 py-3 border-b border-outline/20 bg-surface-variant shrink-0">
            <div class="flex items-center gap-2">
              <span class={["px-1.5 py-0.5 rounded text-[10px] font-bold uppercase", category_badge_class(@selected_entry.category)]}>
                {@selected_entry.category}
              </span>
              <span class="text-sm font-mono">{@selected_entry.event}</span>
            </div>
            <button
              phx-click="close_entry"
              phx-target={@myself}
              class="text-surface-content/60 hover:text-surface-content"
            >
              <.dm_mdi name="close" class="w-5 h-5" />
            </button>
          </div>
          <div class="flex-1 overflow-auto p-4">
            <pre class="text-xs font-mono whitespace-pre-wrap break-all"><%= inspect(@selected_entry.metadata, pretty: true, limit: :infinity) %></pre>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("toggle_logs", _params, socket) do
    send(self(), {:toggle_logs})
    {:noreply, socket}
  end

  @impl true
  def handle_event("select_entry", %{"id" => id}, socket) do
    id = String.to_integer(id)
    entry = Enum.find(socket.assigns.entries, &(&1.id == id))
    {:noreply, assign(socket, :selected_entry, entry)}
  end

  @impl true
  def handle_event("close_entry", _params, socket) do
    {:noreply, assign(socket, :selected_entry, nil)}
  end

  defp category_badge_class(:llm), do: "bg-primary/20 text-primary"
  defp category_badge_class(:tool), do: "bg-secondary/20 text-secondary"
  defp category_badge_class(:permission), do: "bg-warning/20 text-warning"
  defp category_badge_class(_), do: "bg-surface-variant text-surface-content/60"

  defp category_active_class(:llm), do: "bg-primary/20 text-primary"
  defp category_active_class(:tool), do: "bg-secondary/20 text-secondary"
  defp category_active_class(:permission), do: "bg-warning/20 text-warning"
  defp category_active_class(_), do: "bg-surface-variant text-surface-content"

  defp format_ts(ts) do
    ts
    |> DateTime.from_unix!(:millisecond)
    |> Calendar.strftime("%H:%M:%S.%f")
    |> String.slice(0, 12)
  end

  defp summarize(%{category: :llm, event: :request_start, metadata: m}) do
    body = m[:request_body]
    field_count = if is_map(body), do: map_size(body), else: 0
    "→ #{m[:model]} (#{field_count} body fields)"
  end

  defp summarize(%{category: :llm, event: :request_stop, metadata: m}),
    do: "← #{m[:model]} | #{(m[:usage] || %{}) |> Map.get(:output, 0)} output tokens"

  defp summarize(%{category: :tool, event: :call_start, metadata: m}),
    do: "→ #{m[:tool_name]}"

  defp summarize(%{category: :tool, event: :call_stop, metadata: m}),
    do: "← #{m[:tool_name]}"

  defp summarize(%{category: :permission, metadata: m}),
    do: "permission check: #{m[:tool_name]}"

  defp summarize(entry), do: inspect(entry.event)
end
