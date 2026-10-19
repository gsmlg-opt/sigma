defmodule Sigma.Agent.SubagentSubscriptionTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.{ProtocolSubscription, PublicRuntime, Runtime}
  alias Sigma.Protocol.{Codec, Envelope}
  alias Sigma.Session.{EntryEncoder, Log, Storage.JsonlFile}

  @moduletag :tmp_dir

  setup %{tmp_dir: root} = tags do
    repo = Path.join(root, "repo")
    sessions = Path.join(root, "sessions")
    File.mkdir_p!(repo)
    File.mkdir_p!(sessions)

    context = %{
      repo_path: repo,
      sessions_dir: sessions,
      session_opts: [
        execution_engine: Map.get(tags, :execution_engine, :sigma),
        model: %{id: "fixture", api: "fixture", provider: "fixture"},
        provider: Sigma.Agent.PublicRuntimeTest.ScriptedProvider
      ]
    }

    {:ok, create} = Envelope.command("session.create", "root", %{"cwd" => repo})
    assert {:ok, _} = PublicRuntime.execute(create, context)
    {:ok, path} = Sigma.Session.SessionFiles.jsonl_path(sessions, "root")

    on_exit(fn ->
      case Runtime.lookup(repo, :supervisor) do
        pid when is_pid(pid) ->
          DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)

        nil ->
          :ok
      end
    end)

    %{context: context, path: path, agent: Runtime.lookup(repo, "root", :agent)}
  end

  for engine <- [:sigma, :backplane] do
    @tag execution_engine: engine
    test "#{engine} host cannot replace a newer committed roster with its stale projection", c do
      host = Runtime.lookup(c.context.repo_path, "root", :subagents)
      assert {:ok, live} = Sigma.Agent.Subagents.snapshot(host)
      assert live.subagents.revision == 0
      assert live.available == (unquote(engine) == :backplane)
      assert {:ok, initial} = Runtime.session_snapshot(c.context.repo_path, "root", c.path)
      assert initial.subagents_available == live.available

      persist!(c.path, fact(:registered, 1))
      persist!(c.path, fact(:run_started, 2))
      {:ok, committed} = Log.snapshot(c.path)
      assert {:ok, snapshot} = Runtime.session_snapshot(c.context.repo_path, "root", c.path)
      assert snapshot.subagents == committed.subagents
      assert snapshot.subagents.revision == 2
      assert [%{status: :unknown_outcome}] = snapshot.subagents.agents
      refute snapshot.subagents_available
      assert {:ok, public} = command("session.status", c.context, capabilities())
      assert public.payload["subagents"] == Sigma.Protocol.Subagents.to_map(committed.subagents)
      refute public.payload["subagentsAvailable"]
    end
  end

  test "legacy snapshots omit roster and unknown events do not consume cursors", c do
    persist!(c.path, fact(:registered, 1))
    {:ok, attach} = command("subscription.attach", c.context)
    refute Map.has_key?(attach.payload, "subagents")
    id = attach.payload["subscriptionId"]
    relay = relay(id)
    send(relay, {:subagent, fact(:registered, 1)})
    :sys.get_state(relay)
    refute_receive {:sigma_protocol, ^id, _}
    assert {:ok, status} = command("session.status", c.context, %{"subscriptionId" => id})
    refute Map.has_key?(status.payload, "subagents")
    assert status.payload["cursor"] == 0
  end

  test "capable status resume attach and fork read the persisted roster", c do
    persist!(c.path, fact(:registered, 1))
    persist!(c.path, fact(:run_started, 2))
    persist!(c.path, fact(:run_finished, 3))

    {:ok, committed} = Log.snapshot(c.path)
    expected_roster = Sigma.Protocol.Subagents.to_map(committed.subagents)

    for type <- ["session.status", "session.resume", "subscription.attach"] do
      assert {:ok, event} = command(type, c.context, capabilities())
      assert event.payload["subagents"] == expected_roster
      assert event.payload["subagents"]["revision"] == 3
      assert event.payload["subagents"]["counts"]["stopped"] == 1
      assert [%{"status" => "completed"}] = event.payload["subagents"]["agents"]
      assert {:ok, _} = Codec.encode(event)

      if type == "subscription.attach" do
        assert {:ok, 0, _turn, snapshot} =
                 ProtocolSubscription.snapshot(
                   event.payload["subscriptionId"],
                   self(),
                   fn -> Log.snapshot(c.path) end
                 )

        assert snapshot.subagents == committed.subagents
      end
    end

    assert {:ok, fork} =
             command(
               "session.fork",
               c.context,
               Map.merge(capabilities(), %{
                 "targetSessionId" => "forked",
                 "expectedSourceRevision" => 1,
                 "expectedSourceLeaf" => nil
               })
             )

    assert Map.has_key?(fork.payload, "subagents")

    assert {:ok, legacy} =
             command("session.fork", c.context, %{
               "targetSessionId" => "legacy-fork",
               "expectedSourceRevision" => 1,
               "expectedSourceLeaf" => nil
             })

    refute Map.has_key?(legacy.payload, "subagents")
  end

  test "attach seeds authoritative revision before processing concurrent settlement", c do
    persist!(c.path, fact(:registered, 1))

    loader = fn ->
      send(self(), {:subagent, fact(:registered, 1)})
      persist!(c.path, fact(:run_started, 2))
      {:ok, snapshot} = Log.snapshot(c.path)
      persist!(c.path, fact(:run_finished, 3))
      send(self(), {:subagent, fact(:run_started, 2)})
      send(self(), {:subagent, fact(:run_finished, 3)})
      {:ok, snapshot}
    end

    assert {:ok, id, 0, _, snapshot} =
             ProtocolSubscription.attach_snapshot(c.agent, "root", self(),
               capabilities: ["subagents.v1"],
               snapshot_loader: loader
             )

    assert snapshot.subagents.revision == 2
    assert [%{status: :unknown_outcome}] = snapshot.subagents.agents

    assert_receive {:sigma_protocol, ^id,
                    %{type: "subagents.changed", payload: %{"revision" => 3, "cursor" => 1}}}

    refute_receive {:sigma_protocol, ^id, _}
  end

  test "duplicates stale runs and retired observers are ignored while gaps require resync", c do
    persist!(c.path, fact(:registered, 1))
    {:ok, attach} = command("subscription.attach", c.context, capabilities())
    id = attach.payload["subscriptionId"]
    pid = relay(id)
    started = fact(:run_started, 2)
    persist!(c.path, started)
    send(pid, {:subagent, started})

    assert_receive {:sigma_protocol, ^id,
                    %{type: "subagents.changed", payload: %{"revision" => 2}}}

    send(pid, {:subagent, started})
    send(pid, {:subagent, fact(:registered, 1)})
    recovered = %{fact(:recovered, 3) | observer_incarnation: "owner-2"}
    persist!(c.path, recovered)
    send(pid, {:subagent, recovered})

    assert_receive {:sigma_protocol, ^id,
                    %{type: "subagents.changed", payload: %{"revision" => 3}}}

    send(pid, {:subagent, fact(:run_started, 4)})

    send(
      pid,
      {:subagent,
       %{
         fact(:run_started, 4)
         | observer_incarnation: "owner-2",
           data: %{started.data | incarnation: 0}
       }}
    )

    :sys.get_state(pid)
    refute_receive {:sigma_protocol, ^id, _}
    persist!(c.path, %{fact(:run_finished, 4) | observer_incarnation: "owner-2"})
    gap = %{fact(:closed, 5) | observer_incarnation: "owner-2"}
    persist!(c.path, gap)
    send(pid, {:subagent, gap})

    assert_receive {:sigma_protocol, ^id,
                    %{
                      type: "session.error",
                      error: %{code: "resync_required"},
                      payload: %{"reason" => "subagent_revision_gap"}
                    }}

    assert {:ok, fresh} =
             command("session.status", c.context, Map.put(capabilities(), "subscriptionId", id))

    assert fresh.payload["subagents"]["revision"] == 5
    assert fresh.payload["subagents"]["counts"]["stopped"] == 1
    closed = %{fact(:closed, 6) | observer_incarnation: "owner-2"}
    persist!(c.path, closed)
    send(pid, {:subagent, closed})

    assert_receive {:sigma_protocol, ^id,
                    %{type: "subagents.changed", payload: %{"revision" => 6}}}
  end

  test "terminal subagent overflow remains bounded and a fresh snapshot restores counts", c do
    sink =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> send(sink, :stop) end)
    persist!(c.path, fact(:registered, 1))
    context = Map.merge(c.context, %{subscriber: sink, max_subscriber_queue: 1})
    {:ok, attach} = command("subscription.attach", context, capabilities())
    id = attach.payload["subscriptionId"]
    pid = relay(id)

    for revision <- 2..102 do
      event = fact(:run_finished, revision)
      persist!(c.path, event)
      send(pid, {:subagent, event})
    end

    state = :sys.get_state(pid)
    assert state.subagent_resync["reason"] == "subscriber_overflow"
    assert state.subagent_blocked?
    assert {:message_queue_len, queued} = Process.info(sink, :message_queue_len)
    assert queued <= 1

    assert {:ok, fresh} =
             command("session.status", context, Map.put(capabilities(), "subscriptionId", id))

    assert fresh.payload["subagents"]["counts"]["stopped"] == 1
    assert fresh.payload["subagents"]["revision"] == 102
    refute :sys.get_state(pid).subagent_blocked?
  end

  for {label, rows, task_bytes} <- [{"row limit", 201, 0}, {"byte limit", 3, 24_000}] do
    @tag timeout: 10_000
    test "oversized #{label} roster returns an encodable error and leaves no attachment", c do
      for revision <- 1..unquote(rows) do
        event = fact(:registered, revision)

        event = %{
          event
          | data: %{
              event.data
              | agent_id: "child-#{revision}",
                agent_path: "/root/child-#{revision}",
                task: String.duplicate("x", unquote(task_bytes))
            }
        }

        persist!(c.path, event)
      end

      {:ok, roster_snapshot} = Log.snapshot(c.path)
      assert length(roster_snapshot.subagents.agents) == unquote(rows)
      assert roster_snapshot.subagents.counts.created == unquote(rows)

      subscriptions = subscription_registrations()
      relay_pids = supervised_relays()

      for type <- ["session.status", "session.resume", "subscription.attach"] do
        assert {:error, %{type: "session.error", error: %{code: "payload_too_large"}} = event} =
                 command(type, c.context, capabilities())

        assert {:ok, _encoded} = Codec.encode(event)

        # Registry removes dead owners asynchronously; supervisor termination is synchronous.
        for {_id, pid, _sink} <- subscription_registrations() -- subscriptions do
          refute Process.alive?(pid)
        end

        assert MapSet.subset?(supervised_relays(), relay_pids)
      end

      assert {:ok, legacy} = command("session.status", c.context)
      refute Map.has_key?(legacy.payload, "subagents")
      assert {:ok, _} = Codec.encode(legacy)
    end
  end

  test "final committed terminal overflow delivers resync after draining without another fact",
       c do
    parent = self()

    sink =
      spawn(fn ->
        receive do
          :drain ->
            receive do
              {:sigma_protocol, _id, event} -> send(parent, {:drained, event})
            end

            forward_sink(parent)

          :stop ->
            :ok
        end
      end)

    on_exit(fn -> send(sink, :stop) end)
    persist!(c.path, fact(:registered, 1))
    context = Map.merge(c.context, %{subscriber: sink, max_subscriber_queue: 1})
    {:ok, attach} = command("subscription.attach", context, capabilities())
    id = attach.payload["subscriptionId"]
    pid = relay(id)
    persist!(c.path, fact(:run_started, 2))
    send(pid, {:subagent, fact(:run_started, 2)})
    :sys.get_state(pid)
    persist!(c.path, fact(:run_finished, 3))
    send(pid, {:subagent, fact(:run_finished, 3)})
    state = :sys.get_state(pid)
    assert state.subagent_resync["reason"] == "subscriber_overflow"
    assert {:message_queue_len, 1} = Process.info(sink, :message_queue_len)
    send(sink, :drain)
    assert_receive {:drained, %{type: "subagents.changed", payload: %{"revision" => 2}}}

    assert_receive {:forwarded, %{type: "session.error", error: %{code: "resync_required"}}},
                   1_000

    refute_receive {:forwarded, _}

    assert {:ok, fresh} =
             command("session.status", context, Map.put(capabilities(), "subscriptionId", id))

    assert fresh.payload["subagents"]["counts"]["stopped"] == 1
    refute :sys.get_state(pid).subagent_blocked?
  end

  test "unencodable committed terminal delta requests resync instead of sending an unsafe envelope",
       c do
    persist!(c.path, fact(:registered, 1))
    persist!(c.path, fact(:run_started, 2))
    {:ok, attach} = command("subscription.attach", c.context, capabilities())
    id = attach.payload["subscriptionId"]
    pid = relay(id)
    event = fact(:run_finished, 3)
    event = %{event | data: %{event.data | task: String.duplicate("x", 40_000)}}
    persist!(c.path, event)
    send(pid, {:subagent, event})
    assert_receive {:sigma_protocol, ^id, delivered}
    assert delivered.type == "session.error"
    assert delivered.error.code == "resync_required"
    assert delivered.payload["reason"] == "subagent_payload_too_large"
    assert {:ok, _} = Codec.encode(delivered)
    assert :sys.get_state(pid).subagent_blocked?
    {:ok, snapshot} = Log.snapshot(c.path)
    assert [%{task: task, status: :completed}] = snapshot.subagents.agents
    assert byte_size(task) == 40_000
    refute_receive {:sigma_protocol, ^id, %{type: "subagents.changed"}}

    assert {:error, %{error: %{code: "payload_too_large"}}} =
             command("session.status", c.context, Map.put(capabilities(), "subscriptionId", id))

    assert :sys.get_state(pid).subagent_blocked?
    before_legacy_status = :sys.get_state(pid)
    assert {:ok, legacy} = command("session.status", c.context, %{"subscriptionId" => id})
    refute Map.has_key?(legacy.payload, "subagents")
    after_legacy_status = :sys.get_state(pid)
    assert after_legacy_status.subagent_blocked?
    assert after_legacy_status.subagent_revision == before_legacy_status.subagent_revision
    assert after_legacy_status.subagent_resync == before_legacy_status.subagent_resync
    closed = fact(:closed, 4)
    persist!(c.path, closed)
    send(pid, {:subagent, closed})
    refute_receive {:sigma_protocol, ^id, %{type: "subagents.changed"}}
    assert :sys.get_state(pid).subagent_blocked?

    assert {:ok, fresh} =
             command("session.status", c.context, Map.put(capabilities(), "subscriptionId", id))

    assert fresh.payload["subagents"]["revision"] == 4
    assert fresh.payload["subagents"]["counts"]["stopped"] == 1
    refute :sys.get_state(pid).subagent_blocked?
    closed = fact(:closed, 5)
    persist!(c.path, closed)
    send(pid, {:subagent, closed})

    assert_receive {:sigma_protocol, ^id,
                    %{type: "subagents.changed", payload: %{"revision" => 5}}}
  end

  defp forward_sink(parent) do
    receive do
      {:sigma_protocol, _id, event} ->
        send(parent, {:forwarded, event})
        forward_sink(parent)

      :stop ->
        :ok
    end
  end

  defp subscription_registrations do
    Registry.select(Sigma.Agent.ProtocolSubscriptionRegistry, [
      {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
    ])
  end

  defp supervised_relays do
    Sigma.Agent.ProtocolSubscriptionSupervisor
    |> DynamicSupervisor.which_children()
    |> MapSet.new(fn {_id, pid, _type, _modules} -> pid end)
  end

  defp capabilities, do: %{"requiredCapabilities" => ["subagents.v1"]}

  defp command(type, context, payload \\ %{}) do
    {:ok, command} = Envelope.command(type, "root", payload)
    PublicRuntime.execute(command, context)
  end

  defp relay(id) do
    [{pid, _}] = Registry.lookup(Sigma.Agent.ProtocolSubscriptionRegistry, id)
    pid
  end

  defp persist!(path, event) do
    {:ok, entry} = EntryEncoder.encode({:subagent, event}, nil, true)
    :ok = JsonlFile.append(path, entry)
  end

  defp fact(fact, revision) do
    status =
      %{
        registered: :pending_init,
        run_started: :running,
        run_finished: :completed,
        recovered: :unknown_outcome,
        closed: :completed
      }[fact]

    %{
      fact: fact,
      event_id: "event-#{revision}",
      revision: revision,
      observer_incarnation: "owner-1",
      data: %{
        agent_id: "child",
        agent_path: "/root/child",
        root_session_id: "root",
        parent_agent_id: "parent",
        child_session_id: "child-session",
        origin_turn_id: "turn-1",
        origin_tool_call_id: "spawn-1",
        depth: 1,
        run_id: "run-1",
        incarnation: 1,
        status: status,
        closure: if(fact == :closed, do: :closed, else: :open),
        task: "fixture"
      }
    }
  end
end
