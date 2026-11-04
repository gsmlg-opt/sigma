defmodule Sigma.Agent.ProtocolAsyncInteractionsTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.{ProtocolEventMapper, ProtocolSubscription, PublicRuntime, Runtime}
  alias Sigma.Protocol.{AsyncInteractions, Codec, Envelope}
  alias Sigma.Session.Writer

  @moduletag :tmp_dir
  @capability "async_interactions.v1"
  @pages "async_interactions.pages.v1"
  @session "async-session"

  setup %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    sessions = Path.join(dir, "sessions")
    File.mkdir_p!(repo)
    File.mkdir_p!(sessions)
    {:ok, projection} = AsyncInteractions.apply_event(AsyncInteractions.new(), received())
    inbox = start_supervised!({Agent, fn -> %{projection: projection, leaf_id: "anchor"} end})
    owner = self()

    context = %{
      repo_path: repo,
      sessions_dir: sessions,
      session_opts: [
        model: %{id: "mock", api: "mock", provider: "mock"},
        provider: Sigma.Ai.Providers.Anthropic
      ],
      async_interaction_snapshot: fn _agent -> {:ok, snapshot(inbox)} end,
      reply_async_interaction: fn agent, item_id, payload, leaf ->
        send(owner, {:async_reply_called, agent, item_id, payload, leaf})

        mutate(inbox, item_id, leaf, fn item ->
          with {:ok, reply} <- AsyncInteractions.reply(payload, item),
               {:ok, fact} <- AsyncInteractions.fact(item, "reply_saved", %{"reply" => reply}) do
            {:ok, fact, {:ok, %{status: :saved, private: self()}}}
          end
        end)
      end,
      dismiss_async_interaction: fn agent, item_id, leaf ->
        send(owner, {:async_dismiss_called, agent, item_id, leaf})

        mutate(inbox, item_id, leaf, fn item ->
          with {:ok, fact} <-
                 AsyncInteractions.fact(item, "dismissed", %{"reason" => "user_dismissed"}) do
            {:ok, fact, :ok}
          end
        end)
      end
    }

    assert {:ok, _} = execute(context, "session.create", %{"cwd" => repo})
    agent = Runtime.lookup(repo, @session, :agent)

    on_exit(fn ->
      if supervisor = Runtime.lookup(repo, :supervisor),
        do: DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, supervisor)
    end)

    %{context: context, inbox: inbox, agent: agent}
  end

  test "async snapshots and updates are opt-in and retain full ordered cards", %{
    context: context,
    inbox: inbox
  } do
    assert {:ok, legacy_snapshot} = execute(context, "session.status", %{})
    refute Map.has_key?(legacy_snapshot.payload, "asyncInteractions")
    refute Map.has_key?(legacy_snapshot.payload, "asyncInteractionLeafId")
    assert {:ok, capable} = execute(context, "subscription.attach", capable_payload())
    assert capable.payload["asyncInteractions"] == snapshot(inbox).items
    assert capable.payload["asyncInteractionLeafId"] == "anchor"
    assert {:ok, legacy} = execute(context, "subscription.attach", %{})
    refute Map.has_key?(legacy.payload, "asyncInteractions")
    opted_id = capable.payload["subscriptionId"]
    legacy_id = legacy.payload["subscriptionId"]
    send(relay(opted_id), {:async_interactions_updated, snapshot(inbox)})
    send(relay(legacy_id), {:async_interactions_updated, snapshot(inbox)})
    event = receive_type(opted_id, "async_interactions.updated")
    assert event.payload["items"] == snapshot(inbox).items
    assert event.payload["leafId"] == "anchor"
    assert event.payload["cursor"] > 0
    refute_receive {:sigma_protocol, ^legacy_id, _}, 30
  end

  test "reply ACK preserves exact text and separate saved status without exposing host terms", %{
    context: context,
    agent: agent,
    inbox: inbox
  } do
    reply = reply_payload()
    assert {:ok, event} = execute(context, "async_interaction.reply", command_payload(reply))
    assert_receive {:async_reply_called, ^agent, "item", ^reply, "anchor"}
    assert event.type == "async_interactions.updated"
    assert event.payload["acknowledgement"] == %{"itemId" => "item", "status" => "saved"}
    assert [item] = event.payload["items"]
    assert item["status"] == "saved"
    assert item["reply"]["content"] =~ "  原文\n"
    assert item["reply"]["content"] =~ " freeform answer "
    assert {:ok, json} = Codec.encode(event)
    refute json =~ "private"
    assert {:ok, repeated} = execute(context, "async_interaction.reply", command_payload(reply))
    assert repeated.payload["items"] == event.payload["items"]

    assert {:error, _} =
             execute(
               context,
               "async_interaction.reply",
               command_payload(put_in(reply, ["answers", Access.at(0), "answer"], "different"))
             )

    assert hd(snapshot(inbox).items)["reply"] == item["reply"]
  end

  test "a real already-consumed Agent retry returns a string status without dispatching again", %{
    context: context,
    agent: agent
  } do
    writer = Runtime.lookup(context.repo_path, @session, :writer)

    message =
      Sigma.Agent.Message.user("origin-user", "Origin") |> Map.put(:metadata, %{turn_id: "run"})

    assert {:ok, anchor} = Writer.append(writer, {:message_end, message})
    event = put_in(received(), ["origin", "branch_entry_id"], anchor)
    assert {:ok, _} = Writer.append_async_interaction(writer, event, anchor)
    assert {:ok, state} = Writer.async_interaction_state(writer)
    item = state.projection.items["item"]
    assert {:ok, reply} = AsyncInteractions.reply(reply_payload(), item)

    for {name, attrs} <- [
          {"reply_saved", %{"reply" => reply}},
          {"dispatch_started", %{"reply_id" => "reply"}},
          {"consumed", %{"reply_id" => "reply"}}
        ] do
      assert {:ok, fact} = AsyncInteractions.fact(item, name, attrs)
      assert {:ok, _} = Writer.append_async_interaction(writer, fact, anchor)
    end

    assert {:ok, before} = Writer.async_interaction_state(writer)

    assert {:ok, %{status: "consumed"}} =
             Sigma.Agent.reply_async_interaction(agent, "item", reply_payload(), anchor)

    real_context =
      Map.drop(context, [
        :async_interaction_snapshot,
        :reply_async_interaction,
        :dismiss_async_interaction
      ])

    payload = %{command_payload() | "expectedLeafId" => anchor}
    assert {:ok, response} = execute(real_context, "async_interaction.reply", payload)
    assert response.payload["acknowledgement"] == %{"itemId" => "item", "status" => "consumed"}
    assert hd(response.payload["items"])["status"] == "consumed"
    assert {:ok, ^before} = Writer.async_interaction_state(writer)
    assert :sys.get_state(agent).current_turn_task == nil
  end

  test "notification replies are optional new messages and dismissal closes the card", %{
    context: context,
    inbox: inbox
  } do
    notice = received() |> Map.delete("questions") |> Map.put("message", "Still working")
    notice = put_in(notice, ["origin", "tool_name"], "send_message_to_user_async")
    {:ok, projection} = AsyncInteractions.apply_event(AsyncInteractions.new(), notice)
    Agent.update(inbox, &%{&1 | projection: projection})

    assert {:ok, reply_event} =
             execute(
               context,
               "async_interaction.reply",
               command_payload(%{"replyId" => "optional", "text" => "  Please continue\n"})
             )

    assert hd(reply_event.payload["items"])["reply"]["content"] =~ "  Please continue\n"

    assert {:ok, dismissed} =
             execute(context, "async_interaction.dismiss", Map.delete(command_payload(), "reply"))

    assert hd(dismissed.payload["items"])["status"] == "dismissed"
    refute hd(dismissed.payload["items"])["can_reply"]

    assert {:error, _} =
             execute(
               context,
               "async_interaction.reply",
               command_payload(%{"replyId" => "late", "text" => "Late"})
             )
  end

  test "invalid commands never reach host callbacks or change the inbox", %{
    context: context,
    inbox: inbox
  } do
    original = snapshot(inbox)
    payload = command_payload()

    for invalid <- [
          Map.put(payload, "messageId", "chosen"),
          Map.put(payload, "turnId", "chosen"),
          Map.put(payload, "unsupported", true),
          Map.delete(payload, "expectedLeafId"),
          Map.put(payload, "expectedLeafId", self()),
          put_in(payload, ["reply", "metadata"], %{}),
          put_in(payload, ["reply", "message_id"], "chosen"),
          put_in(payload, ["reply", "answers"], []),
          put_in(payload, ["reply", "answers"], [%{"questionIndex" => 1, "answer" => "A"}]),
          put_in(payload, ["reply", "answers", Access.at(0), "answer"], <<255>>)
        ] do
      assert {:error, _} = execute(context, "async_interaction.reply", invalid)
    end

    assert {:error, _} = execute(context, "async_interaction.dismiss", payload)
    assert snapshot(inbox) == original
    refute_receive {:async_reply_called, _, _, _, _}, 0
    refute_receive {:async_dismiss_called, _, _, _}, 0
  end

  test "capability, session and expected-leaf boundaries prevent cross-channel consumption", %{
    context: context,
    inbox: inbox
  } do
    original = snapshot(inbox)

    assert {:error, %{error: %{code: "required_capability_missing"}}} =
             execute(
               context,
               "async_interaction.reply",
               Map.delete(command_payload(), "requiredCapabilities")
             )

    assert {:error, %{error: %{code: "session_not_running"}}} =
             execute(context, "async_interaction.reply", command_payload(), "wrong-session")

    refute_receive {:async_reply_called, _, _, _, _}, 0

    assert {:error, %{error: %{code: "leaf_conflict"}}} =
             execute(context, "async_interaction.reply", %{
               command_payload()
               | "expectedLeafId" => "old-leaf"
             })

    assert {:error, _} =
             execute(context, "question.resolve", %{
               "requestId" => "item",
               "action" => "answer",
               "answer" => "A"
             })

    assert {:error, _} =
             execute(context, "permission.resolve", %{
               "requestId" => "item",
               "decision" => "allow"
             })

    assert snapshot(inbox) == original
  end

  test "malformed card payloads fail closed without projecting private values", %{inbox: inbox} do
    [item] = snapshot(inbox).items

    for malformed <- [
          Map.put(item, "private", "hidden-secret"),
          Map.put(item, "can_reply", self()),
          put_in(item, ["origin", "callback"], fn -> :secret end),
          put_in(item, ["questions", Access.at(0), "title"], <<255>>)
        ] do
      assert {%{type: "session.error", error: %{code: "async_payload_rejected"}} = event, "turn"} =
               ProtocolEventMapper.map(
                 {:async_interactions_updated, %{items: [malformed], leaf_id: "anchor"}},
                 @session,
                 "turn"
               )

      assert {:ok, json} = Codec.encode(event)
      refute json =~ "hidden-secret"
      refute json =~ "#PID"
    end

    foreign = %{item | "session_id" => "foreign"}

    assert {:error, _} =
             ProtocolEventMapper.async_interaction_payload(
               %{items: [foreign], leaf_id: "anchor"},
               @session
             )

    assert {:ok, _} =
             ProtocolEventMapper.async_interaction_payload(
               %{items: [%{foreign | "can_reply" => false}], leaf_id: "anchor"},
               @session
             )
  end

  test "consumption after delivery uncertainty preserves its reason in the wire DTO", %{
    inbox: inbox
  } do
    state = Agent.get(inbox, & &1.projection)
    item = state.items["item"]
    {:ok, reply} = AsyncInteractions.reply(reply_payload(), item)
    {:ok, saved} = AsyncInteractions.fact(item, "reply_saved", %{"reply" => reply})
    {:ok, state} = AsyncInteractions.apply_event(state, saved)

    for {fact, attrs} <- [
          {"dispatch_started", %{"reply_id" => "reply"}},
          {"delivery_unknown", %{"reply_id" => "reply", "reason" => "ack_lost"}},
          {"consumed", %{"reply_id" => "reply"}}
        ],
        reduce: state do
      state ->
        {:ok, event} = AsyncInteractions.fact(item, fact, attrs)
        {:ok, state} = AsyncInteractions.apply_event(state, event)
        card = Map.put(state.items["item"], "can_reply", false)

        assert {:ok, _} =
                 ProtocolEventMapper.async_interaction_payload(
                   %{items: [card], leaf_id: "anchor"},
                   @session
                 )

        state
    end
  end

  test "oversized snapshots and attachments return an explicit error without truncation", %{
    context: context,
    inbox: inbox,
    agent: agent
  } do
    oversized =
      put_in(received(), ["questions"], [
        %{
          "title" => String.duplicate("q", 32_768),
          "options" => [String.duplicate("a", 32_768), String.duplicate("b", 32_768)]
        }
      ])

    {:ok, projection} = AsyncInteractions.apply_event(AsyncInteractions.new(), oversized)
    Agent.update(inbox, &%{&1 | projection: projection})
    before = snapshot(inbox)

    assert {:error, %{error: %{code: "async_payload_too_large"}}} =
             execute(context, "session.status", capable_payload())

    count = Registry.count(Sigma.Agent.ProtocolSubscriptionRegistry)
    owner = self()
    subscribers = :sys.get_state(agent).subscribers

    attachment_context =
      Map.put(context, :async_interaction_snapshot, fn _agent ->
        [subscription_id] = Registry.keys(Sigma.Agent.ProtocolSubscriptionRegistry, self())
        send(owner, {:attachment_started, self(), subscription_id})
        {:ok, snapshot(inbox)}
      end)

    assert {:error, %{error: %{code: "async_payload_too_large"}}} =
             execute(attachment_context, "subscription.attach", capable_payload())

    assert_receive {:attachment_started, failed_relay, subscription_id}
    refute Process.alive?(failed_relay)
    assert Registry.lookup(Sigma.Agent.ProtocolSubscriptionRegistry, subscription_id) == []

    refute Enum.any?(
             DynamicSupervisor.which_children(Sigma.Agent.ProtocolSubscriptionSupervisor),
             fn {_id, pid, _type, _modules} -> pid == failed_relay end
           )

    assert :sys.get_state(agent).subscribers == subscribers
    assert Registry.count(Sigma.Agent.ProtocolSubscriptionRegistry) == count
    assert snapshot(inbox) == before
  end

  test "detach synchronously removes the relay, Registry binding and Agent subscription", %{
    context: context,
    agent: agent
  } do
    subscribers = :sys.get_state(agent).subscribers
    assert {:ok, attached} = execute(context, "subscription.attach", capable_payload())
    id = attached.payload["subscriptionId"]
    pid = relay(id)
    assert pid in :sys.get_state(agent).subscribers
    assert {:ok, _} = execute(context, "subscription.detach", %{"subscriptionId" => id})
    refute Process.alive?(pid)
    assert Registry.lookup(Sigma.Agent.ProtocolSubscriptionRegistry, id) == []
    assert :sys.get_state(agent).subscribers == subscribers

    refute Enum.any?(
             DynamicSupervisor.which_children(Sigma.Agent.ProtocolSubscriptionSupervisor),
             fn {_id, child, _type, _modules} -> child == pid end
           )
  end

  test "a dropped async update stays blocked until a validated capable snapshot succeeds", %{
    context: context,
    inbox: inbox
  } do
    owner = self()

    sink =
      spawn(fn ->
        receive do
          :drain -> forward_sink(owner)
        end
      end)

    on_exit(fn -> if Process.alive?(sink), do: Process.exit(sink, :kill) end)
    send(sink, :occupied)
    slow_context = Map.merge(context, %{subscriber: sink, max_subscriber_queue: 1})
    assert {:ok, attached} = execute(slow_context, "subscription.attach", capable_payload())
    id = attached.payload["subscriptionId"]
    pid = relay(id)
    send(pid, {:async_interactions_updated, snapshot(inbox)})
    assert :sys.get_state(pid).async_blocked?
    send(sink, :drain)
    assert_receive {:async_sink, :occupied}

    assert_receive {:async_sink,
                    {:sigma_protocol, ^id,
                     %{type: "session.error", error: %{code: "resync_required"}}}}

    send(pid, {:async_interactions_updated, snapshot(inbox)})
    assert :sys.get_state(pid).async_blocked?
    sync_sink(sink)
    refute_receive {:async_sink, {:sigma_protocol, ^id, _}}, 0
    assert {:ok, _} = execute(slow_context, "session.status", %{"subscriptionId" => id})
    assert :sys.get_state(pid).async_blocked?

    assert {:ok, _, _, _} =
             ProtocolSubscription.snapshot(id, sink, fn ->
               {:ok, %{async_interaction_snapshot: snapshot(inbox)}}
             end)

    assert :sys.get_state(pid).async_blocked?

    failed_context =
      Map.put(slow_context, :async_interaction_snapshot, fn _ ->
        {:error, :snapshot_unavailable}
      end)

    assert {:error, _} =
             execute(
               failed_context,
               "session.status",
               Map.put(capable_payload(), "subscriptionId", id)
             )

    assert :sys.get_state(pid).async_blocked?

    assert {:ok, refreshed} =
             execute(
               slow_context,
               "session.status",
               Map.put(capable_payload(), "subscriptionId", id)
             )

    assert refreshed.payload["asyncInteractions"] == snapshot(inbox).items
    refute :sys.get_state(pid).async_blocked?
    send(pid, {:async_interactions_updated, snapshot(inbox)})
    assert_receive {:async_sink, {:sigma_protocol, ^id, %{type: "async_interactions.updated"}}}
  end

  test "delivery checks the final correlated envelope size after adding cursor and long identities",
       %{
         agent: agent
       } do
    session_id = String.duplicate("s", 200)
    turn_id = String.duplicate("t", 200)

    event = %{
      received()
      | "session_id" => session_id,
        "questions" => [
          %{
            "title" => String.duplicate("q", 32_768),
            "options" => [String.duplicate("o", 30_000)]
          }
        ]
    }

    {:ok, projection} = AsyncInteractions.apply_event(AsyncInteractions.new(), event)
    item = Map.put(projection.items["item"], "can_reply", true)

    {:ok, payload} =
      ProtocolEventMapper.async_interaction_payload(
        %{items: [item], leaf_id: "anchor"},
        session_id
      )

    {:ok, probe} = Envelope.event("async_interactions.updated", "projection", payload)
    {:ok, encoded} = Codec.encode(probe)
    padding = 65_536 - byte_size(encoded) - 16
    assert padding > 0

    item =
      put_in(
        item,
        ["questions", Access.at(0), "options", Access.at(0)],
        String.duplicate("o", 30_000 + padding)
      )

    assert {:ok, _} =
             ProtocolEventMapper.async_interaction_payload(
               %{items: [item], leaf_id: "anchor"},
               session_id
             )

    assert {:ok, subscription} =
             ProtocolSubscription.attach(agent, session_id, self(), capabilities: [@capability])

    send(
      relay(subscription),
      {:prompt_admitted, :accepted, %{message_id: "wire-message", turn_id: turn_id}}
    )

    assert receive_type(subscription, "prompt.admitted").turn_id == turn_id
    send(relay(subscription), {:async_interactions_updated, %{items: [item], leaf_id: "anchor"}})
    error = receive_type(subscription, "session.error")
    assert error.error.code == "async_payload_too_large"
    refute Map.has_key?(error.payload, "items")
    assert {:ok, _} = Codec.encode(error)
    assert byte_size(hd(hd(item["questions"])["options"])) == 30_000 + padding
  end

  test "Runtime delivery identities survive capable snapshots and consumed updates", %{
    context: context,
    inbox: inbox
  } do
    for status <- ~w(dispatching admitted consumed delivery_unknown) do
      assert {:ok, state} = AsyncInteractions.apply_event(AsyncInteractions.new(), received())
      item = state.items["item"]
      assert {:ok, reply} = AsyncInteractions.reply(reply_payload(), item)
      delivery = %{"run_id" => "destination", "runtime_message_id" => "runtime-admission"}

      facts = [
        {"reply_saved", %{"reply" => reply}},
        {"dispatch_started", %{"reply_id" => "reply"}},
        {"runtime_admitted", Map.put(delivery, "reply_id", "reply")}
      ]

      facts =
        case status do
          "dispatching" ->
            facts

          "delivery_unknown" ->
            facts ++ [{status, %{"reply_id" => "reply", "reason" => "unconfirmed"}}]

          _ ->
            facts ++ [{status, %{"reply_id" => "reply"}}]
        end

      projection =
        Enum.reduce(facts, state, fn {name, attrs}, state ->
          assert {:ok, event} = AsyncInteractions.fact(item, name, attrs)
          assert {:ok, state} = AsyncInteractions.apply_event(state, event)
          state
        end)

      Agent.update(inbox, &%{&1 | projection: projection})
      assert {:ok, response} = execute(context, "subscription.attach", capable_payload())
      assert [card] = response.payload["asyncInteractions"]
      assert card["status"] == status
      assert card["delivery"] == delivery
      assert {:ok, _} = Codec.encode(response)

      assert {:error, :async_payload_rejected} =
               ProtocolEventMapper.async_interaction_payload(
                 %{
                   items: [put_in(card, ["delivery", "runtime_message_id"], "")],
                   leaf_id: "anchor"
                 },
                 @session
               )
    end
  end

  test "large history remains a valid host snapshot with an explicit wire size boundary" do
    cards =
      for index <- 1..257 do
        event = received()
        id = "item-#{index}"
        event = %{event | "event_id" => "event-#{index}", "item_id" => id}
        assert {:ok, state} = AsyncInteractions.apply_event(AsyncInteractions.new(), event)
        state.items[id] |> Map.put("sequence", index) |> Map.put("can_reply", true)
      end

    assert {:ok, payload} =
             ProtocolEventMapper.async_interaction_payload(
               %{items: cards, leaf_id: "anchor"},
               @session
             )

    assert payload["items"] == cards
    assert {:ok, envelope} = Envelope.event("async_interactions.updated", @session, payload)
    assert {:error, :payload_too_large} = Codec.encode(envelope)
    assert length(envelope.payload["items"]) == 257
  end

  test "paged subscriptions read large complete cards and histories within unchanged wire limits",
       %{
         context: context,
         inbox: inbox
       } do
    replace_many(inbox, 225, true)

    assert {:error, %{error: %{code: "async_payload_too_large"}}} =
             execute(context, "session.status", capable_payload())

    assert {:ok, attached} = execute(context, "subscription.attach", pages_payload())
    descriptor = attached.payload["asyncInteractionInbox"]
    assert descriptor["itemCount"] == 225
    refute Map.has_key?(attached.payload, "asyncInteractions")
    refute Map.has_key?(attached.payload, "asyncInteractionLeafId")
    assert {:ok, json} = Codec.encode(attached)
    assert byte_size(json) < 65_536

    cards = paged_summaries(context, descriptor, 0)
    assert Enum.map(cards, & &1["itemId"]) == Enum.map(snapshot(inbox).items, & &1["item_id"])
    assert hd(cards)["byteLength"] > 65_536
    bytes = paged_card(context, descriptor, "item", 0)
    assert Jason.decode!(bytes) == hd(snapshot(inbox).items)
    assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == hd(cards)["sha256"]

    id = attached.payload["subscriptionId"]
    send(relay(id), {:async_interactions_updated, snapshot(inbox)})
    event = receive_type(id, "async_interactions.changed")
    assert event.payload["inbox"] == descriptor
    refute Map.has_key?(event.payload, "items")
  end

  test "paged reply ACK is bounded and invalidates old reads without changing reply identity", %{
    context: context,
    inbox: inbox,
    agent: agent
  } do
    replace_many(inbox, 225)
    assert {:ok, before} = execute(context, "session.status", pages_payload())
    descriptor = before.payload["asyncInteractionInbox"]
    reply = Map.merge(command_payload(), pages_payload())
    assert {:ok, saved} = execute(context, "async_interaction.reply", reply)
    assert saved.type == "async_interactions.changed"
    assert saved.payload["acknowledgement"] == %{"itemId" => "item", "status" => "saved"}
    assert saved.payload["inbox"]["revision"] != descriptor["revision"]
    assert_receive {:async_reply_called, ^agent, "item", _, "anchor"}
    assert {:ok, _} = Codec.encode(saved)

    assert {:error, %{error: %{code: "async_inbox_stale"}}} =
             execute(context, "async_interactions.list", page_request(descriptor))

    assert {:ok, repeated} = execute(context, "async_interaction.reply", reply)
    assert repeated.payload == saved.payload

    dismiss = reply |> Map.delete("reply")
    assert {:ok, dismissed} = execute(context, "async_interaction.dismiss", dismiss)
    assert dismissed.payload["acknowledgement"]["status"] == "dismissed"
    refute Map.has_key?(dismissed.payload, "items")
  end

  test "paged mode rejects mixed capabilities and malformed queries before host calls", %{
    context: context,
    inbox: inbox
  } do
    before = snapshot(inbox)

    for type <- ["session.status", "subscription.attach", "async_interaction.reply"] do
      payload = Map.put(command_payload(), "requiredCapabilities", [@capability, @pages])

      assert {:error, %{error: %{code: "incompatible_protocol_capabilities"}}} =
               execute(context, type, payload)
    end

    for type <- ["async_interactions.list", "async_interaction.read"] do
      assert {:error, %{error: %{code: "required_capability_missing"}}} =
               execute(context, type, capable_payload())

      assert {:error, %{error: %{code: "invalid_async_page"}}} =
               execute(context, type, Map.put(pages_payload(), "expectedRevision", "bad"))
    end

    refute_receive {:async_reply_called, _, _, _, _}, 0
    assert snapshot(inbox) == before
  end

  test "an accepted async mutation retains its receipt when the subsequent snapshot fails", %{
    context: context,
    inbox: inbox
  } do
    for capability <- [@capability, @pages] do
      replace_many(inbox, 1)

      failed =
        Map.put(context, :async_interaction_snapshot, fn _ -> {:error, :snapshot_failed} end)

      payload = Map.put(command_payload(), "requiredCapabilities", [capability])
      assert {:error, event} = execute(failed, "async_interaction.reply", payload)
      assert event.payload["acknowledgement"] == %{"itemId" => "item", "status" => "saved"}
      assert event.payload["snapshotRequired"] == true
      assert event.error.message =~ "accepted"
      assert hd(snapshot(inbox).items)["status"] == "saved"
      assert {:ok, _} = Codec.encode(event)

      # A failed refresh does not turn the accepted mutation into a new operation.
      assert {:ok, retried} = execute(context, "async_interaction.reply", payload)
      assert retried.payload["acknowledgement"] == event.payload["acknowledgement"]

      for failing_read <- [fn _ -> raise "read failed" end, fn _ -> exit(:read_failed) end] do
        failing = Map.put(context, :async_interaction_snapshot, failing_read)
        assert {:error, raised} = execute(failing, "async_interaction.reply", payload)
        assert raised.payload["acknowledgement"] == event.payload["acknowledgement"]
        assert raised.payload["snapshotRequired"]
      end
    end
  end

  test "paged resync is bound to attached Agent session and async mode before loading", %{
    context: context
  } do
    assert {:ok, attached} = execute(context, "subscription.attach", pages_payload())
    id = attached.payload["subscriptionId"]
    pid = relay(id)
    :sys.replace_state(pid, &%{&1 | async_blocked?: true})
    owner = self()

    guarded =
      Map.put(context, :async_interaction_snapshot, fn _ ->
        send(owner, :snapshot_loaded)
        {:error, :must_not_load}
      end)

    payload = Map.put(pages_payload(), "subscriptionId", id)

    assert {:error, %{error: %{code: "subscription_scope_mismatch"}}} =
             execute(guarded, "session.status", payload, "another-session")

    assert {:error, %{error: %{code: "subscription_scope_mismatch"}}} =
             execute(
               %{guarded | repo_path: context.repo_path <> "-other"},
               "session.status",
               payload
             )

    assert {:error, %{error: %{code: "subscription_mode_mismatch"}}} =
             execute(guarded, "session.status", Map.put(capable_payload(), "subscriptionId", id))

    refute_receive :snapshot_loaded, 0
    assert :sys.get_state(pid).async_blocked?
    assert {:ok, _} = execute(context, "session.status", payload)
    refute :sys.get_state(pid).async_blocked?
  end

  test "paged overflow stays blocked through failed snapshots and recovers from a validated descriptor",
       %{
         context: context,
         inbox: inbox
       } do
    owner = self()

    sink =
      spawn(fn ->
        receive do
          :drain -> forward_sink(owner)
        end
      end)

    on_exit(fn -> if Process.alive?(sink), do: Process.exit(sink, :kill) end)
    send(sink, :occupied)
    slow = Map.merge(context, %{subscriber: sink, max_subscriber_queue: 1})
    assert {:ok, attached} = execute(slow, "subscription.attach", pages_payload())
    id = attached.payload["subscriptionId"]
    pid = relay(id)
    old = snapshot(inbox)
    send(pid, {:async_interactions_updated, old})
    assert :sys.get_state(pid).async_blocked?
    send(sink, :drain)
    assert_receive {:async_sink, :occupied}
    assert_receive {:async_sink, {:sigma_protocol, ^id, %{type: "session.error"}}}
    payload = Map.put(pages_payload(), "subscriptionId", id)

    failed =
      Map.put(slow, :async_interaction_snapshot, fn _ -> {:ok, %{items: [%{}], leaf_id: nil}} end)

    assert {:error, _} = execute(failed, "session.status", payload)
    assert :sys.get_state(pid).async_blocked?
    Agent.update(inbox, &%{&1 | leaf_id: "another-leaf"})
    assert {:ok, refreshed} = execute(slow, "session.status", payload)
    refute :sys.get_state(pid).async_blocked?
    # A queued earlier notification is only an invalidation hint. Queries use the current view.
    send(pid, {:async_interactions_updated, old})

    assert_receive {:async_sink,
                    {:sigma_protocol, ^id, %{type: "async_interactions.changed"} = hint}}

    refute hint.payload["inbox"] == refreshed.payload["asyncInteractionInbox"]

    assert {:error, %{error: %{code: "async_inbox_stale"}}} =
             execute(slow, "async_interactions.list", page_request(hint.payload["inbox"]))
  end

  test "paged revisions follow Writer branches and remain stable on the same durable view after restart",
       %{
         context: context,
         agent: original_agent
       } do
    real =
      Map.drop(context, [
        :async_interaction_snapshot,
        :reply_async_interaction,
        :dismiss_async_interaction
      ])

    writer = Runtime.lookup(context.repo_path, @session, :writer)

    user =
      Sigma.Agent.Message.user("first", "First branch") |> Map.put(:metadata, %{turn_id: "run"})

    assert {:ok, first_leaf} = Writer.append(writer, {:message_end, user})

    first =
      received()
      |> Map.delete("questions")
      |> Map.put("message", "Branch notice")
      |> put_in(["origin", "tool_name"], "send_message_to_user_async")
      |> put_in(["origin", "branch_entry_id"], first_leaf)

    assert {:ok, _} = Writer.append_async_interaction(writer, first, first_leaf)
    assert {:ok, first_status} = execute(real, "session.status", pages_payload())
    descriptor = first_status.payload["asyncInteractionInbox"]
    assert descriptor["leafId"] == first_leaf
    assert descriptor["itemCount"] == 1
    before_card = paged_card(real, descriptor, "item", 0)

    assert :ok = Writer.checkout(writer, nil, first_leaf)

    user =
      Sigma.Agent.Message.user("second", "Second branch")
      |> Map.put(:metadata, %{turn_id: "second-run"})

    assert {:ok, second_leaf} = Writer.append(writer, {:message_end, user})

    second =
      %{first | "event_id" => "second", "item_id" => "second"}
      |> put_in(["origin", "branch_entry_id"], second_leaf)
      |> put_in(["origin", "run_id"], "second-run")

    assert {:ok, _} = Writer.append_async_interaction(writer, second, second_leaf)

    assert {:error, %{error: %{code: "async_inbox_stale"}}} =
             execute(real, "async_interactions.list", page_request(descriptor))

    assert {:ok, second_status} = execute(real, "session.status", pages_payload())

    assert Enum.map(
             paged_summaries(real, second_status.payload["asyncInteractionInbox"], 0),
             & &1["itemId"]
           ) == ["second"]

    assert :ok = Writer.checkout(writer, first_leaf, second_leaf)
    assert {:ok, restored} = execute(real, "session.status", pages_payload())
    assert restored.payload["asyncInteractionInbox"] == descriptor

    # Checkout selects Writer's next append parent; an ordinary append makes
    # that selected branch the durable default used by a later resume.
    assert {:ok, _} =
             Writer.append(
               writer,
               {:message_end, Sigma.Agent.Message.user("selected", "Keep first branch")}
             )

    assert {:ok, selected} = execute(real, "session.status", pages_payload())
    selected_descriptor = selected.payload["asyncInteractionInbox"]

    supervisor = Runtime.lookup(context.repo_path, :supervisor)
    assert :ok = DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, supervisor)
    refute Process.alive?(original_agent)
    assert {:ok, reopened} = execute(real, "session.resume", pages_payload())
    refute Runtime.lookup(context.repo_path, @session, :agent) == original_agent
    reopened_descriptor = reopened.payload["asyncInteractionInbox"]
    assert reopened_descriptor["itemCount"] == 1
    assert reopened_descriptor == selected_descriptor
    assert paged_card(real, reopened_descriptor, "item", 0) == before_card
  end

  defp pages_payload, do: %{"requiredCapabilities" => [@pages]}

  defp page_request(descriptor),
    do: Map.put(pages_payload(), "expectedRevision", descriptor["revision"])

  defp paged_summaries(context, descriptor, offset) do
    payload = Map.merge(page_request(descriptor), %{"offset" => offset, "limit" => 50})
    assert {:ok, event} = execute(context, "async_interactions.list", payload)
    assert {:ok, _} = Codec.encode(event)

    case event.payload["nextOffset"] do
      nil -> event.payload["items"]
      next -> event.payload["items"] ++ paged_summaries(context, descriptor, next)
    end
  end

  defp paged_card(context, descriptor, id, offset) do
    payload = Map.merge(page_request(descriptor), %{"itemId" => id, "byteOffset" => offset})
    assert {:ok, event} = execute(context, "async_interaction.read", payload)
    assert {:ok, _} = Codec.encode(event)
    bytes = Base.decode64!(event.payload["data"])

    case event.payload["nextByteOffset"] do
      nil -> bytes
      next -> bytes <> paged_card(context, descriptor, id, next)
    end
  end

  defp replace_many(inbox, count, large? \\ false) do
    projection =
      Enum.reduce(1..count, AsyncInteractions.new(), fn index, state ->
        id = if index == 1, do: "item", else: "item-#{index}"
        event = %{received() | "event_id" => "received:#{id}", "item_id" => id}

        event =
          if large? and index == 1 do
            Map.put(
              event,
              "questions",
              for(i <- 1..3, do: %{"title" => String.duplicate("题", 8_000) <> "\n#{i}"})
            )
          else
            event
          end

        assert {:ok, updated} = AsyncInteractions.apply_event(state, event)
        updated
      end)

    Agent.update(inbox, &%{&1 | projection: projection})
  end

  defp execute(context, type, payload, session_id \\ @session) do
    assert {:ok, command} = Envelope.command(type, session_id, payload)
    PublicRuntime.execute(command, context)
  end

  defp forward_sink(owner) do
    receive do
      {:sync, ref} -> send(owner, {:async_sink_synced, ref})
      message -> send(owner, {:async_sink, message})
    end

    forward_sink(owner)
  end

  defp sync_sink(sink) do
    ref = make_ref()
    send(sink, {:sync, ref})
    assert_receive {:async_sink_synced, ^ref}
  end

  defp snapshot(inbox) do
    Agent.get(inbox, fn state ->
      items = state.projection.items |> Map.values() |> Enum.sort_by(& &1["sequence"])
      items = Enum.map(items, &Map.put(&1, "can_reply", &1["status"] in ~w(open notice saved)))
      %{items: items, leaf_id: state.leaf_id}
    end)
  end

  defp mutate(inbox, id, leaf, callback) do
    Agent.get_and_update(inbox, fn state ->
      result =
        with true <- leaf == state.leaf_id,
             {:ok, item} <- Map.fetch(state.projection.items, id),
             {:ok, fact, reply} <- callback.(item),
             {:ok, projection} <- AsyncInteractions.apply_event(state.projection, fact) do
          {reply, %{state | projection: projection}}
        else
          false -> {{:error, :leaf_conflict}, state}
          {:error, _} = error -> {error, state}
          _ -> {{:error, :invalid_async_reply}, state}
        end

      result
    end)
  end

  defp capable_payload, do: %{"requiredCapabilities" => [@capability]}

  defp command_payload(reply \\ reply_payload()),
    do:
      Map.merge(capable_payload(), %{
        "itemId" => "item",
        "expectedLeafId" => "anchor",
        "reply" => reply
      })

  defp reply_payload,
    do: %{
      "replyId" => "reply",
      "answers" => [
        %{"questionIndex" => 0, "answer" => "  原文\n"},
        %{"questionIndex" => 1, "answer" => " freeform answer "}
      ]
    }

  defp received do
    %{
      "version" => 1,
      "fact" => "received",
      "event_id" => "received",
      "item_id" => "item",
      "session_id" => @session,
      "origin" => %{
        "run_id" => "run",
        "incarnation" => 1,
        "turn_id" => "turn",
        "step_id" => "step",
        "attempt_id" => "attempt",
        "invocation_id" => "invocation",
        "tool_call_id" => "call",
        "tool_name" => "request_user_input_async",
        "branch_entry_id" => "anchor"
      },
      "questions" => [
        %{"title" => "Continue?", "options" => ["A", "B"]},
        %{"title" => "Details?"}
      ]
    }
  end

  defp relay(subscription) do
    [{pid, _}] = Registry.lookup(Sigma.Agent.ProtocolSubscriptionRegistry, subscription)
    pid
  end

  defp receive_type(subscription, type) do
    receive do
      {:sigma_protocol, ^subscription, %{type: ^type} = event} ->
        assert {:ok, _} = Codec.encode(event)
        event

      {:sigma_protocol, ^subscription, _} ->
        receive_type(subscription, type)
    after
      1_000 -> flunk("timed out waiting for #{type}")
    end
  end
end
