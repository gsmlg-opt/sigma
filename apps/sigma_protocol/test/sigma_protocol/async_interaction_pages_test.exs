defmodule Sigma.Protocol.AsyncInteractionPagesTest do
  use ExUnit.Case, async: true

  alias Sigma.Protocol.{AsyncInteractionPages, AsyncInteractions, Codec, Envelope}

  test "empty selected view has a deterministic JSON revision and an empty terminal page" do
    snapshot = %{items: [], leaf_id: nil}

    assert {:ok, descriptor} = AsyncInteractionPages.descriptor(snapshot, "session")

    assert descriptor == %{
             "version" => 1,
             "revision" => sha256(~s({"items":[],"leafId":null})),
             "leafId" => nil,
             "itemCount" => 0
           }

    page = list!(snapshot, %{"expectedRevision" => descriptor["revision"]})

    assert page.payload == %{
             "inbox" => descriptor,
             "offset" => 0,
             "nextOffset" => nil,
             "items" => []
           }
  end

  test "more than 2051 cards page once each in selected order through the actual wire codec" do
    snapshot = snapshot!(2_053)
    assert {:ok, descriptor} = AsyncInteractionPages.descriptor(snapshot, "session")
    assert descriptor["itemCount"] == 2_053

    summaries = pages!(snapshot, descriptor["revision"], 0)
    assert Enum.map(summaries, & &1["itemId"]) == Enum.map(snapshot.items, & &1["item_id"])
    assert Enum.map(summaries, & &1["sequence"]) == Enum.to_list(1..2_053)
    assert length(Enum.uniq_by(summaries, & &1["itemId"])) == 2_053

    for summary <- summaries do
      assert Enum.sort(Map.keys(summary)) ==
               Enum.sort(~w(itemId sequence kind status canReply byteLength sha256))

      assert summary["kind"] == "questions"
      assert summary["status"] == "open"
      assert summary["canReply"]
      assert summary["byteLength"] > 0
      assert Regex.match?(~r/\A[0-9a-f]{64}\z/, summary["sha256"])
    end
  end

  test "large complete replies reassemble exact ordered JSON bytes including UTF-8 and newlines" do
    questions =
      for index <- 0..2,
          do: %{"title" => String.duplicate("题", 8_000) <> "\"\\\n#{index}"}

    event = Map.put(received("large-card"), "questions", questions)
    assert {:ok, state} = AsyncInteractions.apply_event(AsyncInteractions.new(), event)
    item = state.items["large-card"]

    answers =
      for index <- 0..2,
          do: %{"questionIndex" => index, "answer" => "  答案 #{index}\n\"\\原文  "}

    assert {:ok, reply} =
             AsyncInteractions.reply(%{"replyId" => "reply", "answers" => answers}, item)

    assert {:ok, saved} = AsyncInteractions.fact(item, "reply_saved", %{"reply" => reply})
    assert {:ok, state} = AsyncInteractions.apply_event(state, saved)
    card = Map.put(state.items["large-card"], "can_reply", true)
    snapshot = %{items: [card], leaf_id: "leaf"}
    assert {:ok, descriptor} = AsyncInteractionPages.descriptor(snapshot, "session")
    revision = descriptor["revision"]
    page = list!(snapshot, %{"expectedRevision" => revision})
    assert [summary] = page.payload["items"]
    assert summary["byteLength"] > 65_536

    bytes = chunks!(snapshot, revision, "large-card", 0, summary)
    assert byte_size(bytes) == summary["byteLength"]
    assert sha256(bytes) == summary["sha256"]
    assert Jason.decode!(bytes) == card
    assert_sorted_objects!(Jason.decode!(bytes, objects: :ordered_objects))

    request = %{"expectedRevision" => revision, "itemId" => "large-card"}
    first = read!(snapshot, request)
    assert read!(snapshot, request).payload == first.payload
    assert first.payload["byteOffset"] == 0
    assert byte_size(Base.decode64!(first.payload["data"])) == 12_288

    terminal = read!(snapshot, Map.put(request, "byteOffset", byte_size(bytes)))
    assert terminal.payload["data"] == ""
    assert terminal.payload["nextByteOffset"] == nil
  end

  test "revisions cover exact cards and leaf while unrelated global history does not change the view" do
    snapshot = snapshot!(2)
    assert {:ok, descriptor} = AsyncInteractionPages.descriptor(snapshot, "session")

    unrelated = Map.put(snapshot, :global_receipts, %{sibling: "another fact"})
    assert {:ok, ^descriptor} = AsyncInteractionPages.descriptor(unrelated, "session")

    reordered = %{snapshot | items: Enum.map(snapshot.items, &reverse_map_order/1)}
    assert {:ok, ^descriptor} = AsyncInteractionPages.descriptor(reordered, "session")

    first = hd(snapshot.items)

    dismissed =
      first
      |> Map.put("status", "dismissed")
      |> Map.put("reason", "done")
      |> Map.put("can_reply", false)

    changed_text = put_in(first, ["questions", Access.at(0), "title"], "Changed question")

    for changed <- [
          %{snapshot | leaf_id: "other-leaf"},
          %{snapshot | items: [dismissed | tl(snapshot.items)]},
          %{snapshot | items: [changed_text | tl(snapshot.items)]},
          %{snapshot | items: [Map.put(first, "can_reply", false) | tl(snapshot.items)]},
          %{snapshot | items: Enum.reverse(snapshot.items)}
        ] do
      assert {:ok, updated} = AsyncInteractionPages.descriptor(changed, "session")
      refute updated["revision"] == descriptor["revision"]
      request = %{"expectedRevision" => descriptor["revision"]}

      assert {:error, :async_inbox_stale} =
               AsyncInteractionPages.list(changed, "session", request)

      assert {:error, :async_inbox_stale} =
               AsyncInteractionPages.read(
                 changed,
                 "session",
                 Map.put(request, "itemId", first["item_id"])
               )
    end

    assert {:ok, state} =
             AsyncInteractions.apply_event(AsyncInteractions.new(), received("delivery"))

    item = state.items["delivery"]

    assert {:ok, reply} =
             AsyncInteractions.reply(
               %{
                 "replyId" => "delivery-reply",
                 "answers" => [%{"questionIndex" => 0, "answer" => "A"}]
               },
               item
             )

    state =
      Enum.reduce(
        [
          {"reply_saved", %{"reply" => reply}},
          {"dispatch_started", %{"reply_id" => reply["reply_id"]}},
          {"admitted", %{"reply_id" => reply["reply_id"]}}
        ],
        state,
        fn {name, attrs}, current ->
          assert {:ok, fact} = AsyncInteractions.fact(item, name, attrs)
          assert {:ok, updated} = AsyncInteractions.apply_event(current, fact)
          updated
        end
      )

    card = Map.put(state.items["delivery"], "can_reply", false)
    before_delivery = %{items: [card], leaf_id: "leaf"}
    assert {:ok, before_descriptor} = AsyncInteractionPages.descriptor(before_delivery, "session")

    assert {:ok, fact} =
             AsyncInteractions.fact(item, "runtime_admitted", %{
               "reply_id" => reply["reply_id"],
               "run_id" => "destination",
               "runtime_message_id" => "runtime-message"
             })

    assert {:ok, updated} = AsyncInteractions.apply_event(state, fact)

    with_delivery = %{
      before_delivery
      | items: [Map.put(updated.items["delivery"], "can_reply", false)]
    }

    assert hd(with_delivery.items)["status"] == card["status"]
    assert {:ok, after_descriptor} = AsyncInteractionPages.descriptor(with_delivery, "session")
    refute after_descriptor["revision"] == before_descriptor["revision"]

    assert {:error, :async_inbox_stale} =
             AsyncInteractionPages.read(with_delivery, "session", %{
               "expectedRevision" => before_descriptor["revision"],
               "itemId" => "delivery"
             })
  end

  test "list defaults and common routing fields are strict and repeatable" do
    snapshot = snapshot!(23)
    assert {:ok, descriptor} = AsyncInteractionPages.descriptor(snapshot, "session")

    request = %{
      "expectedRevision" => descriptor["revision"],
      "requiredCapabilities" => ["async_interactions.pages.v1"],
      "repoPath" => "/repo",
      "sessionsDir" => "/sessions"
    }

    page = list!(snapshot, request)
    assert length(page.payload["items"]) == 20
    assert page.payload["nextOffset"] == 20
    assert list!(snapshot, request).payload == page.payload

    terminal = list!(snapshot, Map.merge(request, %{"offset" => 23, "limit" => 1}))
    assert terminal.payload["items"] == []
    assert terminal.payload["nextOffset"] == nil

    for invalid <- [
          %{},
          Map.put(request, "expectedRevision", nil),
          Map.put(request, "expectedRevision", "short"),
          Map.put(request, "expectedRevision", String.duplicate("A", 64)),
          Map.put(request, "offset", -1),
          Map.put(request, "offset", 24),
          Map.put(request, "offset", 1.0),
          Map.put(request, "offset", "0"),
          Map.put(request, "limit", 0),
          Map.put(request, "limit", 51),
          Map.put(request, "limit", nil),
          Map.put(request, "limit", true),
          Map.put(request, "itemId", "unexpected"),
          Map.put(request, :offset, 0),
          []
        ] do
      assert {:error, :invalid_async_page} =
               AsyncInteractionPages.list(snapshot, "session", invalid)
    end
  end

  test "read rejects invalid scopes and offsets without returning partial or foreign cards" do
    snapshot = snapshot!(1)
    assert {:ok, descriptor} = AsyncInteractionPages.descriptor(snapshot, "session")
    request = %{"expectedRevision" => descriptor["revision"], "itemId" => "item-1"}
    first = read!(snapshot, request)

    for invalid <- [
          %{},
          Map.delete(request, "itemId"),
          Map.put(request, "itemId", ""),
          Map.put(request, "itemId", <<255>>),
          Map.put(request, "expectedRevision", "bad"),
          Map.put(request, "byteOffset", -1),
          Map.put(request, "byteOffset", first.payload["byteLength"] + 1),
          Map.put(request, "byteOffset", 0.0),
          Map.put(request, "byteOffset", nil),
          Map.put(request, "byteOffset", "0"),
          Map.put(request, "limit", 10),
          Map.put(request, "extra", true),
          []
        ] do
      assert {:error, :invalid_async_page} =
               AsyncInteractionPages.read(snapshot, "session", invalid)
    end

    assert {:error, :async_item_not_found} =
             AsyncInteractionPages.read(snapshot, "session", Map.put(request, "itemId", "absent"))

    assert {:error, :async_payload_rejected} =
             AsyncInteractionPages.descriptor(snapshot, "foreign")

    assert {:error, :async_payload_rejected} =
             AsyncInteractionPages.list(
               snapshot,
               "foreign",
               Map.take(request, ["expectedRevision"])
             )

    assert {:error, :async_payload_rejected} =
             AsyncInteractionPages.read(snapshot, "foreign", request)

    malformed = %{snapshot | items: [Map.put(hd(snapshot.items), "callback", "private")]}

    assert {:error, :async_payload_rejected} =
             AsyncInteractionPages.descriptor(malformed, "session")
  end

  test "message summaries distinguish optional notifications from questions" do
    event =
      received("notice")
      |> Map.delete("questions")
      |> Map.put("message", "  Progress\n原文")
      |> put_in(["origin", "tool_name"], "send_message_to_user_async")

    assert {:ok, state} = AsyncInteractions.apply_event(AsyncInteractions.new(), event)
    snapshot = %{items: [Map.put(state.items["notice"], "can_reply", true)], leaf_id: "leaf"}
    assert {:ok, descriptor} = AsyncInteractionPages.descriptor(snapshot, "session")
    page = list!(snapshot, %{"expectedRevision" => descriptor["revision"]})

    assert [%{"kind" => "message", "status" => "notice", "canReply" => true}] =
             page.payload["items"]
  end

  test "malformed replies and card shapes return typed projection errors at every page boundary" do
    snapshot = snapshot!(1)
    assert hd(snapshot.items)["reply"] == nil
    assert {:ok, _} = AsyncInteractions.project(snapshot, "session")
    assert {:ok, descriptor} = AsyncInteractionPages.descriptor(snapshot, "session")
    list_request = %{"expectedRevision" => descriptor["revision"]}
    read_request = Map.put(list_request, "itemId", "item-1")
    assert list!(snapshot, list_request).payload["items"] != []
    assert read!(snapshot, read_request).payload["data"] != ""

    invalid_replies =
      for reply <- ["bad", 123, ["bad"], %URI{scheme: "https"}] do
        %{snapshot | items: [Map.put(hd(snapshot.items), "reply", reply)]}
      end

    invalid_snapshots =
      invalid_replies ++
        [
          %{snapshot | items: [%URI{scheme: "https"}]},
          %{snapshot | items: nil},
          %{snapshot | leaf_id: 123},
          %{},
          nil
        ]

    for invalid <- invalid_snapshots do
      assert {:error, :async_payload_rejected} = AsyncInteractions.project(invalid, "session")

      assert {:error, :async_payload_rejected} =
               AsyncInteractionPages.descriptor(invalid, "session")

      assert {:error, :async_payload_rejected} =
               AsyncInteractionPages.list(invalid, "session", list_request)

      assert {:error, :async_payload_rejected} =
               AsyncInteractionPages.read(invalid, "session", read_request)
    end
  end

  test "the shared request validator checks exact command names and leaves upper bounds to the view" do
    revision = String.duplicate("a", 64)
    list_request = %{"expectedRevision" => revision, "offset" => 99_999, "limit" => 50}
    read_request = %{"expectedRevision" => revision, "itemId" => "item", "byteOffset" => 99_999}
    assert :ok = AsyncInteractionPages.validate_request("async_interactions.list", list_request)
    assert :ok = AsyncInteractionPages.validate_request("async_interaction.read", read_request)

    for {type, invalid} <- [
          {"async_interaction.list", list_request},
          {"async_interactions.read", read_request},
          {"async_interactions.list",
           Map.put(list_request, "requiredCapabilities", "not-a-list")},
          {"async_interaction.read", Map.put(read_request, "repoPath", false)},
          {"async_interaction.read", Map.put(read_request, "sessionsDir", nil)},
          {"async_interactions.list", Map.put(list_request, "requiredCapabilities", [<<255>>])}
        ] do
      assert {:error, :invalid_async_page} = AsyncInteractionPages.validate_request(type, invalid)
    end
  end

  test "control-byte identities force adaptive page shrink using the complete encoded envelope" do
    snapshot =
      snapshot!(50, fn index -> String.duplicate(<<1>>, 480) <> Integer.to_string(index) end)

    assert {:ok, descriptor} = AsyncInteractionPages.descriptor(snapshot, "session")
    request = %{"expectedRevision" => descriptor["revision"], "limit" => 50}
    first = list!(snapshot, request)
    assert length(first.payload["items"]) in 1..49
    assert first.payload["nextOffset"] == length(first.payload["items"])

    all = pages!(snapshot, descriptor["revision"], 0)
    assert Enum.map(all, & &1["itemId"]) == Enum.map(snapshot.items, & &1["item_id"])

    assert {:ok, failed_descriptor} =
             AsyncInteractionPages.descriptor(%{items: [], leaf_id: nil}, "session")

    assert {:error, reason} =
             AsyncInteractionPages.list(
               %{items: [], leaf_id: nil},
               String.duplicate("s", 70_000),
               %{
                 "expectedRevision" => failed_descriptor["revision"]
               }
             )

    assert is_atom(reason)
  end

  defp list!(snapshot, request) do
    assert {:ok, %Envelope{type: "async_interactions.page"} = event} =
             AsyncInteractionPages.list(snapshot, "session", request)

    wire!(event)
  end

  defp read!(snapshot, request) do
    assert {:ok, %Envelope{type: "async_interaction.chunk"} = event} =
             AsyncInteractionPages.read(snapshot, "session", request)

    wire!(event)
  end

  defp wire!(event) do
    assert {:ok, encoded} = Codec.encode(event)
    assert byte_size(encoded) <= 65_536
    assert {:ok, decoded} = Codec.decode(encoded)
    assert decoded == event
    decoded
  end

  defp pages!(snapshot, revision, offset) do
    page = list!(snapshot, %{"expectedRevision" => revision, "offset" => offset, "limit" => 50})
    assert page.payload["offset"] == offset
    items = page.payload["items"]

    case page.payload["nextOffset"] do
      nil ->
        items

      next ->
        assert items != []
        assert next == offset + length(items)
        items ++ pages!(snapshot, revision, next)
    end
  end

  defp chunks!(snapshot, revision, item_id, offset, summary) do
    chunk =
      read!(snapshot, %{
        "expectedRevision" => revision,
        "itemId" => item_id,
        "byteOffset" => offset
      })

    payload = chunk.payload
    assert payload["encoding"] == "base64-json"
    assert payload["itemId"] == item_id
    assert payload["sha256"] == summary["sha256"]
    assert payload["byteLength"] == summary["byteLength"]
    assert payload["byteOffset"] == offset
    bytes = Base.decode64!(payload["data"])
    assert byte_size(bytes) <= 12_288

    case payload["nextByteOffset"] do
      nil ->
        bytes

      next ->
        assert byte_size(bytes) == 12_288
        assert next == offset + byte_size(bytes)
        bytes <> chunks!(snapshot, revision, item_id, next, summary)
    end
  end

  defp snapshot!(count, id_fn \\ &"item-#{&1}") do
    state =
      Enum.reduce(1..count, AsyncInteractions.new(), fn index, state ->
        assert {:ok, updated} = AsyncInteractions.apply_event(state, received(id_fn.(index)))
        updated
      end)

    %{
      items:
        Enum.map(AsyncInteractions.snapshot(state, ["anchor"]), &Map.put(&1, "can_reply", true)),
      leaf_id: "leaf"
    }
  end

  defp received(id) do
    %{
      "version" => 1,
      "fact" => "received",
      "event_id" => "received:#{id}",
      "item_id" => id,
      "session_id" => "session",
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
      "questions" => [%{"title" => "Continue?", "options" => ["A", "B"]}]
    }
  end

  defp reverse_map_order(value) when is_map(value),
    do: value |> Enum.reverse() |> Map.new(fn {key, item} -> {key, reverse_map_order(item)} end)

  defp reverse_map_order(value) when is_list(value), do: Enum.map(value, &reverse_map_order/1)
  defp reverse_map_order(value), do: value

  defp assert_sorted_objects!(%Jason.OrderedObject{values: values}) do
    keys = Enum.map(values, &elem(&1, 0))
    assert keys == Enum.sort(keys)
    Enum.each(values, fn {_key, value} -> assert_sorted_objects!(value) end)
  end

  defp assert_sorted_objects!(values) when is_list(values),
    do: Enum.each(values, &assert_sorted_objects!/1)

  defp assert_sorted_objects!(_), do: :ok

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
