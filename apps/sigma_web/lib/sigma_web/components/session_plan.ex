defmodule Sigma.Web.SessionPlan do
  use Sigma.Web, :html

  @statuses %{
    "pending" => {"Pending", "secondary"},
    "in_progress" => {"In progress", "primary"},
    "completed" => {"Completed", "success"}
  }

  attr(:id, :string, default: "session-plan")
  attr(:snapshot, :map, default: nil)

  def plan(assigns) do
    snapshot = assigns.snapshot
    steps = if snapshot, do: snapshot["plan"], else: []

    assigns =
      assigns
      |> assign(:steps, steps)
      |> assign(:completed, Enum.count(steps, &(&1["status"] == "completed")))
      |> assign(:statuses, @statuses)

    ~H"""
    <section
      :if={@snapshot}
      id={@id}
      aria-label="Session plan"
      class="border-t border-outline-variant pt-3 text-xs text-on-surface"
    >
      <div class="flex items-center justify-between gap-3">
        <h2 class="font-semibold">Plan</h2>
        <span :if={@steps != []} class="text-on-surface-variant">
          {@completed} of {length(@steps)} completed
        </span>
      </div>
      <p :if={@snapshot["explanation"]} class="mt-2 whitespace-pre-wrap break-words text-on-surface-variant">
        {@snapshot["explanation"]}
      </p>
      <p :if={@steps == []} class="mt-2 text-on-surface-variant">No steps recorded.</p>
      <ol :if={@steps != []} class="mt-3 space-y-2">
        <li
          :for={step <- @steps}
          data-status={step["status"]}
          aria-current={if step["status"] == "in_progress", do: "step"}
          class="flex items-start justify-between gap-3"
        >
          <span class="min-w-0 whitespace-pre-wrap break-words">{step["step"]}</span>
          <.dm_badge variant={elem(@statuses[step["status"]], 1)} size="sm" soft>
            {elem(@statuses[step["status"]], 0)}
          </.dm_badge>
        </li>
      </ol>
    </section>
    """
  end
end
