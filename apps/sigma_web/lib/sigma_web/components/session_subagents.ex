defmodule Sigma.Web.SessionSubagents do
  @moduledoc "Subagent roster display; consumes an authoritative, display-safe snapshot."

  use Sigma.Web, :html

  alias Phoenix.LiveView.JS

  @statuses %{
    pending_init: {"Pending initialization", "info"},
    running: {"Running", "primary"},
    cancelling: {"Cancelling", "warning"},
    completed: {"Completed", "success"},
    errored: {"Errored", "error"},
    interrupted: {"Interrupted", "warning"},
    shutdown: {"Shutdown", "neutral"},
    unknown_outcome: {"Unknown outcome", "warning"}
  }
  @activities %{
    waiting_model: "Waiting for model",
    waiting_tool: "Waiting for tool",
    waiting_approval: "Waiting for approval",
    waiting_agent: "Waiting for agent",
    model: "Model",
    tool: "Tool",
    approval: "Approval",
    agent: "Agent"
  }
  @counts [
    created: "Created",
    executing: "Executing",
    pending: "Pending",
    stopped: "Stopped",
    unknown: "Needs reconciliation"
  ]

  attr(:id, :string, required: true)
  attr(:snapshot, :map, required: true)
  attr(:available, :boolean, default: false)
  attr(:filter, :string, default: "all")

  def subagents(assigns) do
    agents = if assigns.available, do: assigns.snapshot.agents, else: []

    matching_ids =
      agents |> Enum.filter(&matches_filter?(&1, assigns.filter)) |> MapSet.new(& &1.agent_id)

    by_id = Map.new(agents, &{&1.agent_id, &1})
    visible_ids = Enum.reduce(matching_ids, matching_ids, &include_ancestors(&1, by_id, &2))
    agents = Enum.filter(agents, &MapSet.member?(visible_ids, &1.agent_id))
    ids = MapSet.new(agents, & &1.agent_id)

    assigns =
      assigns
      |> assign(:roots, Enum.reject(agents, &MapSet.member?(ids, &1.parent_agent_id)))
      |> assign(:children, Enum.group_by(agents, & &1.parent_agent_id))
      |> assign(:matching_ids, matching_ids)
      |> assign(:count_labels, @counts)

    ~H"""
    <details
      id={@id}
      data-revision={if @available, do: @snapshot.revision}
      phx-mounted={JS.ignore_attributes("open")}
      tabindex="-1"
      class="border-t border-outline-variant pt-3 text-xs text-on-surface"
    >
      <summary class="cursor-pointer rounded font-semibold focus-visible:outline">
        <%= if @available do %>
          Subagents · {@snapshot.counts.created} created · {@snapshot.counts.executing} executing
        <% else %>
          Subagents unavailable
        <% end %>
      </summary>
      <%= if @available do %>
        <dl class="mt-2 grid grid-cols-2 gap-x-3 gap-y-1 text-on-surface-variant">
          <div :for={{key, label} <- @count_labels} class="flex justify-between gap-2">
            <dt>{label}</dt>
            <dd data-subagent-count={key} class="font-mono text-on-surface">
              {@snapshot.counts[key]}
            </dd>
          </div>
        </dl>
        <div class="mt-3 flex flex-wrap gap-1" role="group" aria-label="Filter subagents">
          <.dm_btn
            :for={{value, label} <- [{"all", "All"}, {"running", "Running"}, {"stopped", "Stopped"}, {"unknown", "Needs reconciliation"}]}
            id={@id <> "-filter-" <> value}
            type="button"
            phx-click="filter_subagents"
            phx-value-filter={value}
            phx-hook="WebComponentHook"
            aria-pressed={to_string(@filter == value)}
            variant="ghost"
            size="xs"
          >{label}</.dm_btn>
        </div>
        <p :if={@snapshot.agents != [] and @roots == []} class="mt-2 text-on-surface-variant">No matching subagents.</p>
        <p :if={@snapshot.agents == []} class="mt-2 text-on-surface-variant">None created.</p>
        <ul :if={@roots != []} aria-label="Subagent tree" class="mt-3 space-y-3">
          <.subagent_row :for={agent <- @roots} prefix={@id} agent={agent} children={@children} matching_ids={@matching_ids} />
        </ul>
      <% else %>
        <p class="mt-2 text-on-surface-variant">Subagent observation is unavailable.</p>
      <% end %>
    </details>
    """
  end

  attr(:prefix, :string, required: true)
  attr(:agent, :map, required: true)
  attr(:children, :map, required: true)
  attr(:matching_ids, :any, required: true)

  defp subagent_row(assigns) do
    {status, variant} = Map.fetch!(@statuses, assigns.agent.status)

    assigns =
      assigns
      |> assign(:status_label, status)
      |> assign(:status_variant, variant)
      |> assign(:activity_label, Map.get(@activities, assigns.agent[:activity], "Unknown"))
      |> assign(:nested, Map.get(assigns.children, assigns.agent.agent_id, []))
      |> assign(:times, observed_times(assigns.agent))

    ~H"""
    <li
      id={@prefix <> "-agent-" <> Base.url_encode64(@agent.agent_id, padding: false)}
      data-agent-id={@agent.agent_id}
      data-filter-context={to_string(not MapSet.member?(@matching_ids, @agent.agent_id))}
      class="min-w-0"
    >
      <div class="flex flex-wrap items-center gap-2">
        <span class="break-all font-mono">{@agent.agent_path}</span>
        <.dm_badge variant={@status_variant} size="sm" soft>{@status_label}</.dm_badge>
      </div>
      <p :if={not MapSet.member?(@matching_ids, @agent.agent_id)} class="mt-1 text-on-surface-variant">Ancestor context</p>
      <p class="mt-1 whitespace-pre-wrap break-words">{@agent[:task] || "Task not recorded"}</p>
      <p :if={@agent.status == :unknown_outcome} class="mt-1 text-on-surface-variant">
        Needs reconciliation; execution outcome is unconfirmed.
      </p>
      <p class="mt-1 text-on-surface-variant">
        Observed activity: {@activity_label}
      </p>
      <p class="mt-1 break-words text-on-surface-variant">
        {@agent[:agent_type] || "Unknown type"} · {@agent[:model] || "Unknown model"} · Depth {@agent.depth}
      </p>
      <dl :if={@times != []} class="mt-1 grid gap-1 text-on-surface-variant">
        <div :for={{label, datetime} <- @times}>
          <dt class="inline">{label}: </dt>
          <dd class="inline"><time datetime={datetime}>{datetime || "Unavailable"}</time></dd>
        </div>
      </dl>
      <p :if={@agent[:reason]} class="mt-1 whitespace-pre-wrap break-words text-on-surface-variant">
        Reason: {@agent.reason}
      </p>
      <ul
        :if={@nested != []}
        aria-label={"Children of " <> @agent.agent_path}
        class="mt-3 space-y-3 border-l border-outline-variant pl-3"
      >
        <.subagent_row :for={agent <- @nested} prefix={@prefix} agent={agent} children={@children} matching_ids={@matching_ids} />
      </ul>
    </li>
    """
  end

  defp matches_filter?(_agent, "all"), do: true

  defp matches_filter?(agent, "running"),
    do: agent.status in [:pending_init, :running, :cancelling]

  defp matches_filter?(agent, "stopped"),
    do: agent.status in [:completed, :errored, :interrupted, :shutdown]

  defp matches_filter?(agent, "unknown"), do: agent.status == :unknown_outcome

  defp include_ancestors(id, by_id, ids) do
    case by_id[id] do
      %{parent_agent_id: parent} when is_map_key(by_id, parent) ->
        if MapSet.member?(ids, parent),
          do: ids,
          else: include_ancestors(parent, by_id, MapSet.put(ids, parent))

      _ ->
        ids
    end
  end

  defp observed_times(agent) do
    for {field, label} <- [created_at: "Created", started_at: "Started", finished_at: "Finished"],
        timestamp = agent[field],
        not is_nil(timestamp) do
      datetime =
        case DateTime.from_unix(timestamp, :millisecond) do
          {:ok, datetime} -> DateTime.to_iso8601(datetime)
          {:error, _} -> nil
        end

      {label, datetime}
    end
  end
end
