defmodule Sigma.Web.SessionSubagentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Sigma.Web.SessionSubagents

  test "unavailable is explicit and does not present an authoritative zero" do
    html = render_component(&SessionSubagents.subagents/1, %{id: "subagents", snapshot: empty()})
    tree = Floki.parse_fragment!(html)

    assert Floki.text(tree) =~ "Subagents unavailable"
    refute Floki.text(tree) =~ "None created"
    assert Floki.find(tree, "[data-subagent-count]") == []
  end

  test "available empty roster has a discoverable native keyboard disclosure" do
    tree = render_roster(empty())

    assert Floki.text(tree) =~ "None created"
    assert [_] = Floki.find(tree, "details#subagents > summary")
    assert Floki.find(tree, "summary") |> Floki.text() =~ "Subagents"
    assert count(tree, "created") == "0"
    assert length(Floki.find(tree, "[phx-click=filter_subagents]")) == 4
    assert Floki.find(tree, "a, [phx-click=spawn_agent]") == []
  end

  test "renders authoritative counts and nested mixed states without estimating from rows" do
    parent = agent("parent", :running, %{activity: :waiting_approval})
    child = agent("child", :pending_init, %{parent_agent_id: "parent", depth: 2})
    cancelling = agent("cancel", :cancelling)

    tree =
      render_roster(%{
        revision: 24,
        agents: [child, parent, cancelling],
        counts: %{created: 11, executing: 7, pending: 2, stopped: 1, unknown: 1}
      })

    assert count(tree, "created") == "11"
    assert count(tree, "executing") == "7"
    assert count(tree, "pending") == "2"
    assert count(tree, "stopped") == "1"
    assert count(tree, "unknown") == "1"
    assert Floki.attribute(tree, "data-revision") == ["24"]
    assert [_] = Floki.find(tree, ~s([data-agent-id="parent"] > ul [data-agent-id="child"]))
    assert Floki.text(tree) =~ "Running"
    assert Floki.text(tree) =~ "Pending initialization"
    assert Floki.text(tree) =~ "Cancelling"
    assert Floki.text(tree) =~ "Observed activity: Waiting for approval"
    assert Floki.text(tree) =~ "Depth 2"
    assert Floki.text(tree) =~ "worker"
    assert Floki.text(tree) =~ "test-model"
    assert Floki.text(tree) =~ "/root/child"
  end

  test "retains every terminal row and distinguishes an unknown outcome" do
    states = [:completed, :errored, :interrupted, :shutdown, :unknown_outcome]
    agents = Enum.map(states, &agent(Atom.to_string(&1), &1))
    tree = render_roster(%{empty() | agents: agents})

    assert length(Floki.find(tree, "[data-agent-id]")) == 5

    for label <- ["Completed", "Errored", "Interrupted", "Shutdown", "Unknown outcome"] do
      assert Floki.text(tree) =~ label
    end

    assert Floki.find(tree, ~s([data-agent-id="unknown_outcome"])) |> Floki.text() =~
             "Needs reconciliation"

    refute Floki.find(tree, ~s([data-agent-id="completed"])) |> Floki.text() =~
             "Needs reconciliation"
  end

  test "escapes task and reason and renders observed times with machine-readable values" do
    row =
      agent("safe", :errored, %{
        task: "<script>alert('task')</script>",
        reason: "<img src=x onerror=alert('reason')>",
        created_at: 1_700_000_000_000,
        started_at: 1_700_000_001_000,
        finished_at: 1_700_000_002_000
      })

    tree = render_roster(%{empty() | agents: [row]})

    assert Floki.find(tree, "script, img") == []
    assert Floki.text(tree) =~ row.task
    assert Floki.text(tree) =~ row.reason

    assert Floki.find(tree, "time") |> Floki.attribute("datetime") == [
             "2023-11-14T22:13:20.000Z",
             "2023-11-14T22:13:21.000Z",
             "2023-11-14T22:13:22.000Z"
           ]

    for label <- ["Created", "Started", "Finished"] do
      assert Floki.text(tree) =~ label
    end
  end

  test "stable DOM identity survives status updates and list reordering" do
    first =
      render_roster(%{empty() | agents: [agent("one/child", :running), agent("two", :running)]})

    second =
      render_roster(%{
        empty()
        | agents: [agent("two", :completed), agent("one/child", :interrupted)]
      })

    selector = ~s([data-agent-id="one/child"])
    assert Floki.find(first, selector) |> Floki.attribute("id") != []

    assert Floki.find(first, selector) |> Floki.attribute("id") ==
             Floki.find(second, selector) |> Floki.attribute("id")
  end

  test "unavailable snapshot does not expose stale rows or counts" do
    html =
      render_component(&SessionSubagents.subagents/1, %{
        id: "subagents",
        available: false,
        snapshot: %{empty() | agents: [agent("stale", :completed)]}
      })

    tree = Floki.parse_fragment!(html)
    assert Floki.find(tree, "[data-agent-id], [data-subagent-count]") == []
    assert Floki.text(tree) =~ "Subagents unavailable"
  end

  test "filters retain nonmatching ancestors of matching nested descendants" do
    parent = agent("parent", :completed)
    child = agent("child", :running, %{parent_agent_id: "parent", depth: 2})
    unrelated = agent("unrelated", :completed)
    snapshot = %{empty() | agents: [child, unrelated, parent]}
    tree = render_roster(snapshot, "running")

    assert [_] = Floki.find(tree, ~s([data-agent-id="parent"][data-filter-context="true"]))
    assert [_] = Floki.find(tree, ~s([data-agent-id="parent"] > ul [data-agent-id="child"]))
    assert Floki.find(tree, ~s([data-agent-id="unrelated"])) == []
    assert Floki.text(tree) =~ "Ancestor context"
    assert [_] = Floki.find(tree, ~s([phx-value-filter="running"][aria-pressed="true"]))

    stopped = render_roster(snapshot, "stopped")
    assert length(Floki.find(stopped, "[data-agent-id]")) == 2
    assert Floki.find(stopped, ~s([data-agent-id="child"])) == []
    assert Floki.text(render_roster(snapshot, "unknown")) =~ "No matching subagents"
  end

  defp render_roster(snapshot, filter \\ "all") do
    render_component(&SessionSubagents.subagents/1, %{
      id: "subagents",
      available: true,
      filter: filter,
      snapshot: snapshot
    })
    |> Floki.parse_fragment!()
  end

  defp count(tree, name) do
    tree |> Floki.find(~s([data-subagent-count="#{name}"])) |> Floki.text() |> String.trim()
  end

  defp empty do
    %{
      revision: 0,
      agents: [],
      counts: %{created: 0, executing: 0, pending: 0, stopped: 0, unknown: 0}
    }
  end

  defp agent(id, status, attrs \\ %{}) do
    Map.merge(
      %{
        agent_id: id,
        parent_agent_id: "root",
        agent_path: "/root/#{id}",
        task: "Investigate #{id}",
        status: status,
        activity: nil,
        model: "test-model",
        agent_type: "worker",
        depth: 1,
        created_at: nil,
        started_at: nil,
        finished_at: nil,
        reason: nil
      },
      attrs
    )
  end
end
