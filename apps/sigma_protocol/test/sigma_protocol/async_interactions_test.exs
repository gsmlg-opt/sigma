defmodule Sigma.Protocol.AsyncInteractionsTest do
  use ExUnit.Case, async: true

  alias Sigma.Protocol.AsyncInteractions

  test "received cards preserve a complete ordered batch and JSON identity" do
    event = received()
    assert {:ok, normalized} = AsyncInteractions.event(event)
    assert AsyncInteractions.to_map(normalized) == event
    assert Jason.decode!(Jason.encode!(normalized)) == event
    assert {:ok, state} = AsyncInteractions.apply_event(AsyncInteractions.new(), event)
    assert [item] = AsyncInteractions.snapshot(state, ["anchor"])
    assert item["questions"] == event["questions"]
    assert item["status"] == "open"
    assert item["reply"] == nil
  end

  test "duplicate events are idempotent and conflicting event or item identities fail" do
    event = received()
    assert {:ok, state} = AsyncInteractions.apply_event(AsyncInteractions.new(), event)
    assert {:ok, ^state} = AsyncInteractions.apply_event(state, event)

    conflict = put_in(event, ["questions", Access.at(0), "title"], "Changed")
    assert {:error, _} = AsyncInteractions.apply_event(state, conflict)
    assert {:error, _} = AsyncInteractions.apply_event(state, %{conflict | "event_id" => "other"})
  end

  test "same question content from distinct calls stays separate and sibling cards are hidden" do
    first = received()
    second = received("item-2", "sibling")
    assert {:ok, state} = AsyncInteractions.apply_event(AsyncInteractions.new(), first)
    assert {:ok, state} = AsyncInteractions.apply_event(state, second)
    assert [item] = AsyncInteractions.snapshot(state, ["anchor"])
    assert item["item_id"] == "item-1"
    assert length(AsyncInteractions.snapshot(state, ["anchor", "sibling"])) == 2
    assert AsyncInteractions.snapshot(state, []) == []
  end

  test "strict bounds reject malformed or oversized data without truncation" do
    for event <- [
          Map.put(received(), "callback", "private"),
          put_in(received(), ["origin", "token"], "private"),
          put_in(received(), ["origin", "invocation_id"], ""),
          put_in(received(), ["origin", "incarnation"], 0),
          put_in(received(), ["questions", Access.at(0), "title"], <<255>>),
          put_in(received(), ["questions", Access.at(0), "title"], String.duplicate("x", 32_769)),
          put_in(received(), ["questions", Access.at(0), "options"], []),
          put_in(received(), ["questions", Access.at(0), "options"], [self()]),
          Map.put(received(), "questions", [])
        ] do
      assert {:error, _} = AsyncInteractions.event(event)
    end
  end

  test "long-lived inbox replay retains closed cards and receipts beyond lifetime ceilings" do
    {state, reversed_events} =
      Enum.reduce(1..2_049, {AsyncInteractions.new(), []}, fn index, {state, events} ->
        received = received("closed-#{index}")
        assert {:ok, state} = AsyncInteractions.apply_event(state, received)
        item = state.items[received["item_id"]]
        assert {:ok, dismissed} = AsyncInteractions.fact(item, "dismissed", %{"reason" => "done"})
        assert {:ok, state} = AsyncInteractions.apply_event(state, dismissed)
        {state, [dismissed, received | events]}
      end)

    open = received("still-open")
    sibling = received("sibling-card", "sibling")
    events = Enum.reverse(reversed_events) ++ [open, sibling]

    replayed =
      Enum.reduce(events, AsyncInteractions.new(), fn event, projection ->
        assert {:ok, updated} = AsyncInteractions.apply_event(projection, event)
        updated
      end)

    assert {:ok, state} = AsyncInteractions.apply_event(state, open)
    assert {:ok, state} = AsyncInteractions.apply_event(state, sibling)
    assert replayed == state
    assert map_size(state.items) == 2_051
    assert map_size(state.events) == 4_100
    assert length(AsyncInteractions.snapshot(state, ["anchor"])) == 2_050
    assert [sibling_item] = AsyncInteractions.snapshot(state, ["sibling"])
    assert sibling_item["item_id"] == "sibling-card"
    assert state.items["closed-1"]["status"] == "dismissed"
    assert state.items["still-open"]["status"] == "open"
    assert {:ok, ^state} = AsyncInteractions.apply_event(state, received("closed-1"))

    conflict = put_in(received("closed-1"), ["questions", Access.at(0), "title"], "Changed")
    assert {:error, :async_interaction_conflict} = AsyncInteractions.apply_event(state, conflict)

    payload = %{
      "replyId" => "late-reply",
      "answers" => [%{"questionIndex" => 0, "answer" => "A"}]
    }

    assert {:ok, reply} = AsyncInteractions.reply(payload, state.items["still-open"])

    assert {:ok, saved} =
             AsyncInteractions.fact(state.items["still-open"], "reply_saved", %{"reply" => reply})

    assert {:ok, saved_state} = AsyncInteractions.apply_event(state, saved)
    assert saved_state.items["still-open"]["status"] == "saved"
  end

  test "complete long question titles leave room for every ordered answer" do
    three_questions =
      for index <- 0..2,
          do: %{"title" => String.duplicate("q", 32_767) <> Integer.to_string(index)}

    full_batch =
      for index <- 0..31,
          do: %{"title" => String.duplicate("q", 3_100) <> Integer.to_string(index)}

    for questions <- [three_questions, full_batch] do
      event = Map.put(received(), "questions", questions)
      assert {:ok, state} = AsyncInteractions.apply_event(AsyncInteractions.new(), event)
      item = state.items["item-1"]

      answers =
        questions
        |> Enum.with_index()
        |> Enum.map(fn {_question, index} ->
          %{"questionIndex" => index, "answer" => "  答#{index}\n"}
        end)

      payload = %{"replyId" => "long-reply", "answers" => answers}
      assert {:ok, reply} = AsyncInteractions.reply(payload, item)

      expected =
        Enum.zip(questions, answers)
        |> Enum.map_join("\n\n", fn {question, answer} ->
          question["title"] <> "\nAnswer:\n" <> answer["answer"]
        end)

      assert reply["content"] == "Reply to async questions item-1:\n" <> expected
      assert {:ok, saved} = AsyncInteractions.fact(item, "reply_saved", %{"reply" => reply})
      assert {:ok, saved_state} = AsyncInteractions.apply_event(state, saved)
      assert saved_state.items["item-1"]["reply"] == reply
      assert {:ok, ^reply} = AsyncInteractions.reply(payload, saved_state.items["item-1"])
    end
  end

  test "larger reply envelopes retain bounded answers and reject oversized received cards" do
    questions = for _ <- 1..4, do: %{"title" => "Question"}
    event = Map.put(received(), "questions", questions)
    assert {:ok, state} = AsyncInteractions.apply_event(AsyncInteractions.new(), event)

    answers =
      for index <- 0..3,
          do: %{"questionIndex" => index, "answer" => String.duplicate("a", 32_768)}

    assert {:error, :invalid_async_reply} =
             AsyncInteractions.reply(
               %{"replyId" => "too-large", "answers" => answers},
               state.items["item-1"]
             )

    escaped_answers =
      for index <- 0..3,
          do: %{"questionIndex" => index, "answer" => String.duplicate("\"", 24_000)}

    assert {:error, :invalid_async_reply} =
             AsyncInteractions.reply(
               %{"replyId" => "too-large-json", "answers" => escaped_answers},
               state.items["item-1"]
             )

    oversized =
      Map.put(
        event,
        "questions",
        for(_ <- 1..5, do: %{"title" => String.duplicate("q", 32_768)})
      )

    assert {:error, :invalid_async_interaction} = AsyncInteractions.event(oversized)
  end

  test "Runtime admission records exact delivery identity without changing acknowledgement state" do
    for status <- ["dispatching", "admitted", "delivery_unknown"] do
      assert {:ok, state} = AsyncInteractions.apply_event(AsyncInteractions.new(), received())
      item = state.items["item-1"]

      payload = %{
        "replyId" => "reply-1",
        "answers" => [%{"questionIndex" => 0, "answer" => "A"}]
      }

      assert {:ok, reply} = AsyncInteractions.reply(payload, item)

      assert {:ok, state} =
               AsyncInteractions.apply_event(state, fact("reply_saved", %{"reply" => reply}))

      assert {:ok, state} =
               AsyncInteractions.apply_event(
                 state,
                 fact("dispatch_started", %{"reply_id" => "reply-1"})
               )

      state =
        case status do
          "dispatching" ->
            state

          "admitted" ->
            assert {:ok, updated} =
                     AsyncInteractions.apply_event(
                       state,
                       fact("admitted", %{"reply_id" => "reply-1"})
                     )

            updated

          "delivery_unknown" ->
            assert {:ok, updated} =
                     AsyncInteractions.apply_event(
                       state,
                       fact("delivery_unknown", %{
                         "reply_id" => "reply-1",
                         "reason" => "lost acknowledgement"
                       })
                     )

            updated
        end

      attrs = %{
        "reply_id" => "reply-1",
        "run_id" => "delivery-run",
        "runtime_message_id" => "runtime-user"
      }

      assert {:ok, admission} = AsyncInteractions.fact(item, "runtime_admitted", attrs)
      assert {:ok, updated} = AsyncInteractions.apply_event(state, admission)
      assert updated.items["item-1"]["status"] == status
      assert updated.items["item-1"]["delivery"] == Map.take(attrs, ~w(run_id runtime_message_id))
      assert {:ok, ^updated} = AsyncInteractions.apply_event(updated, admission)

      duplicate = Map.put(admission, "event_id", "runtime-duplicate")
      assert {:ok, duplicate_state} = AsyncInteractions.apply_event(updated, duplicate)
      assert duplicate_state.items == updated.items

      for changes <- [
            %{"reply_id" => "wrong"},
            %{"run_id" => "wrong"},
            %{"runtime_message_id" => "wrong"}
          ] do
        assert {:ok, conflict} =
                 AsyncInteractions.fact(item, "runtime_admitted", Map.merge(attrs, changes))

        assert {:error, :async_interaction_conflict} =
                 AsyncInteractions.apply_event(updated, conflict)

        assert {:error, :async_interaction_conflict} =
                 AsyncInteractions.apply_event(
                   updated,
                   Map.put(conflict, "event_id", "runtime-conflict")
                 )
      end
    end
  end

  test "Runtime admission rejects malformed identity and cannot precede dispatch" do
    assert {:ok, state} = AsyncInteractions.apply_event(AsyncInteractions.new(), received())
    item = state.items["item-1"]

    attrs = %{
      "reply_id" => "reply-1",
      "run_id" => "delivery-run",
      "runtime_message_id" => "runtime-user"
    }

    assert {:ok, event} = AsyncInteractions.fact(item, "runtime_admitted", attrs)
    assert {:error, :async_interaction_conflict} = AsyncInteractions.apply_event(state, event)

    for field <- ~w(reply_id run_id runtime_message_id),
        value <- ["", String.duplicate("x", 513), 1] do
      assert {:error, :invalid_async_interaction} =
               AsyncInteractions.fact(item, "runtime_admitted", Map.put(attrs, field, value))
    end

    for field <- ~w(reply_id run_id runtime_message_id) do
      assert {:error, :invalid_async_interaction} =
               AsyncInteractions.fact(item, "runtime_admitted", Map.delete(attrs, field))
    end

    assert {:error, :invalid_async_interaction} =
             AsyncInteractions.fact(item, "runtime_admitted", Map.put(attrs, "extra", "private"))
  end

  test "reply validates all question indices and preserves free text exactly" do
    assert {:ok, state} = AsyncInteractions.apply_event(AsyncInteractions.new(), received())
    item = state.items["item-1"]

    payload = %{
      "replyId" => "reply-1",
      "answers" => [%{"questionIndex" => 0, "answer" => "  中文\n"}]
    }

    assert {:ok, reply} = AsyncInteractions.reply(payload, item)
    assert reply["content"] =~ "  中文\n"
    assert reply["metadata"]["async_interaction"]["item_id"] == "item-1"
    assert reply["metadata"]["async_interaction"]["reply_id"] == "reply-1"
    assert {:ok, ^reply} = AsyncInteractions.reply(payload, item)

    for invalid <- [
          Map.put(payload, "decision", "approved"),
          %{payload | "replyId" => ""},
          %{payload | "answers" => []},
          %{payload | "answers" => [%{"questionIndex" => 1, "answer" => "A"}]},
          %{payload | "answers" => [%{"questionIndex" => 0, "answer" => <<255>>}]},
          %{payload | "answers" => [%{"questionIndex" => 0, "answer" => " "}]}
        ] do
      assert {:error, _} = AsyncInteractions.reply(invalid, item)
    end
  end

  test "saved, admission and consumption are separate transitions; uncertainty never resubmits" do
    assert {:ok, state} = AsyncInteractions.apply_event(AsyncInteractions.new(), received())
    item = state.items["item-1"]

    assert {:ok, reply} =
             AsyncInteractions.reply(
               %{"replyId" => "reply-1", "answers" => [%{"questionIndex" => 0, "answer" => "A"}]},
               item
             )

    saved = fact("reply_saved", %{"reply" => reply})
    assert {:ok, state} = AsyncInteractions.apply_event(state, saved)
    assert state.items["item-1"]["status"] == "saved"

    assert {:ok, state} =
             AsyncInteractions.apply_event(
               state,
               fact("dispatch_started", %{"reply_id" => "reply-1"})
             )

    assert state.items["item-1"]["status"] == "dispatching"

    unknown =
      fact("delivery_unknown", %{"reply_id" => "reply-1", "reason" => "acknowledgement_lost"})

    assert {:ok, state} = AsyncInteractions.apply_event(state, unknown)
    assert state.items["item-1"]["status"] == "delivery_unknown"

    assert {:error, _} =
             AsyncInteractions.apply_event(
               state,
               fact("dispatch_started", %{"reply_id" => "different"})
             )

    assert {:ok, state} =
             AsyncInteractions.apply_event(state, fact("consumed", %{"reply_id" => "reply-1"}))

    assert state.items["item-1"]["status"] == "consumed"

    assert {:error, _} =
             AsyncInteractions.reply(
               %{"replyId" => "other", "answers" => []},
               state.items["item-1"]
             )
  end

  test "notification is not a required question but allows an optional new-user-message reply" do
    notice = received() |> Map.delete("questions") |> Map.put("message", "Working")
    notice = put_in(notice, ["origin", "tool_name"], "send_message_to_user_async")
    assert {:ok, state} = AsyncInteractions.apply_event(AsyncInteractions.new(), notice)
    assert state.items["item-1"]["status"] == "notice"

    assert {:ok, reply} =
             AsyncInteractions.reply(
               %{"replyId" => "optional", "text" => "Please continue"},
               state.items["item-1"]
             )

    assert reply["content"] =~ "Please continue"

    assert {:error, _} =
             AsyncInteractions.reply(
               %{"replyId" => "optional", "answers" => []},
               state.items["item-1"]
             )
  end

  test "dismissal rejects late answers and wrong-session facts" do
    assert {:ok, state} = AsyncInteractions.apply_event(AsyncInteractions.new(), received())

    assert {:error, _} =
             AsyncInteractions.apply_event(state, %{
               fact("dismissed", %{"reason" => "cancelled"})
               | "session_id" => "other"
             })

    assert {:ok, state} =
             AsyncInteractions.apply_event(state, fact("dismissed", %{"reason" => "cancelled"}))

    assert state.items["item-1"]["status"] == "dismissed"

    assert {:error, _} =
             AsyncInteractions.reply(
               %{"replyId" => "late", "answers" => [%{"questionIndex" => 0, "answer" => "A"}]},
               state.items["item-1"]
             )
  end

  defp received(item_id \\ "item-1", anchor \\ "anchor") do
    %{
      "version" => 1,
      "fact" => "received",
      "event_id" => "received:" <> item_id,
      "item_id" => item_id,
      "session_id" => "session",
      "origin" => %{
        "run_id" => "run",
        "incarnation" => 1,
        "turn_id" => "runtime-turn",
        "step_id" => "step",
        "attempt_id" => "attempt",
        "invocation_id" => "invocation:" <> item_id,
        "tool_call_id" => "call:" <> item_id,
        "tool_name" => "request_user_input_async",
        "branch_entry_id" => anchor
      },
      "questions" => [%{"title" => "Continue?", "options" => ["A", "B"]}]
    }
  end

  defp fact(name, attrs) do
    Map.merge(
      %{
        "version" => 1,
        "fact" => name,
        "event_id" => name <> ":item-1",
        "item_id" => "item-1",
        "session_id" => "session"
      },
      attrs
    )
  end
end
