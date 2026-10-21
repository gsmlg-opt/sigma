defmodule Sigma.Web.HooksSettingsComponent do
  use Sigma.Web, :live_component

  alias Sigma.Session.ConfigManager
  alias Sigma.Web.{HooksConfig, HooksHelp}

  @impl true
  def update(assigns, socket) do
    previous_path = socket.assigns[:path]
    socket = assign(socket, assigns)

    socket =
      if previous_path != assigns.path do
        socket
        |> assign(
          error: nil,
          notice: nil,
          editing: nil,
          expanded_events: MapSet.new(),
          expanded_help: MapSet.new(),
          advanced_open: false
        )
        |> load_json(ConfigManager.get_hooks_json(assigns.path))
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :events,
        Enum.map(HooksConfig.events(), fn event ->
          Map.put(
            event,
            :rows,
            if(assigns.data, do: HooksConfig.rows(assigns.data, event.name), else: [])
          )
        end)
      )

    ~H"""
    <section id={@id} class="space-y-5">
      <p class="text-sm text-on-surface-variant">
        All hook events are listed below. Expand an event to configure commands and view input/output help.
        Events without commands stay inactive.
      </p>
      <code class="block break-all text-[11px] font-mono text-on-surface-variant bg-surface-container rounded-lg px-3 py-2">
        {@path}
      </code>

      <p :if={@error} role="alert" class="rounded-xl bg-error/10 text-error p-3 text-sm">{@error}</p>
      <p :if={@notice} role="status" class="text-success text-sm">{@notice}</p>
      <p :if={@config_error} role="status" class="text-on-surface-variant text-sm">{@config_error}</p>

      <div id={@id <> "-events"} class="space-y-3">
        <details
          :for={event <- @events}
          id={@id <> "-event-" <> event.name}
          data-hook-event={event.name}
          open={MapSet.member?(@expanded_events, event.name)}
          class="rounded-xl border border-outline-variant bg-surface-container-low p-4"
        >
          <summary phx-click="toggle_event" phx-value-event={event.name} phx-target={@myself} class="cursor-pointer text-on-surface">
            <span class="inline-flex flex-wrap items-center gap-3">
              <span class="font-mono font-bold">{event.name}</span>
              <.dm_badge :if={!event.available?} variant="warning" size="sm">Not available</.dm_badge>
              <.dm_badge :if={event.available?} variant={if(event.rows == [], do: "ghost", else: "primary")} size="sm">
                {cond do
                  @data == nil -> "Advanced JSON"
                  event.rows == [] -> "Not configured"
                  true -> "#{length(event.rows)} configured"
                end}
              </.dm_badge>
            </span>
            <span class="mt-1 block text-sm text-on-surface-variant">{event.description}</span>
          </summary>

          <div class="mt-4 space-y-4">
            <p :if={event.limitation} class="text-sm text-on-surface-variant">{event.limitation}</p>
            <.hook_help
              id={@id <> "-help-" <> event.name}
              event={event.name}
              help={HooksHelp.for_event(event.event)}
              open={MapSet.member?(@expanded_help, event.name)}
              target={@myself}
            />
            <div
              :for={row <- event.rows}
              class="space-y-2 rounded-lg bg-surface-container p-3"
              data-hook-command={command_value(row.handler)}
            >
              <pre class="whitespace-pre-wrap break-all text-sm font-mono text-on-surface">{handler_label(row.handler)}</pre>
              <p class="text-xs text-on-surface-variant">
                Matcher: {if(row.matcher == "", do: "All", else: row.matcher)} · Timeout: {timeout(row.handler, event.default_timeout)}s
                <span :if={row.handler["async"] == true && event.name != "SessionEnd"}> · Asynchronous</span>
              </p>
              <div :if={command?(row.handler) && event.available? && @editing == nil} class="flex gap-2">
                <.dm_btn
                  id={row_id(@id, event.name, row) <> "-edit"}
                  phx-click="edit_command"
                  phx-value-event={event.name}
                  phx-value-group={row.group_index}
                  phx-value-handler={row.handler_index}
                  phx-target={@myself}
                  phx-hook="WebComponentHook"
                  variant="outline"
                  size="sm"
                >Edit</.dm_btn>
                <.dm_btn
                  id={row_id(@id, event.name, row) <> "-remove"}
                  phx-click="remove_command"
                  phx-value-event={event.name}
                  phx-value-group={row.group_index}
                  phx-value-handler={row.handler_index}
                  phx-target={@myself}
                  phx-hook="WebComponentHook"
                  variant="error"
                  size="sm"
                >Remove</.dm_btn>
              </div>
              <p :if={!command?(row.handler)} class="text-xs text-on-surface-variant">
                Configure this handler in Advanced JSON.
              </p>
            </div>

            <form
              :if={@editing && @editing.event == event.name}
              id={@id <> "-command-form"}
              phx-submit="save_command"
              phx-change="change_command"
              phx-target={@myself}
              class="space-y-4 rounded-lg border border-outline-variant p-4"
            >
              <h3 class="font-bold">{if(@editing.location == :new, do: "Add command", else: "Edit command")}</h3>
              <.dm_input
                id={@id <> "-command"}
                name="command[command]"
                value={@editing.attrs["command"]}
                label="Shell command"
                placeholder="Run a command when this event fires"
                required
              />
              <.dm_input
                :if={event.matcher}
                id={@id <> "-matcher"}
                name="command[matcher]"
                value={@editing.attrs["matcher"]}
                label="Matcher (applies to this group)"
                placeholder={event.matcher}
              />
              <.dm_input
                id={@id <> "-timeout"}
                name="command[timeout]"
                value={@editing.attrs["timeout"]}
                label="Timeout (seconds)"
                type="number"
                min="1"
                max={event.max_timeout}
                placeholder={to_string(event.default_timeout)}
              />
              <p :if={event.max_timeout} class="text-xs text-on-surface-variant">
                Maximum {event.max_timeout} seconds.
              </p>
              <.dm_input
                id={@id <> "-status-message"}
                name="command[statusMessage]"
                value={@editing.attrs["statusMessage"]}
                label="Status message"
              />
              <.dm_checkbox
                :if={event.name != "SessionEnd"}
                id={@id <> "-async"}
                name="command[async]"
                checked={@editing.attrs["async"] in [true, "true"]}
                label="Run asynchronously"
                helper="Continue without waiting for this command. Its output cannot control execution."
              />
              <div class="flex flex-wrap gap-2">
                <.dm_btn id={@id <> "-command-save"} native_submit variant="primary">Save command</.dm_btn>
                <.dm_btn
                  id={@id <> "-command-cancel"}
                  phx-click="cancel_command"
                  phx-target={@myself}
                  phx-hook="WebComponentHook"
                  variant="ghost"
                >Cancel</.dm_btn>
              </div>
            </form>

            <.dm_btn
              :if={event.available? && @data && @editing == nil}
              id={@id <> "-add-" <> event.name}
              phx-click="add_command"
              phx-value-event={event.name}
              phx-target={@myself}
              phx-hook="WebComponentHook"
              variant="outline"
              size="sm"
            >
              <:prefix><.dm_mdi name="plus" class="w-4 h-4" /></:prefix>
              Add command
            </.dm_btn>
          </div>
        </details>
      </div>

      <details id={@id <> "-advanced"} open={@advanced_open} class="rounded-xl border border-outline-variant p-4">
        <summary phx-click="toggle_advanced" phx-target={@myself} class="cursor-pointer font-bold text-on-surface">Advanced JSON</summary>
        <form id={@form_id} phx-submit="save_hooks" phx-change="change_hooks" phx-target={@myself} class="mt-4 space-y-4">
          <label for={@editor_id} class="block text-sm text-on-surface-variant">Edit the complete hooks.json configuration.</label>
          <textarea
            id={@editor_id}
            name="hooks_json"
            class="w-full font-mono text-sm bg-surface-container-high rounded-xl p-4 min-h-96 text-on-surface resize-y border border-outline-variant focus:outline-none focus:border-primary"
            spellcheck="false"
          >{@json}</textarea>
          <div class="flex flex-wrap justify-between gap-2">
            <.dm_btn id={@id <> "-format"} phx-click="format_hooks" phx-target={@myself} phx-hook="WebComponentHook" variant="outline" size="sm">Format JSON</.dm_btn>
            <.dm_btn id={@id <> "-save"} native_submit variant="primary">Save hooks.json</.dm_btn>
          </div>
        </form>
      </details>
    </section>
    """
  end

  @impl true
  def handle_event("toggle_event", %{"event" => event}, socket) do
    events = socket.assigns.expanded_events

    events =
      if MapSet.member?(events, event),
        do: MapSet.delete(events, event),
        else: MapSet.put(events, event)

    {:noreply, assign(socket, :expanded_events, events)}
  end

  def handle_event("toggle_advanced", _params, socket),
    do: {:noreply, assign(socket, :advanced_open, !socket.assigns.advanced_open)}

  def handle_event("toggle_help", %{"event" => event}, socket) do
    help = socket.assigns.expanded_help

    help =
      if MapSet.member?(help, event),
        do: MapSet.delete(help, event),
        else: MapSet.put(help, event)

    {:noreply, assign(socket, :expanded_help, help)}
  end

  def handle_event("add_command", %{"event" => name}, socket) do
    if available?(name) && socket.assigns.data do
      {:noreply,
       assign(socket,
         editing: %{
           event: name,
           location: :new,
           attrs: %{"command" => "", "matcher" => "", "timeout" => ""}
         },
         error: nil,
         notice: nil,
         expanded_events: MapSet.put(socket.assigns.expanded_events, name)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("edit_command", params, socket) do
    with true <- available?(params["event"]),
         {:ok, location} <- location(params),
         row when not is_nil(row) <- find_row(socket, params["event"], location),
         true <- command?(row.handler) do
      attrs = %{
        "command" => command_value(row.handler) || "",
        "matcher" => row.matcher,
        "timeout" => timeout(row.handler, ""),
        "statusMessage" => row.handler["statusMessage"] || "",
        "async" => row.handler["async"] == true
      }

      {:noreply,
       assign(socket,
         editing: %{event: params["event"], location: location, attrs: attrs},
         error: nil,
         notice: nil,
         expanded_events: MapSet.put(socket.assigns.expanded_events, params["event"])
       )}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("change_command", %{"command" => attrs}, socket) do
    editing = %{socket.assigns.editing | attrs: Map.merge(socket.assigns.editing.attrs, attrs)}
    {:noreply, assign(socket, editing: editing, error: nil)}
  end

  def handle_event("cancel_command", _params, socket),
    do: {:noreply, assign(socket, editing: nil, error: nil)}

  def handle_event("save_command", %{"command" => attrs}, socket) do
    editing = %{socket.assigns.editing | attrs: Map.merge(socket.assigns.editing.attrs, attrs)}
    socket = assign(socket, :editing, editing)

    case HooksConfig.put_command(
           socket.assigns.json,
           editing.event,
           editing.location,
           editing.attrs
         ) do
      {:ok, json} -> {:noreply, save_json(socket, json)}
      {:error, message} -> {:noreply, assign(socket, :error, message)}
    end
  end

  def handle_event("remove_command", params, socket) do
    with true <- available?(params["event"]),
         {:ok, location} <- location(params),
         {:ok, json} <- HooksConfig.remove_command(socket.assigns.json, params["event"], location) do
      {:noreply, save_json(socket, json)}
    else
      {:error, message} -> {:noreply, assign(socket, :error, message)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("change_hooks", %{"hooks_json" => json}, socket) do
    {:noreply, socket |> load_json(json) |> assign(error: nil, notice: nil, editing: nil)}
  end

  def handle_event("format_hooks", _params, socket) do
    case Jason.decode(socket.assigns.json) do
      {:ok, data} ->
        {:noreply, socket |> load_json(Jason.encode!(data, pretty: true)) |> assign(error: nil)}

      {:error, _} ->
        {:noreply, assign(socket, :error, "Cannot format invalid JSON.")}
    end
  end

  def handle_event("save_hooks", %{"hooks_json" => json}, socket),
    do: {:noreply, save_json(socket, json)}

  defp save_json(socket, json) do
    case ConfigManager.save_hooks_json(socket.assigns.path, json) do
      :ok ->
        socket |> load_json(json) |> assign(error: nil, notice: "hooks.json saved", editing: nil)

      {:error, message} ->
        socket |> load_json(json) |> assign(error: message, notice: nil)
    end
  end

  defp load_json(socket, json) do
    case HooksConfig.decode(json) do
      {:ok, data} ->
        assign(socket, json: json, data: data, config_error: nil)

      {:error, message} ->
        assign(socket, json: json, data: nil, config_error: message, advanced_open: true)
    end
  end

  defp available?(name), do: Enum.any?(HooksConfig.events(), &(&1.name == name && &1.available?))

  attr(:id, :string, required: true)
  attr(:event, :string, required: true)
  attr(:help, :map, required: true)
  attr(:open, :boolean, required: true)
  attr(:target, :any, required: true)

  defp hook_help(assigns) do
    ~H"""
    <details id={@id} data-hook-help={@event} open={@open} class="rounded-lg bg-surface-container text-on-surface p-3">
      <summary
        phx-click="toggle_help"
        phx-value-event={@event}
        phx-target={@target}
        aria-label={@event <> " input and output help"}
        class="cursor-pointer text-sm font-semibold"
      >
        <span class="inline-flex items-center gap-2">
          <.dm_mdi name="help-circle-outline" class="w-4 h-4" />
          Input & output help
        </span>
      </summary>
      <div :if={@open} class="mt-4 space-y-5 text-sm">
        <section aria-labelledby={@id <> "-input-title"} class="space-y-3">
          <h3 id={@id <> "-input-title"} class="font-semibold">Input · stdin</h3>
          <p class="text-on-surface-variant">
            The command receives one JSON object on stdin, followed by EOF. These fields are supplied by the event.
            Fields marked optional may be absent; null means no value is available.
          </p>
          <div class="overflow-x-auto">
            <.dm_table id={@id <> "-fields"} data={@help.input_fields} compact class="w-full min-w-0">
              <:col :let={field} label="Field"><code>{field.name}</code></:col>
              <:col :let={field} label="Type" class="whitespace-normal"><span class="text-on-surface-variant">{field.type}</span></:col>
              <:col :let={field} label="Meaning" class="whitespace-normal">{field.description}</:col>
            </.dm_table>
          </div>
          <p class="font-medium">Example input</p>
          <pre data-hook-input-example class="overflow-x-auto rounded-lg bg-surface-container-high text-on-surface p-3 text-xs"><code>{Jason.encode!(@help.input_example, pretty: true)}</code></pre>
        </section>
        <section aria-labelledby={@id <> "-output-title"} class="space-y-3">
          <h3 id={@id <> "-output-title"} class="font-semibold">Output · stdout</h3>
          <ul class="list-disc space-y-2 pl-5 text-on-surface-variant">
            <li :for={rule <- @help.output_rules}>{rule}</li>
          </ul>
          <div :for={example <- @help.output_examples} class="space-y-2">
            <p class="font-medium">{example.label}</p>
            <pre data-hook-output-example class="overflow-x-auto rounded-lg bg-surface-container-high text-on-surface p-3 text-xs"><code>{output_example(example.output)}</code></pre>
          </div>
        </section>
        <section aria-labelledby={@id <> "-exit-title"} class="space-y-3">
          <h3 id={@id <> "-exit-title"} class="font-semibold">Exit codes & stderr</h3>
          <p class="text-on-surface-variant">Exit status takes precedence over stdout. A failed command cannot grant permission through its JSON output.</p>
          <dl class="space-y-2">
            <div :for={status <- @help.exit_codes} class="flex gap-3">
              <dt class="shrink-0 font-mono">{status.code}</dt>
              <dd class="text-on-surface-variant">{status.description}</dd>
            </div>
          </dl>
          <p class="text-on-surface-variant">{@help.async_note}</p>
        </section>
      </div>
    </details>
    """
  end

  defp output_example(output) when is_binary(output), do: output
  defp output_example(output), do: Jason.encode!(output, pretty: true)

  defp location(%{"group" => group, "handler" => handler}) do
    with {group, ""} <- Integer.parse(group),
         {handler, ""} <- Integer.parse(handler),
         true <- group >= 0 && handler >= 0 do
      {:ok, {group, handler}}
    else
      _ -> {:error, "Command could not be found."}
    end
  end

  defp find_row(%{assigns: %{data: nil}}, _, _), do: nil

  defp find_row(socket, event, {group, handler}),
    do:
      Enum.find(
        HooksConfig.rows(socket.assigns.data, event),
        &(&1.group_index == group && &1.handler_index == handler)
      )

  defp row_id(id, event, row), do: "#{id}-#{event}-#{row.group_index}-#{row.handler_index}"

  defp command?(handler),
    do: Map.get(handler, "type", "command") == "command" && !Map.has_key?(handler, "url")

  defp command_value(handler) do
    case handler["command"] || handler["cmd"] do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp handler_label(handler), do: command_value(handler) || Jason.encode!(handler)

  defp timeout(handler, default) do
    case handler["timeout"] || handler["timeoutSec"] || handler["timeout_sec"] do
      value when is_number(value) or is_binary(value) -> value
      _ -> default
    end
  end
end
