defmodule Sigma.Web.SessionTerminalComponents do
  @moduledoc false

  use Sigma.Web, :html

  @states ~w(starting running stopping exited failed cleanup_failed unavailable)

  attr(:catalog, :map, required: true)
  attr(:panel_open?, :boolean, default: false)

  def terminal_trigger(assigns) do
    assigns = assign(assigns, :count, catalog_count(assigns.catalog))

    ~H"""
    <span class="sigma-terminal-trigger" title={catalog_title(@catalog)}>
      <.dm_btn
        id="session-terminal-open-btn"
        type="button"
        phx-click="terminal_open"
        phx-hook="WebComponentHook"
        variant="ghost"
        size="sm"
        shape="circle"
        aria-label={catalog_title(@catalog)}
        aria-expanded={to_string(@panel_open?)}
      >
        <.dm_mdi name="console-line" class="h-4 w-4" />
        <span class="sr-only">{catalog_title(@catalog)}</span>
      </.dm_btn>
      <span :if={is_integer(@count) and @count > 0} class="sigma-terminal-count" aria-hidden="true">
        {@count}
      </span>
      <span :if={unavailable?(@catalog)} class="sigma-terminal-unavailable" aria-hidden="true">!</span>
    </span>
    """
  end

  attr(:catalog, :map, required: true)
  attr(:session, :map, required: true)
  attr(:panel_open?, :boolean, default: true)

  def terminal_panel(assigns) do
    assigns =
      assigns
      |> assign(:entries, catalog_entries(assigns.catalog))
      |> assign(:unavailable?, unavailable?(assigns.catalog))
      |> assign(:selected_id, value(assigns.catalog, :selected_id))

    ~H"""
    <section
      id="session-terminal-panel"
      class={if @panel_open?, do: "sigma-terminal-panel", else: "sigma-terminal-panel is-collapsed"}
      phx-hook="SessionTerminals"
      data-terminal-storage-key={storage_key(@session)}
      data-terminal-panel-open={to_string(@panel_open?)}
      data-terminal-repository={value(@session, :repository_id)}
      data-terminal-session={value(@session, :session_id)}
      data-terminal-incarnation={value(@session, :incarnation_id)}
      data-terminal-catalog-revision={value(@catalog, :revision)}
      aria-label="Session terminals"
    >
      <div class="sigma-terminal-toolbar">
        <div class="sigma-terminal-title">
          <.dm_mdi name="console-line" class="h-4 w-4" />
          <span>Terminals</span>
          <span class="sigma-terminal-summary" role="status">{catalog_title(@catalog)}</span>
        </div>
        <div class="sigma-terminal-actions">
          <.terminal_icon_button id="session-terminal-height-btn" label="Adjust terminal height, current automatic" icon="arrow-expand-vertical" action="height" action_value="automatic" />
          <.terminal_icon_button id="session-terminal-maximize-btn" label="Maximize terminal" icon="arrow-expand-all" action="maximize" action_value="restored" pressed="false" />
          <.terminal_icon_button id="session-terminal-collapse-btn" event="terminal_collapse" label="Collapse terminal panel" icon="chevron-down" action="collapse" />
        </div>
      </div>

      <p :if={@unavailable?} class="sigma-terminal-notice is-error" role="status">
        {unavailable_message(@catalog)}
      </p>

      <div :if={not @unavailable?} class="sigma-terminal-tabbar" role="tablist" aria-label="Terminal tabs">
        <button
          :for={entry <- @entries}
          id={tab_id(entry)}
          class={tab_class(entry, @selected_id)}
          type="button"
          role="tab"
          aria-selected={to_string(selected?(entry, @selected_id))}
          aria-controls={panel_id(entry)}
          tabindex={if selected?(entry, @selected_id), do: "0", else: "-1"}
          data-terminal-id={value(entry, :terminal_id)}
          phx-click="terminal_select"
          phx-value-terminal_id={value(entry, :terminal_id)}
        >
          <span class={"sigma-terminal-state is-#{state(entry)}"} aria-hidden="true"></span>
          <span class="sigma-terminal-tab-label">{value(entry, :label, "Terminal")}</span>
          <span :if={value(entry, :unread?) == true} class="sigma-terminal-unread" aria-label="Unread terminal output">new</span>
          <span class="sr-only">{state_label(entry)}. {control_label(entry)}. {exit_label(entry)}</span>
        </button>
        <.terminal_icon_button id="session-terminal-create-btn" event="terminal_create" label="Create terminal" icon="plus" />
      </div>

      <div :if={not @unavailable? and @entries == []} class="sigma-terminal-empty">
        <p>No retained terminals.</p>
        <.dm_btn id="session-terminal-empty-create-btn" type="button" phx-click="terminal_create" phx-hook="WebComponentHook" variant="outline" size="sm">
          <.dm_mdi name="plus" class="h-4 w-4" /> Create terminal
        </.dm_btn>
      </div>

      <section
        :for={entry <- @entries}
        id={panel_id(entry)}
        class="sigma-terminal-run"
        role="tabpanel"
        aria-labelledby={tab_id(entry)}
        hidden={not selected?(entry, @selected_id)}
        data-terminal-id={value(entry, :terminal_id)}
        data-terminal-generation={value(entry, :generation)}
        data-terminal-controller={to_string(value(entry, :controller?) == true)}
        data-terminal-resynced={to_string(value(entry, :resynced?) == true)}
        data-terminal-attachment={value(entry, :attachment_id)}
        data-terminal-control-epoch={value(entry, :control_epoch)}
      >
        <header class="sigma-terminal-run-header">
          <div class="min-w-0">
            <form
              :if={renaming?(entry)}
              id={"terminal-rename-form-#{dom_id(entry)}"}
              class="sigma-terminal-rename-form"
              phx-submit="terminal_rename_submit"
              phx-change="terminal_rename_validate"
            >
              <input type="hidden" name="terminal_id" value={value(entry, :terminal_id)} />
              <.dm_compact_input
                id={"terminal-rename-input-#{dom_id(entry)}"}
                name="label"
                label="Terminal name"
                value={value(entry, :rename_value, value(entry, :label, "Terminal"))}
                maxlength="80"
                data-max-bytes="80"
                autocomplete="off"
                required
                size="xs"
                class="sigma-terminal-rename-field"
              />
              <div class="sigma-terminal-rename-actions">
                <.dm_btn type="submit" variant="primary" size="xs" shape="square" aria-label="Save terminal name" title="Save terminal name">
                  <.dm_mdi name="check" class="h-4 w-4" />
                  <span class="sr-only">Save terminal name</span>
                </.dm_btn>
                <.dm_btn
                  id={"terminal-rename-cancel-#{dom_id(entry)}"}
                  type="button"
                  phx-click="terminal_rename_cancel"
                  phx-value-terminal_id={value(entry, :terminal_id)}
                  phx-hook="WebComponentHook"
                  variant="ghost"
                  size="xs"
                  shape="square"
                  aria-label="Cancel terminal rename"
                  title="Cancel terminal rename"
                >
                  <.dm_mdi name="close" class="h-4 w-4" />
                  <span class="sr-only">Cancel terminal rename</span>
                </.dm_btn>
              </div>
              <p :if={value(entry, :rename_error)} class="sigma-terminal-rename-error" role="alert">
                {value(entry, :rename_error)}
              </p>
            </form>
            <div :if={not renaming?(entry)} class="sigma-terminal-run-identity">
              <strong>{value(entry, :label, "Terminal")}</strong>
              <span class="sigma-terminal-meta">{state_label(entry)} | {control_label(entry)} | {exit_label(entry)}</span>
              <span :if={value(entry, :startup_directory)} class="sigma-terminal-path" title={value(entry, :startup_directory)}>
                started in {value(entry, :startup_directory)}
              </span>
            </div>
          </div>
          <div class="sigma-terminal-run-actions">
            <.terminal_icon_button :if={not renaming?(entry)} id={"terminal-rename-#{value(entry, :terminal_id)}"} event="terminal_rename" label={"Rename #{value(entry, :label, "terminal")}"} icon="pencil" value={value(entry, :terminal_id)} />
            <.terminal_icon_button :if={value(entry, :controller?) != true} id={"terminal-control-#{value(entry, :terminal_id)}"} event="terminal_take_control" label={"Take control of #{value(entry, :label, "terminal")}"} icon="keyboard" value={value(entry, :terminal_id)} />
            <.terminal_icon_button :if={restartable?(entry)} id={"terminal-restart-#{value(entry, :terminal_id)}"} event="terminal_restart" label={"Restart #{value(entry, :label, "terminal")}; prior screen will be cleared"} icon="restart" value={value(entry, :terminal_id)} confirm="Restart this terminal? The prior run's visible screen will be cleared and commands will not be replayed." />
            <.terminal_icon_button :if={state(entry) == "cleanup_failed"} id={"terminal-cleanup-retry-#{value(entry, :terminal_id)}"} event="terminal_cleanup_retry" label={"Retry cleanup for #{value(entry, :label, "terminal")}"} icon="refresh" value={value(entry, :terminal_id)} />
            <.terminal_icon_button id={"terminal-close-#{value(entry, :terminal_id)}"} event="terminal_close" label={"Close #{value(entry, :label, "terminal")}"} icon="close" value={value(entry, :terminal_id)} confirm={close_confirmation(entry)} />
          </div>
        </header>
        <p :if={state(entry) == "cleanup_failed"} class="sigma-terminal-notice is-error" role="status">Cleanup needs confirmation before this terminal can be removed.</p>
        <p :if={restartable?(entry)} class="sigma-terminal-notice" role="status">Restart starts a new run and clears this terminal's visible screen.</p>
        <div id={"terminal-host-#{value(entry, :terminal_id)}-#{value(entry, :generation)}"} class="web-shell-terminal-host" data-terminal-host="true" phx-update="ignore" aria-label={"Terminal screen for #{value(entry, :label, "terminal")}"} />
      </section>
    </section>
    """
  end

  attr(:id, :string, required: true)
  attr(:event, :string, default: nil)
  attr(:action, :string, default: nil)
  attr(:action_value, :string, default: nil)
  attr(:pressed, :string, default: nil)
  attr(:label, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:value, :any, default: nil)
  attr(:confirm, :string, default: "")

  defp terminal_icon_button(assigns) do
    ~H"""
    <.dm_btn id={@id} type="button" phx-click={@event} phx-value-terminal_id={@value} phx-hook="WebComponentHook" data-terminal-action={@action} data-terminal-action-value={@action_value} variant="ghost" size="xs" shape="square" aria-label={@label} aria-pressed={@pressed} title={@label} confirm={@confirm} confirm_title="Confirm terminal action">
      <.dm_mdi name={@icon} class="h-4 w-4" />
      <span class="sr-only" data-terminal-action-label={@action != nil}>{@label}</span>
    </.dm_btn>
    """
  end

  defp catalog_entries(%{entries: entries}) when is_list(entries), do: entries
  defp catalog_entries(_), do: []
  defp catalog_count(%{retained_count: count}) when is_integer(count), do: count
  defp catalog_count(%{total_retained: count}) when is_integer(count), do: count
  defp catalog_count(%{entries: entries}) when is_list(entries), do: length(entries)
  defp catalog_count(_), do: nil
  defp catalog_title(%{status: :disabled}), do: "Terminals disabled"
  defp catalog_title(%{status: :backend_missing}), do: "Terminal backend missing"

  defp catalog_title(%{status: :unsupported_platform}),
    do: "Terminals unsupported on this platform"

  defp catalog_title(%{status: status}) when status != :available,
    do: "Terminal catalog unavailable"

  defp catalog_title(catalog) do
    count = catalog_count(catalog) || "unknown"

    counts =
      value(
        catalog,
        :state_counts,
        value(catalog, :lifecycle_counts, lifecycle_counts(catalog_entries(catalog)))
      )

    breakdown =
      @states
      |> Enum.reject(&(&1 == "unavailable"))
      |> Enum.flat_map(fn state ->
        case value(counts, state_atom(state), 0) do
          value when is_integer(value) and value > 0 ->
            ["#{value} #{String.replace(state, "_", " ")}"]

          _ ->
            []
        end
      end)

    case breakdown do
      [] -> "#{count} retained terminals"
      values -> "#{count} retained terminals: #{Enum.join(values, ", ")}"
    end
  end

  defp lifecycle_counts(entries),
    do: Enum.frequencies_by(entries, &(state(&1) |> state_atom()))

  defp state_atom("starting"), do: :starting
  defp state_atom("running"), do: :running
  defp state_atom("stopping"), do: :stopping
  defp state_atom("exited"), do: :exited
  defp state_atom("failed"), do: :failed
  defp state_atom("cleanup_failed"), do: :cleanup_failed
  defp state_atom("unavailable"), do: :unavailable

  defp unavailable?(catalog), do: value(catalog, :status, :available) != :available

  defp unavailable_message(%{status: :disabled}),
    do: "Terminals are disabled by the deployment configuration."

  defp unavailable_message(%{status: :backend_missing}),
    do: "The packaged terminal backend is missing or is not executable."

  defp unavailable_message(%{status: :unsupported_platform}),
    do: "Terminals are not supported on this platform."

  defp unavailable_message(_catalog),
    do:
      "Terminal service is unavailable. Existing terminal state cannot be counted or controlled here."

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp state(entry) do
    state = entry |> value(:state, "unavailable") |> to_string()
    if state in @states, do: state, else: "unavailable"
  end

  defp selected?(entry, selected_id), do: value(entry, :terminal_id) == selected_id
  defp renaming?(entry), do: value(entry, :renaming?) == true
  defp tab_id(entry), do: "terminal-tab-#{dom_id(entry)}"
  defp panel_id(entry), do: "terminal-panel-#{dom_id(entry)}"

  defp tab_class(entry, selected_id),
    do: [
      "sigma-terminal-tab",
      if(selected?(entry, selected_id), do: "is-selected"),
      if(value(entry, :unread?) == true, do: "has-unread")
    ]

  defp state_label(entry), do: state(entry) |> String.replace("_", " ")

  defp control_label(entry),
    do: if(value(entry, :controller?) == true, do: "You control input", else: "Read only")

  defp exit_label(entry),
    do:
      if(is_integer(value(entry, :exit_status)),
        do: "exit #{value(entry, :exit_status)}",
        else: "no exit status"
      )

  defp restartable?(entry),
    do:
      state(entry) in ["exited", "failed"] and
        to_string(value(entry, :resource_state)) == "released"

  defp close_confirmation(entry),
    do:
      if(state(entry) in ["starting", "running", "stopping"],
        do: "Close this live terminal? Its running command will be terminated.",
        else: ""
      )

  defp storage_key(session),
    do:
      Enum.map_join(
        ~w(repository_id session_id incarnation_id)a,
        ".",
        &(session |> value(&1, "unknown") |> to_string() |> Base.url_encode64(padding: false))
      )

  defp dom_id(entry),
    do:
      entry |> value(:terminal_id, "unknown") |> to_string() |> Base.url_encode64(padding: false)
end
