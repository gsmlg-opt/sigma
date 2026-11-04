defmodule Sigma.Session.HookFeedbackTest do
  use ExUnit.Case, async: true

  alias Sigma.Session.HookFeedback

  test "Chinese hook output survives receipt JSON round trips without truncation" do
    text = "检查完成：请保留中文原文。\n第二行：没有调用 Runtime。"
    assert {:ok, received} = HookFeedback.received("session-1", origin(), text)
    assert String.starts_with?(received["item_id"], "sigma-async-hook-")

    assert {:ok, ^received} =
             received |> Jason.encode!() |> Jason.decode!() |> HookFeedback.event()

    assert {:ok, state} = HookFeedback.apply_event(HookFeedback.new(), received)
    item = state.items[received["item_id"]]
    assert item["text"] == text
    assert item["origin"] == origin()
    assert item["status"] == "received"
    assert item["delivery"] == nil
    assert state.version == 1
  end

  test "all immutable origin fields and the session bind identity, including handler index" do
    assert {:ok, first} = HookFeedback.received("session-1", origin(), "first output")
    assert {:ok, same} = HookFeedback.received("session-1", origin(), "changed output")
    assert same["item_id"] == first["item_id"]
    assert same["event_id"] == first["event_id"]

    variants =
      Enum.map(origin(), fn
        {"handler_index", value} -> Map.put(origin(), "handler_index", value + 1)
        {"incarnation", value} -> Map.put(origin(), "incarnation", value + 1)
        {"handler_digest", _} -> Map.put(origin(), "handler_digest", String.duplicate("b", 64))
        {key, value} -> Map.put(origin(), key, value <> "-different")
      end)

    ids =
      Enum.map(variants, fn changed ->
        assert {:ok, received} = HookFeedback.received("session-1", changed, "first output")
        received["item_id"]
      end)

    assert length(Enum.uniq([first["item_id"] | ids])) == length(ids) + 1
    assert {:ok, foreign} = HookFeedback.received("session-2", origin(), "first output")
    refute foreign["item_id"] in (ids ++ [first["item_id"]])

    assert {:ok, second} =
             HookFeedback.received("session-1", Map.put(origin(), "handler_index", 1), "same")

    assert {:ok, state} = HookFeedback.apply_event(HookFeedback.new(), first)
    assert {:ok, state} = HookFeedback.apply_event(state, second)
    assert map_size(state.items) == 2
  end

  test "replay is idempotent while changed text, origin, session or event identity is rejected" do
    {state, item, received} = received_state()
    assert {:ok, ^state} = HookFeedback.apply_event(state, received)
    assert {:ok, changed} = HookFeedback.received("session-1", origin(), "changed")
    assert {:error, :hook_feedback_conflict} = HookFeedback.apply_event(state, changed)

    for forged <- [
          put_in(received, ["origin", "tool_call_id"], "foreign-call"),
          Map.put(received, "session_id", "foreign-session"),
          Map.put(received, "item_id", "sigma-async-hook-forged"),
          Map.put(received, "event_id", "payload-dependent-new-id")
        ] do
      assert {:error, _} = HookFeedback.apply_event(state, forged)
    end

    assert {:ok, started} = start_event(item)
    assert {:ok, dispatching} = HookFeedback.apply_event(state, started)
    assert {:ok, ^dispatching} = HookFeedback.apply_event(dispatching, received)
    assert {:ok, ^dispatching} = HookFeedback.apply_event(dispatching, started)

    assert {:ok, changed_start} =
             HookFeedback.fact(item, "dispatch_started", %{
               "delivery" => Map.put(delivery(), "message_id", "different-canonical-id")
             })

    assert changed_start["event_id"] == started["event_id"]

    assert {:error, :hook_feedback_conflict} =
             HookFeedback.apply_event(dispatching, changed_start)
  end

  test "admission binds the real Runtime ID separately from the canonical host message" do
    {state, item, _} = received_state()
    assert {:ok, started} = start_event(item)
    assert {:ok, state} = HookFeedback.apply_event(state, started)
    item = state.items[item["item_id"]]
    assert item["delivery"] == delivery()

    assert {:error, _} = HookFeedback.fact(item, "admitted", %{"message_id" => "host-message"})
    assert {:ok, admitted} = admitted_event(item)
    assert {:ok, state} = HookFeedback.apply_event(state, admitted)
    item = state.items[item["item_id"]]
    assert item["status"] == "admitted"
    assert item["delivery"]["message_id"] == "host-message"
    assert item["delivery"]["runtime_message_id"] == "runtime-returned-message"
    assert {:ok, ^state} = HookFeedback.apply_event(state, admitted)

    assert {:ok, conflicting} =
             HookFeedback.fact(item, "admitted", %{
               "message_id" => "host-message",
               "runtime_message_id" => "different-runtime-message"
             })

    assert conflicting["event_id"] == admitted["event_id"]
    assert {:error, :hook_feedback_conflict} = HookFeedback.apply_event(state, conflicting)
    assert {:ok, consumed} = consumed_event(item)
    assert {:ok, state} = HookFeedback.apply_event(state, consumed)
    assert state.items[item["item_id"]]["status"] == "consumed"
    assert state.items[item["item_id"]]["delivery"] == item["delivery"]
  end

  test "canonical message correlation is checked for admission and consumption" do
    {state, item, _} = received_state()
    assert {:ok, started} = start_event(item)
    assert {:ok, state} = HookFeedback.apply_event(state, started)

    assert {:ok, wrong} =
             HookFeedback.fact(item, "admitted", %{
               "message_id" => "wrong-host-message",
               "runtime_message_id" => "runtime-returned-message"
             })

    assert {:error, :hook_feedback_conflict} = HookFeedback.apply_event(state, wrong)
    assert {:ok, admitted} = admitted_event(item)
    assert {:ok, state} = HookFeedback.apply_event(state, admitted)

    assert {:ok, wrong} =
             HookFeedback.fact(item, "consumed", %{"message_id" => "runtime-returned-message"})

    assert {:error, :hook_feedback_conflict} = HookFeedback.apply_event(state, wrong)
  end

  test "delivery uncertainty prevents redispatch and permits only correlated consumption or discard" do
    for admission? <- [false, true] do
      {state, item, received} = received_state()
      assert {:ok, started} = start_event(item)
      assert {:ok, state} = HookFeedback.apply_event(state, started)

      state =
        if admission? do
          assert {:ok, admitted} = admitted_event(item)
          assert {:ok, state} = HookFeedback.apply_event(state, admitted)
          state
        else
          state
        end

      assert {:ok, unknown} =
               HookFeedback.fact(item, "delivery_unknown", %{"reason" => "process lost"})

      assert {:ok, uncertain} = HookFeedback.apply_event(state, unknown)
      assert uncertain.items[item["item_id"]]["status"] == "delivery_unknown"
      assert {:ok, ^uncertain} = HookFeedback.apply_event(uncertain, received)
      assert {:ok, ^uncertain} = HookFeedback.apply_event(uncertain, started)
      assert {:ok, admitted} = admitted_event(item)

      if admission?,
        do: assert({:ok, ^uncertain} = HookFeedback.apply_event(uncertain, admitted)),
        else:
          assert(
            {:error, :hook_feedback_conflict} =
              HookFeedback.apply_event(uncertain, admitted)
          )

      assert {:ok, consumed} = consumed_event(item)
      assert {:ok, consumed_state} = HookFeedback.apply_event(uncertain, consumed)
      assert consumed_state.items[item["item_id"]]["status"] == "consumed"

      assert {:ok, discarded} =
               HookFeedback.fact(item, "discarded", %{"reason" => "session changed"})

      assert {:ok, discarded_state} = HookFeedback.apply_event(uncertain, discarded)
      assert discarded_state.items[item["item_id"]]["status"] == "discarded"
    end
  end

  test "facts cannot skip dispatch, consume before proof, or change a terminal outcome" do
    {received, item, _} = received_state()
    assert {:ok, started} = start_event(item)
    assert {:ok, admitted} = admitted_event(item)
    assert {:ok, consumed} = consumed_event(item)
    assert {:ok, unknown} = HookFeedback.fact(item, "delivery_unknown", %{"reason" => "lost"})
    assert {:ok, discarded} = HookFeedback.fact(item, "discarded", %{"reason" => "closed"})

    for event <- [admitted, consumed, unknown] do
      assert {:error, :hook_feedback_conflict} = HookFeedback.apply_event(received, event)
    end

    assert {:ok, dispatching} = HookFeedback.apply_event(received, started)
    assert {:error, :hook_feedback_conflict} = HookFeedback.apply_event(dispatching, consumed)
    assert {:ok, admitted_state} = HookFeedback.apply_event(dispatching, admitted)
    assert {:ok, consumed_state} = HookFeedback.apply_event(admitted_state, consumed)
    assert {:ok, ^consumed_state} = HookFeedback.apply_event(consumed_state, consumed)

    for event <- [unknown, discarded] do
      assert {:error, :hook_feedback_conflict} = HookFeedback.apply_event(consumed_state, event)
    end

    for state <- [received, dispatching, admitted_state] do
      assert {:ok, terminal} = HookFeedback.apply_event(state, discarded)
      assert {:ok, ^terminal} = HookFeedback.apply_event(terminal, discarded)

      for event <- [consumed, unknown] do
        assert {:error, :hook_feedback_conflict} = HookFeedback.apply_event(terminal, event)
      end
    end
  end

  test "text bounds count UTF-8 bytes and never truncate the original" do
    exact = String.duplicate("中", 21_845) <> "x"
    assert byte_size(exact) == 65_536
    assert {:ok, event} = HookFeedback.received("session-1", origin(), exact)
    assert event["text"] == exact

    for text <- ["", " \n", <<255>>, exact <> "x", nil, 1] do
      assert {:error, _} = HookFeedback.received("session-1", origin(), text)
    end
  end

  test "origin is a closed JSON map with bounded identities and explicit handler identity" do
    invalid = [
      Map.delete(origin(), "handler_index"),
      Map.delete(origin(), "handler_digest"),
      Map.put(origin(), "handler_index", -1),
      Map.put(origin(), "handler_index", 0.0),
      Map.put(origin(), "incarnation", 0),
      Map.put(origin(), "incarnation", "1"),
      Map.put(origin(), "run_id", ""),
      Map.put(origin(), "tool_name", <<255>>),
      Map.put(origin(), "run_id", String.duplicate("x", 513)),
      Map.put(origin(), "handler_digest", String.duplicate("A", 64)),
      Map.put(origin(), "handler_digest", String.duplicate("a", 63)),
      Map.put(origin(), "handler_digest", String.duplicate("z", 64)),
      Map.put(origin(), "extra", "unexpected"),
      Map.put(origin(), :run_id, "alias"),
      %{run_id: "atom-only"},
      nil
    ]

    for candidate <- invalid do
      assert {:error, _} = HookFeedback.received("session-1", candidate, "text")
    end

    for session <- ["", <<255>>, String.duplicate("x", 513), nil] do
      assert {:error, _} = HookFeedback.received(session, origin(), "text")
    end
  end

  test "closed fact schemas reject aliases, unrecognized fields, versions and phases" do
    {_state, item, received} = received_state()

    for candidate <- [
          Map.put(received, :version, 1),
          Map.put(received, "version", 2),
          Map.put(received, "fact", "host_feedback"),
          Map.put(received, "extra", true),
          Map.put(received, "text", <<255>>),
          Map.put(received, "text", String.duplicate("x", 65_537)),
          %{version: 1},
          nil
        ] do
      assert {:error, _} = HookFeedback.event(candidate)
    end

    for {name, attrs} <- [
          {"dispatch_started", %{"delivery" => Map.put(delivery(), :message_id, "alias")}},
          {"dispatch_started", %{"delivery" => Map.put(delivery(), "mode", "async")}},
          {"dispatch_started", %{"delivery" => Map.delete(delivery(), "turn_id")}},
          {"dispatch_started", %{"delivery" => delivery(), "extra" => true}},
          {"admitted", %{"message_id" => "host-message", "runtime_message_id" => ""}},
          {"consumed", %{"message_id" => "host-message", "receipt" => "fake"}},
          {"discarded", %{"reason" => ""}},
          {"delivery_unknown", %{"reason" => String.duplicate("x", 4_097)}},
          {"received", %{"origin" => origin(), "text" => "new"}},
          {"unknown", %{}},
          {"discarded", %{"reason" => "closed", "session_id" => "foreign"}},
          {"discarded", %{reason: "closed"}}
        ] do
      assert {:error, _} = HookFeedback.fact(item, name, attrs)
    end

    assert {:error, _} = HookFeedback.apply_event(%{HookFeedback.new() | version: 2}, received)
    assert {:error, _} = HookFeedback.apply_event(HookFeedback.new(), %{"version" => 2})
  end

  defp received_state do
    assert {:ok, received} = HookFeedback.received("session-1", origin(), "检查原始输出")
    assert {:ok, state} = HookFeedback.apply_event(HookFeedback.new(), received)
    {state, state.items[received["item_id"]], received}
  end

  defp start_event(item),
    do: HookFeedback.fact(item, "dispatch_started", %{"delivery" => delivery()})

  defp admitted_event(item),
    do:
      HookFeedback.fact(item, "admitted", %{
        "message_id" => "host-message",
        "runtime_message_id" => "runtime-returned-message"
      })

  defp consumed_event(item),
    do: HookFeedback.fact(item, "consumed", %{"message_id" => "host-message"})

  defp delivery,
    do: %{"message_id" => "host-message", "turn_id" => "delivery-turn", "mode" => "steering"}

  defp origin do
    %{
      "run_id" => "root-run",
      "incarnation" => 1,
      "turn_id" => "origin-turn",
      "step_id" => "step-1",
      "attempt_id" => "attempt-1",
      "invocation_id" => "invocation-1",
      "tool_call_id" => "tool-call-1",
      "tool_name" => "exec_command",
      "branch_entry_id" => "branch-anchor",
      "handler_index" => 0,
      "handler_digest" => String.duplicate("a", 64)
    }
  end
end
