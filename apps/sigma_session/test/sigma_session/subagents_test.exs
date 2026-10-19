defmodule Sigma.Session.SubagentsTest do
  use ExUnit.Case, async: true

  alias Sigma.Session.Subagents

  defp event(fact \\ :registered, revision \\ 1, attrs \\ %{}) do
    %{
      fact: fact,
      event_id: "event-#{revision}",
      revision: revision,
      observer_incarnation: "owner-1",
      data:
        Map.merge(
          %{
            agent_id: "agent-1",
            agent_path: "/root/survey",
            root_session_id: "root-session",
            parent_agent_id: "root-agent",
            child_session_id: "child-session",
            origin_turn_id: "turn-1",
            origin_tool_call_id: "spawn-1",
            task: "survey",
            depth: 1,
            agent_type: "default",
            model: "fixture-model",
            run_id: "run-1",
            incarnation: 1,
            status: :pending_init,
            activity: nil,
            closure: :open,
            created_at: 1000,
            started_at: nil,
            finished_at: nil,
            reason: nil
          },
          attrs
        )
    }
  end

  test "empty roster has distinct zero counts" do
    assert %{
             revision: 0,
             agents: [],
             counts: %{created: 0, executing: 0, pending: 0, stopped: 0, unknown: 0}
           } =
             Subagents.snapshot(Subagents.new())
  end

  test "duplicate events and registration receipts do not create another identity" do
    registered = event()
    assert {:ok, roster} = Subagents.apply_event(Subagents.new(), registered)
    assert {:ok, ^roster} = Subagents.apply_event(roster, registered)
    assert {:ok, roster} = Subagents.apply_event(roster, event(:registered, 2))
    assert %{counts: %{created: 1, pending: 1}} = Subagents.snapshot(roster)
  end

  test "follow-up starts a new run on the same stable identity" do
    {:ok, roster} = Subagents.apply_event(Subagents.new(), event())

    {:ok, roster} =
      Subagents.apply_event(roster, event(:run_started, 2, %{status: :running, started_at: 1010}))

    {:ok, roster} =
      Subagents.apply_event(
        roster,
        event(:run_finished, 3, %{status: :completed, finished_at: 1020})
      )

    assert %{counts: %{created: 1, stopped: 1}} = Subagents.snapshot(roster)

    {:ok, roster} =
      Subagents.apply_event(
        roster,
        event(:run_started, 4, %{
          run_id: "run-2",
          incarnation: 2,
          status: :running,
          started_at: 1030
        })
      )

    assert %{counts: %{created: 1, executing: 1, stopped: 0}, agents: [agent]} =
             Subagents.snapshot(roster)

    assert agent.run_id == "run-2"
    assert agent.finished_at == nil
    assert agent.created_at == 1000
  end

  test "confirmed terminals, cancellation and unknown outcomes have separate counts" do
    for status <- [:completed, :errored, :interrupted, :shutdown, :unknown_outcome] do
      {:ok, roster} = Subagents.apply_event(Subagents.new(), event())
      fact = if status == :unknown_outcome, do: :recovered, else: :run_finished

      {:ok, roster} =
        Subagents.apply_event(roster, event(fact, 2, %{status: status, reason: "fixture"}))

      counts = Subagents.snapshot(roster).counts
      assert counts.stopped == if(status == :unknown_outcome, do: 0, else: 1)
      assert counts.unknown == if(status == :unknown_outcome, do: 1, else: 0)
    end

    {:ok, roster} = Subagents.apply_event(Subagents.new(), event())
    {:ok, roster} = Subagents.apply_event(roster, event(:run_started, 2, %{status: :cancelling}))
    assert Subagents.snapshot(roster).counts.executing == 1
  end

  test "recovery marks unconfirmed active runs unknown and preserves terminal results" do
    {:ok, roster} = Subagents.apply_event(Subagents.new(), event())
    assert Subagents.snapshot(Subagents.recover(roster)).counts.unknown == 1
    {:ok, roster} = Subagents.apply_event(roster, event(:run_finished, 2, %{status: :completed}))
    assert Subagents.snapshot(Subagents.recover(roster)).counts.stopped == 1
  end

  test "revision gaps and conflicting duplicate revisions request resync" do
    {:ok, roster} = Subagents.apply_event(Subagents.new(), event())

    assert {:error, {:resync_required, {:revision_gap, 2, 3}}} =
             Subagents.apply_event(roster, event(:run_started, 3, %{status: :running}))

    assert {:error, {:resync_required, :revision_conflict}} =
             Subagents.apply_event(roster, %{event() | event_id: "conflict"})
  end

  test "old observers and run callbacks cannot overwrite current identity" do
    {:ok, roster} = Subagents.apply_event(Subagents.new(), event())

    recovered = %{
      event(:recovered, 2, %{status: :unknown_outcome})
      | observer_incarnation: "owner-2"
    }

    {:ok, roster} = Subagents.apply_event(roster, recovered)

    assert {:error, {:stale_event, :observer_incarnation}} =
             Subagents.apply_event(roster, event(:run_finished, 3, %{status: :completed}))

    next = %{
      event(:run_started, 3, %{status: :running, run_id: "run-2", incarnation: 2})
      | observer_incarnation: "owner-2"
    }

    {:ok, roster} = Subagents.apply_event(roster, next)
    stale = %{event(:run_finished, 4, %{status: :completed}) | observer_incarnation: "owner-2"}
    assert {:error, {:stale_event, :run_identity}} = Subagents.apply_event(roster, stale)
  end

  test "malformed identities, run links, status and mutable stable fields are rejected" do
    for attrs <- [
          %{agent_id: nil},
          %{run_id: nil},
          %{incarnation: nil},
          %{status: :invented},
          %{depth: -1},
          %{created_at: "now"}
        ] do
      assert {:error, {:invalid_event, _}} =
               Subagents.apply_event(Subagents.new(), event(:registered, 1, attrs))
    end

    {:ok, roster} = Subagents.apply_event(Subagents.new(), event())

    assert {:error, {:invalid_event, {:identity_conflict, :child_session_id}}} =
             Subagents.apply_event(roster, event(:registered, 2, %{child_session_id: "other"}))

    assert {:error, {:invalid_event, :agent_not_registered}} =
             Subagents.apply_event(Subagents.new(), event(:run_started, 1, %{status: :running}))
  end

  test "safe DTO discards arbitrary host data and retains missing observed timestamps" do
    {:ok, roster} =
      Subagents.apply_event(
        Subagents.new(),
        event(:registered, 1, %{credentials: %{token: "secret"}, prompt: "private"})
      )

    agent = hd(Subagents.snapshot(roster).agents)
    refute Map.has_key?(agent, :credentials)
    refute Map.has_key?(agent, :prompt)
    assert agent.started_at == nil
    assert agent.finished_at == nil
  end

  test "closing confirms resources without replacing the completed run outcome" do
    {:ok, roster} = Subagents.apply_event(Subagents.new(), event())
    {:ok, roster} = Subagents.apply_event(roster, event(:run_finished, 2, %{status: :completed}))

    {:ok, roster} =
      Subagents.apply_event(roster, event(:closed, 3, %{status: :completed, closure: :closed}))

    assert [agent] = Subagents.snapshot(roster).agents
    assert agent.status == :completed
    assert agent.closure == :closed
  end

  test "a close receipt cannot replace a confirmed execution outcome" do
    for {confirmed, replacement} <- [{:completed, :shutdown}, {:errored, :completed}] do
      {:ok, roster} = Subagents.apply_event(Subagents.new(), event())
      {:ok, roster} = Subagents.apply_event(roster, event(:run_finished, 2, %{status: confirmed}))

      assert {:error, {:invalid_event, :terminal_transition}} =
               Subagents.apply_event(
                 roster,
                 event(:closed, 3, %{status: replacement, closure: :closed})
               )
    end
  end

  test "nested and stopped agents stay in the cumulative root roster" do
    {:ok, roster} = Subagents.apply_event(Subagents.new(), event())

    {:ok, roster} =
      Subagents.apply_event(
        roster,
        event(:registered, 2, %{
          agent_id: "nested",
          agent_path: "/root/survey/inspect",
          parent_agent_id: "agent-1",
          child_session_id: "nested-session",
          run_id: "nested-run",
          depth: 2
        })
      )

    {:ok, roster} = Subagents.apply_event(roster, event(:run_finished, 3, %{status: :completed}))

    assert %{counts: %{created: 2, pending: 1, stopped: 1}, agents: [root_child, nested]} =
             Subagents.snapshot(roster)

    assert root_child.agent_id == "agent-1"
    assert nested.parent_agent_id == root_child.agent_id
    assert nested.depth == 2
  end
end
