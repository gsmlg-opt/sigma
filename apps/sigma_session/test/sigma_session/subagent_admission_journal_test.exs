defmodule Sigma.Session.SubagentAdmissionJournalTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.Message
  alias Sigma.Session.{EntryDecoder, EntryEncoder, Journal, Log, Writer}
  alias Sigma.Session.Storage.JsonlFile

  defmodule Storage do
    @behaviour Sigma.Session.Storage
    def read(pid), do: Agent.get(pid, &{:ok, &1.entries})

    def append(pid, entry) do
      Agent.get_and_update(pid, fn state ->
        if state.fail?,
          do: {{:error, :disk_full}, state},
          else: {:ok, %{state | entries: state.entries ++ [entry]}}
      end)
    end
  end

  defp intent(generation \\ "generation-1") do
    %{
      phase: :intent,
      attempt_id: generation <> ":attempt-1",
      observer_incarnation: generation,
      agent_id: generation <> ":child",
      run_id: generation <> ":run-1",
      incarnation: 1,
      name: "child",
      child_session_id: "child-session",
      metadata: %{task: "inspect", depth: 1}
    }
  end

  defp receipt(status, attrs) do
    intent()
    |> Map.merge(%{phase: :receipt, status: status, process_started: status == :created})
    |> Map.merge(attrs)
  end

  defp fact do
    %{
      fact: :registered,
      event_id: "registered-1",
      revision: 1,
      observer_incarnation: "generation-1",
      data: %{
        agent_id: "generation-1:child",
        agent_path: "/root/child",
        root_session_id: "root",
        parent_agent_id: "root-agent",
        child_session_id: "child-session",
        origin_turn_id: "turn",
        origin_tool_call_id: "spawn",
        depth: 1,
        run_id: "generation-1:run-1",
        incarnation: 1,
        status: :pending_init
      }
    }
  end

  @tag :tmp_dir
  test "file-backed operational appends sync data before acknowledging", %{tmp_dir: dir} do
    path = Path.join(dir, "synced.jsonl")
    parent = self()

    pid =
      spawn(fn ->
        receive do
          :append ->
            result =
              JsonlFile.append(path, %{"type" => "subagent_admission", "phase" => "intent"})

            send(parent, {:appended, result})
        end
      end)

    :erlang.trace_pattern({:file, :sync, 1}, true, [:local])
    :erlang.trace(pid, true, [:call])
    send(pid, :append)

    try do
      assert_receive {:trace, ^pid, :call, {:file, :sync, [_io]}}, 1000
      assert_receive {:appended, :ok}
      assert {:ok, [%{"type" => "subagent_admission"}]} = JsonlFile.read(path)
    after
      :erlang.trace_pattern({:file, :sync, 1}, false, [:local])
    end
  end

  test "admissions round trip with strict fields, safe metadata and validated facts" do
    assert {:ok, entry} = EntryEncoder.encode({:subagent_admission, intent()}, nil, true)
    assert entry["type"] == "subagent_admission"
    assert {:ok, decoded} = EntryDecoder.subagent_admission(Jason.decode!(Jason.encode!(entry)))
    assert decoded.phase == :intent
    assert decoded.metadata == %{"task" => "inspect", "depth" => 1}

    for bad <- [
          %{phase: :bad},
          %{incarnation: 0},
          %{metadata: %{secret: self()}},
          %{facts: [%{fact: :invented}]},
          %{status: :created},
          %{process_started: false},
          %{credentials: "secret"},
          %{metadata: %{"task" => "b", task: "a"}}
        ] do
      assert {:error, _} =
               EntryEncoder.encode({:subagent_admission, Map.merge(intent(), bad)}, nil, true)
    end

    assert {:error, _} =
             EntryEncoder.encode(
               {:subagent_admission, receipt(:created, %{process_started: "yes"})},
               nil,
               true
             )
  end

  test "receipt requires its intent and every fact in an atomic append must validate contiguously" do
    {:ok, header} = EntryEncoder.encode({:agent_start, "/repo"}, nil, false)
    {:ok, storage} = Agent.start_link(fn -> %{entries: [header], fail?: false} end)

    {:ok, writer} =
      Writer.start_link(storage_id: storage, storage_mod: Storage, session_id: "root")

    assert {:error, {:invalid_subagent_admission, :missing_intent}} =
             Writer.append(writer, {:subagent_admission, receipt(:created, %{})})

    {:ok, _} = Writer.append(writer, {:subagent_admission, intent()})

    started = %{
      fact()
      | fact: :run_started,
        event_id: "started",
        revision: 3,
        data: Map.put(fact().data, :status, :running)
    }

    assert {:error, {:resync_required, {:revision_gap, 2, 3}}} =
             Writer.append(
               writer,
               {:subagent_admission, receipt(:created, %{facts: [fact(), started]})}
             )

    assert {:ok, %{subagents: %{revision: 0, counts: %{created: 0}}}} = Writer.flush(writer)
    assert length(Agent.get(storage, & &1.entries)) == 2

    assert {:error, {:invalid_subagent_admission, :fact_identity}} =
             Writer.append(
               writer,
               {:subagent_admission,
                receipt(
                  :created,
                  %{facts: [%{fact() | observer_incarnation: "other"}]}
                )}
             )

    valid = receipt(:created, %{facts: [fact(), %{started | revision: 2}]})
    assert {:ok, id} = Writer.append(writer, {:subagent_admission, valid})

    assert {:ok, %{subagents: %{revision: 2, counts: %{created: 1, executing: 1}}}} =
             Writer.flush(writer)

    assert {:ok, ^id} = Writer.append(writer, {:subagent, fact()})
    entries = Agent.get(storage, & &1.entries)
    assert length(entries) == 3
    assert {:ok, replayed} = Journal.replay(entries)
    assert replayed.subagents.revision == 2
    assert replayed.subagents.counts.created == 1
    assert replayed.diagnostics == []
  end

  test "replay diagnoses conflicting admissions while identical copies retain original entry ID" do
    {:ok, header} = EntryEncoder.encode({:agent_start, "/repo"}, nil, false)
    {:ok, first} = EntryEncoder.encode({:subagent_admission, intent()}, nil, true)
    {:ok, duplicate} = EntryEncoder.encode({:subagent_admission, intent()}, nil, true)

    {:ok, conflict} =
      EntryEncoder.encode({:subagent_admission, %{intent() | name: "changed"}}, nil, true)

    assert {:ok, snapshot} = Journal.replay([header, first, duplicate, conflict])

    assert snapshot.subagent_admission_entry_ids[{intent().attempt_id, :intent, nil}] ==
             first["id"]

    assert snapshot.subagent_admissions[intent().attempt_id].intent.name == "child"
    assert [%{reason: {:invalid_subagent_admission, :conflict}}] = snapshot.diagnostics
    assert snapshot.active_leaf_id == nil
    assert snapshot.branch_entry_ids == []
    assert snapshot.messages == []
  end

  test "append and replay reject a failed receipt that denies an acknowledged process start" do
    {:ok, header} = EntryEncoder.encode({:agent_start, "/repo"}, nil, false)
    {:ok, storage} = Agent.start_link(fn -> %{entries: [header], fail?: false} end)

    {:ok, writer} =
      Writer.start_link(storage_id: storage, storage_mod: Storage, session_id: "root")

    {:ok, _} = Writer.append(writer, {:subagent_admission, intent()})
    {:ok, _} = Writer.append(writer, {:subagent_admission, receipt(:created, %{})})
    assert {:ok, committed} = Writer.subagent_state(writer)
    before_entries = Agent.get(storage, & &1.entries)
    contradictory = receipt(:failed, %{process_started: false, reason: "prompt_failed"})

    assert {:error, {:invalid_subagent_admission, :outcome_conflict}} =
             Writer.append(writer, {:subagent_admission, contradictory})

    assert {:ok, ^committed} = Writer.subagent_state(writer)
    assert Agent.get(storage, & &1.entries) == before_entries

    {:ok, invalid_entry} = EntryEncoder.encode({:subagent_admission, contradictory}, nil, true)
    assert {:ok, replayed} = Journal.replay(before_entries ++ [invalid_entry])
    assert replayed.subagent_admissions == committed.admissions

    assert [%{reason: {:invalid_subagent_admission, :outcome_conflict}}] =
             replayed.diagnostics

    assert [%{status: :created, process_started: true}] =
             replayed.subagent_admissions[intent().attempt_id].receipts
  end

  test "intent and rejection do not create roster rows; created and failed receipts preserve history" do
    {:ok, header} = EntryEncoder.encode({:agent_start, "/repo"}, nil, false)
    {:ok, storage} = Agent.start_link(fn -> %{entries: [header], fail?: false} end)

    {:ok, writer} =
      Writer.start_link(storage_id: storage, storage_mod: Storage, session_id: "root")

    assert {:ok, intent_id} = Writer.append(writer, {:subagent_admission, intent()})
    assert {:ok, ^intent_id} = Writer.append(writer, {:subagent_admission, intent()})
    assert {:ok, %{subagents: %{counts: %{created: 0}}}} = Writer.flush(writer)

    assert {:ok, created_id} =
             Writer.append(writer, {:subagent_admission, receipt(:created, %{facts: [fact()]})})

    assert {:ok, ^created_id} =
             Writer.append(writer, {:subagent_admission, receipt(:created, %{facts: [fact()]})})

    assert {:ok, _} =
             Writer.append(
               writer,
               {:subagent_admission,
                receipt(:failed, %{process_started: true, reason: "prompt_failed"})}
             )

    assert {:error, _} =
             Writer.append(
               writer,
               {:subagent_admission, receipt(:created, %{reason: "conflict"})}
             )

    assert {:ok, snapshot} = Writer.flush(writer)
    assert snapshot.subagents.counts.created == 1

    assert Enum.map(snapshot.subagent_admissions[intent().attempt_id].receipts, & &1.status) == [
             :created,
             :failed
           ]

    assert {:ok, replayed} = Journal.replay(Agent.get(storage, & &1.entries))
    assert replayed.subagent_admissions == snapshot.subagent_admissions
    assert replayed.diagnostics == []
  end

  test "storage failure commits neither admission nor facts and retry after restart returns original ID" do
    {:ok, header} = EntryEncoder.encode({:agent_start, "/repo"}, nil, false)
    {:ok, storage} = Agent.start_link(fn -> %{entries: [header], fail?: false} end)
    opts = [storage_id: storage, storage_mod: Storage, session_id: "root"]
    {:ok, writer} = Writer.start_link(opts)
    {:ok, _} = Writer.append(writer, {:subagent_admission, intent()})
    Agent.update(storage, &%{&1 | fail?: true})

    assert {:error, {:storage_append_failed, :disk_full}} =
             Writer.append(writer, {:subagent_admission, receipt(:created, %{facts: [fact()]})})

    assert {:ok, snapshot} = Writer.flush(writer)
    assert snapshot.subagent_admissions[intent().attempt_id].receipts == []
    assert snapshot.subagents.counts.created == 0
    Agent.update(storage, &%{&1 | fail?: false})

    assert {:ok, id} =
             Writer.append(writer, {:subagent_admission, receipt(:created, %{facts: [fact()]})})

    GenServer.stop(writer)
    {:ok, restarted} = Writer.start_link(opts)

    assert {:ok, ^id} =
             Writer.append(
               restarted,
               {:subagent_admission, receipt(:created, %{facts: [fact()]})}
             )

    assert length(Agent.get(storage, & &1.entries)) == 3
  end

  @tag :tmp_dir
  test "generation-separated admissions survive checkout and are excluded from forks and messages",
       %{tmp_dir: dir} do
    path = Path.join(dir, "root.jsonl")
    fork = Path.join(dir, "fork.jsonl")
    {:ok, writer} = Writer.start_link(storage_id: path, session_id: "root", cwd: "/repo")

    {:ok, first} =
      Writer.append(writer, {:message_end, Message.assistant("first", %{content: "done"})})

    for generation <- ["generation-1", "generation-2"] do
      {:ok, _} = Writer.append(writer, {:subagent_admission, intent(generation)})

      rejected =
        Map.merge(intent(generation), %{
          phase: :receipt,
          status: :rejected,
          process_started: false
        })

      {:ok, _} = Writer.append(writer, {:subagent_admission, rejected})
    end

    assert {:ok, %{active_leaf_id: ^first, subagents: %{counts: %{created: 0}}}} =
             Writer.flush(writer)

    :ok = Writer.checkout(writer, nil, first)

    {:ok, second} =
      Writer.append(writer, {:message_end, Message.assistant("second", %{content: "done"})})

    for leaf <- [first, second] do
      assert {:ok, snapshot} = Log.snapshot(path, leaf_id: leaf)
      assert map_size(snapshot.subagent_admissions) == 2
      assert length(snapshot.messages) == 1
      assert length(snapshot.branch_entry_ids) == 1
    end

    assert {:ok, _} = Log.fork_at_message(path, fork, :all, "/fork")
    assert {:ok, %{subagent_admissions: %{}}} = Log.snapshot(fork)
    {:ok, entries} = JsonlFile.read(fork)
    refute Enum.any?(entries, &(&1["type"] == "subagent_admission"))
  end
end
