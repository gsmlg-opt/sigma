defmodule Sigma.Agent.BackplanePlanProjectionTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.Backplane.PlanProjection

  test "captures only the final prepared input and a confirmed successful receipt" do
    prepared = invocation(%{"plan" => [%{"step" => "Approved", "status" => "completed"}]})

    assert {:ok, snapshot} = PlanProjection.capture(prepared, %{revision: 2, status: :updated})
    assert snapshot["plan"] == prepared.arguments["plan"]
    assert snapshot["run_id"] == "run-1"
    assert snapshot["incarnation"] == 1
    assert snapshot["tool_call_id"] == "call-1"
    assert snapshot["revision"] == 2
    assert snapshot["version"] == 1
    assert snapshot["explanation"] == nil
    assert snapshot == snapshot |> Jason.encode!() |> Jason.decode!()
  end

  test "unknown, failed and malformed effects never become confirmed plans" do
    for result <- [
          %{revision: 2, status: :unknown_outcome},
          %{revision: 2, status: :updated, is_error: true},
          %{revision: 2, status: :updated, error: %{message: "post hook failed"}},
          %{revision: 0, status: :updated},
          %{status: :updated},
          %{revision: 2, status: :completed},
          nil
        ] do
      assert PlanProjection.capture(invocation(), result) == :ignore
    end

    for change <- [%{tool_name: "exec"}, %{run_id: nil}, %{incarnation: 0}, %{tool_call_id: ""}] do
      assert PlanProjection.capture(Map.merge(invocation(), change), receipt()) == :ignore
    end
  end

  test "bounded validation preserves Unicode, strips unrelated data and refuses invalid steps" do
    args = %{
      "plan" => [%{"step" => "复核 👩‍💻", "status" => "in_progress", "extra" => self()}],
      "explanation" => "Keep exact text\n",
      "private" => self()
    }

    assert {:ok, snapshot} = PlanProjection.capture(invocation(args), receipt())
    assert snapshot["plan"] == [%{"step" => "复核 👩‍💻", "status" => "in_progress"}]
    assert snapshot["explanation"] == "Keep exact text\n"

    for args <- [
          %{"plan" => [%{"step" => "Bad", "status" => "done"}]},
          %{"plan" => [%{"step" => self(), "status" => "pending"}]},
          %{"plan" => [%{"step" => <<255>>, "status" => "pending"}]},
          %{"plan" => List.duplicate(%{"step" => "x", "status" => "pending"}, 129)},
          %{"plan" => [%{"step" => String.duplicate("界", 1_366), "status" => "pending"}]},
          %{"plan" => [], "explanation" => String.duplicate("x", 8_193)},
          %{
            "plan" =>
              List.duplicate(%{"step" => String.duplicate("x", 4_096), "status" => "pending"}, 20)
          }
        ] do
      assert PlanProjection.capture(invocation(args), receipt()) == :ignore
    end
  end

  test "latest uses only validated metadata on successful matching tool results" do
    {:ok, first} = PlanProjection.capture(invocation(), receipt())

    next = invocation(%{"plan" => [], "explanation" => "Done"})
    next = %{next | run_id: "after-restart", tool_call_id: "call-2"}
    {:ok, second} = PlanProjection.capture(next, %{revision: 1, status: :updated})

    assert PlanProjection.latest([message(first), message(second)]) == second
    assert PlanProjection.latest([message(first), %{message(second) | is_error: true}]) == first

    for invalid <- [
          %{message(second) | tool_call_id: "other-call"},
          %{message(second) | tool_name: "exec_command"},
          %{message(second) | metadata: %{native_plan: %{second | "version" => 2}}},
          %{message(second) | metadata: %{native_plan: second}},
          %{role: :assistant, content: [], metadata: %{native_plan: second}}
        ] do
      assert PlanProjection.latest([message(first), invalid]) == first
    end
  end

  test "JSONL metadata restores across reload without reconstructing old calls or executing effects" do
    alias Sigma.Agent.Message
    alias Sigma.Session.{EntryDecoder, EntryEncoder}

    {:ok, snapshot} = PlanProjection.capture(invocation(), receipt())
    msg = struct(Message, message(snapshot))
    assert {:ok, entry} = EntryEncoder.encode({:message_end, msg}, nil, true)
    assert {:ok, reloaded} = entry |> Jason.encode!() |> Jason.decode!() |> EntryDecoder.message()
    assert PlanProjection.latest([reloaded]) == snapshot

    old = %{msg | metadata: %{}, content: [%{type: :text, text: Jason.encode!(receipt())}]}
    assert PlanProjection.latest([old]) == nil
  end

  test "public Plan state captures nested final content with explicit root publication identity" do
    alias Backplane.AgentRuntime.Plan

    {:ok, plan} = Plan.start_link("/trusted/workspace")

    try do
      origin = %{invocation() | tool_name: "exec"}
      assert PlanProjection.capture_state(origin, Plan.read(plan)) == :ignore
      content = %{"plan" => [%{"step" => "Nested prepared", "status" => "completed"}]}
      assert {:ok, _} = Plan.update(plan, 1, content)
      assert {:ok, snapshot} = PlanProjection.capture_state(origin, Plan.read(plan))
      assert snapshot["plan"] == content["plan"]
      assert snapshot["source"] == "plan_state"
      assert snapshot["source_tool"] == "exec"
      refute Map.has_key?(snapshot, "scope")

      publication = %{message(snapshot) | tool_name: "exec", metadata: %{native_plan: snapshot}}
      assert PlanProjection.latest([publication]) == snapshot
      assert PlanProjection.latest([%{publication | is_error: true}]) == nil
      assert PlanProjection.capture_state(origin, {:error, :unavailable}) == :ignore
    after
      GenServer.stop(plan)
    end
  end

  @tag :tmp_dir
  test "raw selected branch retains archived plans across compaction/reset and excludes sibling plans",
       %{tmp_dir: dir} do
    alias Sigma.Agent.Message
    alias Sigma.Session.{Log, Writer}

    writer =
      start_supervised!(
        {Writer, storage_id: Path.join(dir, "plan.jsonl"), session_id: "plan", cwd: dir}
      )

    {:ok, first} = PlanProjection.capture(invocation(), receipt())

    assert {:ok, first_id} =
             Writer.append(writer, {:message_end, struct(Message, message(first))})

    assert {:ok, kept_id} = Writer.append(writer, {:message_end, Message.user("kept", "Keep")})
    assert {:ok, _} = Writer.append(writer, {:compact, %{content: "Summary"}, kept_id})

    assert {:ok, reset_id} =
             Writer.append(
               writer,
               {:context_window_started, %{run_id: "reset", incarnation: 1, window: 2}}
             )

    assert {:ok, selected} = Writer.selected_journal(writer)

    assert {:ok, ^first} =
             PlanProjection.latest_entries(selected.entries, leaf_id: selected.leaf_id)

    assert {:ok, display} = Log.snapshot(Path.join(dir, "plan.jsonl"))
    assert PlanProjection.latest(display.messages) == nil

    {:ok, sibling} =
      PlanProjection.capture(%{invocation(%{"plan" => []}) | tool_call_id: "sibling"}, receipt())

    assert {:ok, sibling_id} =
             Writer.append(writer, {:message_end, struct(Message, message(sibling))})

    assert :ok = Writer.checkout(writer, reset_id, sibling_id)
    assert {:ok, selected} = Writer.selected_journal(writer)
    assert selected.leaf_id == reset_id

    assert {:ok, ^first} =
             PlanProjection.latest_entries(selected.entries, leaf_id: selected.leaf_id)

    assert {:ok, ^sibling} = PlanProjection.latest_entries(selected.entries, leaf_id: sibling_id)
    assert {:ok, nil} = PlanProjection.latest_entries(selected.entries, leaf_id: nil)

    assert {:error, {:leaf_not_found, "foreign"}} =
             PlanProjection.latest_entries(selected.entries, leaf_id: "foreign")

    assert {:ok, ^first} = PlanProjection.latest_entries(selected.entries, leaf_id: first_id)
  end

  defp invocation(args \\ %{"plan" => [%{"step" => "Review", "status" => "pending"}]}) do
    %{
      tool_name: "update_plan",
      run_id: "run-1",
      incarnation: 1,
      tool_call_id: "call-1",
      arguments: args
    }
  end

  defp receipt, do: %{revision: 2, status: :updated}

  defp message(snapshot) do
    %{
      id: "result-" <> snapshot["tool_call_id"],
      role: :tool_result,
      tool_name: "update_plan",
      tool_call_id: snapshot["tool_call_id"],
      is_error: false,
      content: [],
      metadata: %{
        native_plan: snapshot,
        structured_result: %{"revision" => snapshot["revision"], "status" => "updated"}
      }
    }
  end
end
