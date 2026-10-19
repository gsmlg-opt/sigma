defmodule Sigma.Session.SubagentJournalTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.Message
  alias Sigma.Session.{EntryDecoder, EntryEncoder, Journal, Log, Subagents, Writer}
  alias Sigma.Session.Journal.Index
  alias Sigma.Session.Storage.JsonlFile

  defmodule FailingStorage do
    @behaviour Sigma.Session.Storage
    def read(storage), do: Agent.get(storage, &{:ok, &1.entries})
    def read_with_diagnostics(storage), do: Agent.get(storage, &{:ok, &1.entries, []})

    def append(storage, entry) do
      Agent.get_and_update(storage, fn state ->
        cond do
          state.fail? ->
            {{:error, :disk_full}, state}

          Map.get(state, :lose_ack?, false) ->
            {{:error, :ack_lost}, %{state | entries: state.entries ++ [entry], lose_ack?: false}}

          true ->
            {:ok, %{state | entries: state.entries ++ [entry]}}
        end
      end)
    end
  end

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
            closure: :open,
            created_at: 1000
          },
          attrs
        )
    }
  end

  test "five lifecycle facts round trip safely instead of being ignored" do
    for fact <- [:registered, :run_started, :run_finished, :closed, :recovered] do
      expected = event(fact)
      assert {:ok, entry} = EntryEncoder.encode({:subagent, expected}, "parent", true)
      assert entry["type"] == "subagent"
      assert entry["parentId"] == "parent"
      assert is_binary(entry["id"])
      assert {:ok, decoded} = EntryDecoder.subagent(entry |> Jason.encode!() |> Jason.decode!())
      assert decoded.fact == fact
      assert decoded.data.agent_id == "agent-1"
      assert decoded.revision == 1
      assert decoded.observer_incarnation == "owner-1"
    end

    assert {:error, _} = EntryEncoder.encode({:subagent, %{event() | fact: :invented}}, nil, true)

    assert {:error, _} =
             EntryDecoder.subagent(%{"type" => "subagent", "fact" => "invented", "data" => %{}})
  end

  test "wire validation creates no atoms and excludes credentials before persistence" do
    unknown = "future_subagent_status_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    assert {:error, {:invalid_event, :status}} =
             EntryEncoder.encode(
               {:subagent, event(:registered, 1, %{status: unknown})},
               nil,
               true
             )

    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end

    assert {:ok, entry} =
             EntryEncoder.encode(
               {:subagent, event(:registered, 1, %{credentials: "secret", prompt: "private"})},
               nil,
               true
             )

    refute Map.has_key?(entry["data"], "credentials")
    refute Map.has_key?(entry["data"], "prompt")
    assert entry["data"]["created_at"] == 1000
    assert {:ok, decoded} = EntryDecoder.subagent(entry)
    assert decoded.data.status == :pending_init
  end

  @tag :tmp_dir
  test "durable facts leave conversation parents and branch checkpoints unchanged", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "root.jsonl")
    {:ok, writer} = Writer.start_link(storage_id: path, session_id: "root-session", cwd: "/repo")
    {:ok, user_id} = Writer.append(writer, {:message_end, Message.user("user", "inspect")})
    assert {:ok, _} = Writer.append(writer, {:subagent, event()})

    assert {:ok, %{active_leaf_id: ^user_id, subagents: %{counts: %{created: 1}}}} =
             Writer.flush(writer)

    {:ok, assistant_id} =
      Writer.append(writer, {:message_end, Message.assistant("assistant", %{content: "done"})})

    assert {:ok, entries} = JsonlFile.read(path)
    assert List.last(entries)["parentId"] == user_id
    assert {:ok, {^assistant_id, nodes}} = Index.path(Index.build(entries))
    refute Enum.any?(nodes, &(&1.entry["type"] == "subagent"))

    assert {:ok,
            %{
              messages: [%{id: "user"}, %{id: "assistant"}],
              subagents: %{counts: %{created: 1, unknown: 1}}
            }} = Log.snapshot(path)

    assert {:ok, [%{leaf_id: ^assistant_id}]} = Log.branch_summaries(path)
  end

  @tag :tmp_dir
  test "root roster survives retry branches while a fresh fork starts at zero", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "root.jsonl")
    fork = Path.join(tmp_dir, "fork.jsonl")
    {:ok, writer} = Writer.start_link(storage_id: path, session_id: "root-session", cwd: "/repo")

    {:ok, first_id} =
      Writer.append(
        writer,
        {:message_end, Message.assistant("first", %{content: "first branch"})}
      )

    {:ok, _} = Writer.append(writer, {:subagent, event()})

    {:ok, _} =
      Writer.append(
        writer,
        {:subagent, event(:run_finished, 2, %{status: :completed, finished_at: 1010})}
      )

    :ok = Writer.checkout(writer, nil, first_id)

    {:ok, second_id} =
      Writer.append(
        writer,
        {:message_end, Message.assistant("second", %{content: "second branch"})}
      )

    for leaf <- [first_id, second_id] do
      assert {:ok, %{subagents: %{counts: %{created: 1, stopped: 1}}}} =
               Log.snapshot(path, leaf_id: leaf)
    end

    assert {:ok, _} = Log.fork_at_message(path, fork, :all, "/fork")
    assert {:ok, %{subagents: %{counts: %{created: 0}}}} = Log.snapshot(fork)
    assert {:ok, fork_entries} = JsonlFile.read(fork)
    refute Enum.any?(fork_entries, &(&1["type"] == "subagent"))
  end

  test "storage failure never publishes or advances the roster and retry commits once" do
    {:ok, header} = EntryEncoder.encode({:agent_start, "/repo"}, nil, false)
    {:ok, storage} = Agent.start_link(fn -> %{entries: [header], fail?: true} end)

    {:ok, writer} =
      Writer.start_link(
        storage_id: storage,
        storage_mod: FailingStorage,
        session_id: "root-session"
      )

    assert {:error, {:storage_append_failed, :disk_full}} =
             Writer.append(writer, {:subagent, event()})

    assert {:ok,
            %{sequence: 1, active_leaf_id: nil, subagents: %{revision: 0, counts: %{created: 0}}}} =
             Writer.flush(writer)

    Agent.update(storage, &%{&1 | fail?: false})
    assert {:ok, committed_id} = Writer.append(writer, {:subagent, event()})
    assert {:ok, ^committed_id} = Writer.append(writer, {:subagent, event()})
    assert {:ok, %{sequence: 2, subagents: %{counts: %{created: 1}}}} = Writer.flush(writer)
    assert length(Agent.get(storage, & &1.entries)) == 2
  end

  test "lost storage acknowledgement leaves live state unchanged and replay deduplicates retry" do
    {:ok, header} = EntryEncoder.encode({:agent_start, "/repo"}, nil, false)

    {:ok, storage} =
      Agent.start_link(fn -> %{entries: [header], fail?: false, lose_ack?: true} end)

    {:ok, writer} =
      Writer.start_link(
        storage_id: storage,
        storage_mod: FailingStorage,
        session_id: "root-session"
      )

    assert {:error, {:storage_append_failed, :ack_lost}} =
             Writer.append(writer, {:subagent, event()})

    assert {:ok, %{subagents: %{counts: %{created: 0}}}} = Writer.flush(writer)
    assert {:ok, _} = Writer.append(writer, {:subagent, event()})
    assert {:ok, %{subagents: %{counts: %{created: 1}}}} = Writer.flush(writer)
    entries = Agent.get(storage, & &1.entries)
    assert length(entries) == 3
    assert {:ok, snapshot} = Journal.replay(entries)
    assert snapshot.subagents.counts.created == 1
    assert snapshot.subagents.counts.unknown == 1
    assert snapshot.diagnostics == []
  end

  @tag :tmp_dir
  test "restarted Writer returns the original committed receipt without another append", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "restart.jsonl")
    {:ok, writer} = Writer.start_link(storage_id: path, session_id: "root-session", cwd: "/repo")
    {:ok, receipt_id} = Writer.append(writer, {:subagent, event()})
    GenServer.stop(writer)
    original_bytes = File.read!(path)

    {:ok, restarted} =
      Writer.start_link(storage_id: path, session_id: "root-session", cwd: "/repo")

    assert {:ok, ^receipt_id} = Writer.append(restarted, {:subagent, event()})
    assert {:ok, %{subagents: %{counts: %{created: 1, unknown: 1}}}} = Writer.flush(restarted)
    assert File.read!(path) == original_bytes
  end

  test "old logs replay with empty roster and corrupt facts produce diagnostics" do
    assert {:ok, snapshot} = Journal.replay([])
    assert snapshot.subagents == Subagents.snapshot(Subagents.new())
    {:ok, header} = EntryEncoder.encode({:agent_start, "/repo"}, nil, false)
    {:ok, fact} = EntryEncoder.encode({:subagent, event()}, nil, true)
    malformed = Map.put(fact, "fact", "bad_fact")
    assert {:ok, snapshot} = Journal.replay([header, malformed])
    assert snapshot.active_leaf_id == nil
    assert snapshot.messages == []
    assert snapshot.subagents.counts.created == 0
    assert Enum.any?(snapshot.diagnostics, &(&1.kind == :invalid_payload))
  end

  test "duplicate durable receipts remain idempotent after restart and preserve terminals" do
    {:ok, header} = EntryEncoder.encode({:agent_start, "/repo"}, nil, false)
    {:ok, registered} = EntryEncoder.encode({:subagent, event()}, nil, true)
    {:ok, duplicate} = EntryEncoder.encode({:subagent, event()}, nil, true)

    {:ok, terminal} =
      EntryEncoder.encode(
        {:subagent, event(:run_finished, 2, %{status: :errored, reason: "provider failed"})},
        nil,
        true
      )

    assert {:ok, snapshot} = Journal.replay([header, registered, duplicate, terminal])

    assert snapshot.subagents.counts == %{
             created: 1,
             executing: 0,
             pending: 0,
             stopped: 1,
             unknown: 0
           }

    assert [agent] = snapshot.subagents.agents
    assert agent.reason == "provider failed"
    assert snapshot.active_leaf_id == nil
  end
end
