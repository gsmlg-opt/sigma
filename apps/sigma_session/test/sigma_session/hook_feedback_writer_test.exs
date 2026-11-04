defmodule Sigma.Session.HookFeedbackWriterTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.Message
  alias Sigma.Session.{HookFeedback, Journal, Log, Writer}
  alias Sigma.Session.Storage.JsonlFile

  @moduletag :tmp_dir

  defmodule FaultStorage do
    def read({path, _fault}), do: JsonlFile.read(path)
    def read_with_diagnostics({path, _fault}), do: JsonlFile.read_with_diagnostics(path)

    def append({path, fault}, entry) do
      if entry["type"] == "hook_feedback" and Agent.get(fault, & &1),
        do: {:error, :disk_full},
        else: JsonlFile.append(path, entry)
    end
  end

  test "receipt ACK follows disk commit and exact retries survive a writer restart", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "receipts.jsonl")
    fault = start_supervised!({Agent, fn -> false end})
    writer = writer!(path, storage_id: {path, fault}, storage_mod: FaultStorage)
    anchor = user!(writer, "user")
    event = received!(anchor)
    bytes = File.read!(path)
    Agent.update(fault, fn _ -> true end)

    assert {:error, {:storage_append_failed, :disk_full}} = append(writer, event, anchor)
    assert {:ok, empty} = state(writer)
    assert empty.projection == HookFeedback.new()
    assert File.read!(path) == bytes

    Agent.update(fault, fn _ -> false end)
    assert {:ok, receipt} = append(writer, event, anchor)
    assert {:ok, saved} = state(writer)
    assert saved.leaf_id == anchor
    assert saved.session_id == "hooks-session"
    assert saved.projection.items[event["item_id"]]["text"] == "  中文\ncontext  "
    bytes = File.read!(path)
    assert {:ok, ^receipt} = append(writer, event, anchor)

    assert {:error, :hook_feedback_conflict} =
             append(writer, %{event | "text" => "changed"}, anchor)

    assert File.read!(path) == bytes

    GenServer.stop(writer)
    reopened = writer!(path)
    assert {:ok, ^saved} = state(reopened)
    assert {:ok, ^receipt} = append(reopened, event, anchor)
    assert File.read!(path) == bytes
  end

  test "facts require the current leaf and trusted session without admitting foreign branches", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "scope.jsonl")
    writer = writer!(path)
    anchor = user!(writer, "user")
    event = received!(anchor)
    bytes = File.read!(path)

    assert {:error, :invalid_hook_feedback_scope} = append(writer, event, nil)
    assert {:ok, foreign} = HookFeedback.received("foreign-session", origin(anchor), "foreign")
    assert {:error, :invalid_hook_feedback_scope} = append(writer, foreign, anchor)

    assert {:error, :hook_feedback_requires_expected_leaf} =
             Writer.append(writer, {:hook_feedback, event})

    assert File.read!(path) == bytes

    assert :ok = Writer.checkout(writer, nil, anchor)
    sibling = user!(writer, "sibling")
    assert {:error, :invalid_hook_feedback_scope} = append(writer, event, sibling)
    assert {:ok, scope} = state(writer)
    assert scope.projection.items == %{}
  end

  test "a sibling delivery stays globally deduplicated and cannot appear on another branch", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "branches.jsonl")
    writer = writer!(path)
    anchor = user!(writer, "common")
    event = received!(anchor)
    assert {:ok, _} = append(writer, event, anchor)
    first_leaf = user!(writer, "first-branch")
    assert {:ok, current} = state(writer)
    item = current.projection.items[event["item_id"]]

    assert {:ok, dispatch} =
             HookFeedback.fact(item, "dispatch_started", %{"delivery" => delivery()})

    assert {:ok, receipt} = append(writer, dispatch, first_leaf)
    assert :ok = Writer.checkout(writer, anchor, first_leaf)
    sibling = user!(writer, "second-branch")

    assert {:ok, selected} = state(writer)
    assert selected.projection.items == %{}
    assert selected.projection.events == %{}
    assert selected.history.items[event["item_id"]]["status"] == "dispatching"
    before = File.read!(path)
    assert {:error, :invalid_hook_feedback_scope} = append(writer, event, sibling)
    assert {:error, :invalid_hook_feedback_scope} = append(writer, dispatch, sibling)
    assert File.read!(path) == before
    assert {:ok, branches} = Log.branch_summaries(path)
    assert length(branches) == 2

    GenServer.stop(writer)
    reopened = writer!(path)
    assert {:ok, recovered} = state(reopened)
    assert recovered.projection.items == %{}
    assert :ok = Writer.checkout(reopened, first_leaf, sibling)
    assert {:ok, ^receipt} = append(reopened, dispatch, first_leaf)
    assert File.read!(path) == before
  end

  test "delivery phases remain auxiliary and preserve exact canonical and Runtime identities", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "delivery.jsonl")
    writer = writer!(path)
    anchor = user!(writer, "origin")
    event = received!(anchor)
    assert {:ok, _} = append(writer, event, anchor)

    for {fact, attrs} <- [
          {"dispatch_started", %{"delivery" => delivery()}},
          {"admitted",
           %{"message_id" => "canonical-message", "runtime_message_id" => "runtime-admission"}},
          {"consumed", %{"message_id" => "canonical-message"}}
        ] do
      assert {:ok, current} = state(writer)
      item = current.projection.items[event["item_id"]]
      assert {:ok, next} = HookFeedback.fact(item, fact, attrs)
      assert {:ok, _} = append(writer, next, anchor)
    end

    assert {:ok, done} = state(writer)
    assert done.leaf_id == anchor
    assert done.projection.items[event["item_id"]]["status"] == "consumed"

    assert done.projection.items[event["item_id"]]["delivery"]["runtime_message_id"] ==
             "runtime-admission"

    assert {:ok, snapshot} = Log.snapshot(path)
    assert [%{id: "origin"}] = snapshot.messages
    assert snapshot.active_leaf_id == anchor
    assert {:ok, [only]} = Log.branch_summaries(path)
    assert only.leaf_id == anchor
  end

  test "corrupted receipt ancestry blocks further acknowledgements after replay", %{tmp_dir: dir} do
    path = Path.join(dir, "corrupt.jsonl")
    writer = writer!(path)
    first = user!(writer, "first")
    assert :ok = Writer.checkout(writer, nil, first)
    second = user!(writer, "second")
    GenServer.stop(writer)

    entry = %{
      "id" => "crossed-hook-fact",
      "type" => "hook_feedback",
      "parentId" => second,
      "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
      "event" => received!(first)
    }

    assert :ok = JsonlFile.append(path, entry)
    assert {:ok, entries} = JsonlFile.read(path)
    assert {:ok, snapshot} = Journal.replay(entries)
    assert Enum.any?(snapshot.diagnostics, &(&1.kind == :invalid_hook_feedback))
    bytes = File.read!(path)
    reopened = writer!(path)
    assert {:error, {:invalid_journal, _}} = state(reopened)

    assert {:error, {:invalid_journal, _}} =
             Writer.append(reopened, {:message_end, Message.user("later", "later")})

    assert File.read!(path) == bytes
  end

  test "uncertain delivery survives restart and cannot be automatically dispatched again", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "unknown.jsonl")
    writer = writer!(path)
    anchor = user!(writer, "origin")
    received = received!(anchor)
    assert {:ok, _} = append(writer, received, anchor)
    assert {:ok, saved} = state(writer)
    item = saved.projection.items[received["item_id"]]

    assert {:ok, dispatch} =
             HookFeedback.fact(item, "dispatch_started", %{"delivery" => delivery()})

    assert {:ok, receipt} = append(writer, dispatch, anchor)

    assert {:ok, unknown} =
             HookFeedback.fact(item, "delivery_unknown", %{"reason" => "admission ACK lost"})

    assert {:ok, _} = append(writer, unknown, anchor)
    GenServer.stop(writer)
    writer = writer!(path)
    before = File.read!(path)

    assert {:ok, recovered} = state(writer)
    item = recovered.projection.items[received["item_id"]]
    assert item["status"] == "delivery_unknown"
    assert {:ok, ^receipt} = append(writer, dispatch, anchor)
    assert {:ok, _} = append(writer, received, anchor)
    assert {:ok, still_unknown} = state(writer)
    assert still_unknown.projection.items[item["item_id"]]["status"] == "delivery_unknown"

    assert {:ok, retry} =
             HookFeedback.fact(item, "dispatch_started", %{
               "delivery" => %{delivery() | "message_id" => "retry"}
             })

    assert {:error, :hook_feedback_conflict} = append(writer, retry, anchor)

    assert {:ok, late_admitted} =
             HookFeedback.fact(item, "admitted", %{
               "message_id" => "canonical-message",
               "runtime_message_id" => "late-ACK"
             })

    assert {:error, :hook_feedback_conflict} = append(writer, late_admitted, anchor)
    assert File.read!(path) == before
  end

  test "replay rejects a later fact that crosses sibling ancestry from a shared origin", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "cross-sibling-transition.jsonl")
    writer = writer!(path)
    anchor = user!(writer, "common")
    received = received!(anchor)
    assert {:ok, _} = append(writer, received, anchor)
    assert {:ok, saved} = state(writer)
    item = saved.projection.items[received["item_id"]]
    first = user!(writer, "first")

    assert {:ok, dispatch} =
             HookFeedback.fact(item, "dispatch_started", %{"delivery" => delivery()})

    assert {:ok, _} = append(writer, dispatch, first)
    assert :ok = Writer.checkout(writer, anchor, first)
    sibling = user!(writer, "sibling")
    GenServer.stop(writer)

    assert {:ok, admitted} =
             HookFeedback.fact(item, "admitted", %{
               "message_id" => "canonical-message",
               "runtime_message_id" => "runtime-ID"
             })

    assert :ok =
             JsonlFile.append(path, %{
               "id" => "crossed-transition",
               "type" => "hook_feedback",
               "parentId" => sibling,
               "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
               "event" => admitted
             })

    reopened = writer!(path)
    assert {:error, {:invalid_journal, diagnostics}} = state(reopened)

    assert Enum.any?(
             diagnostics,
             &(&1.kind == :invalid_hook_feedback and &1.reason == :invalid_hook_feedback_scope)
           )

    before = File.read!(path)

    assert {:error, {:invalid_journal, _}} =
             Writer.append(reopened, {:message_end, Message.user("later", "later")})

    assert File.read!(path) == before
  end

  test "recovery authenticates every hook fact against the writer's trusted session", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "foreign-session.jsonl")
    writer = writer!(path)
    anchor = user!(writer, "origin")
    GenServer.stop(writer)

    assert {:ok, foreign} =
             HookFeedback.received("foreign-session", origin(anchor), "foreign context")

    assert :ok =
             JsonlFile.append(path, %{
               "id" => "foreign-receipt",
               "type" => "hook_feedback",
               "parentId" => anchor,
               "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
               "event" => foreign
             })

    reopened = writer!(path)
    assert {:error, {:invalid_journal, diagnostics}} = state(reopened)

    assert Enum.any?(
             diagnostics,
             &(&1.kind == :invalid_hook_feedback and &1.reason == :invalid_hook_feedback_session)
           )

    assert {:error, {:invalid_journal, _}} = Writer.context_snapshot(reopened)
    assert {:error, {:invalid_journal, _}} = Writer.selected_journal(reopened)
    assert {:error, {:invalid_journal, _}} = Writer.checkout(reopened, nil, anchor)
    assert {:ok, %{active_leaf_id: ^anchor}} = Writer.flush(reopened)
    before = File.read!(path)

    assert {:error, {:invalid_journal, _}} =
             Writer.append(reopened, {:message_end, Message.user("later", "later")})

    assert File.read!(path) == before
  end

  defp writer!(path, opts \\ []) do
    {:ok, writer} =
      Writer.start_link(
        Keyword.merge(
          [storage_id: path, session_id: "hooks-session", cwd: Path.dirname(path)],
          opts
        )
      )

    on_exit(fn -> if Process.alive?(writer), do: GenServer.stop(writer) end)
    writer
  end

  defp user!(writer, id) do
    assert {:ok, entry_id} =
             Writer.append(writer, {:message_end, Message.user(id, "user prompt")})

    entry_id
  end

  defp received!(anchor) do
    assert {:ok, event} =
             HookFeedback.received("hooks-session", origin(anchor), "  中文\ncontext  ")

    event
  end

  defp origin(anchor) do
    %{
      "run_id" => "origin-run",
      "incarnation" => 1,
      "turn_id" => "origin-turn",
      "step_id" => "origin-step",
      "attempt_id" => "origin-attempt",
      "invocation_id" => "origin-invocation",
      "tool_call_id" => "origin-call",
      "tool_name" => "update_plan",
      "branch_entry_id" => anchor,
      "handler_index" => 0,
      "handler_digest" => String.duplicate("a", 64)
    }
  end

  defp delivery,
    do: %{"message_id" => "canonical-message", "turn_id" => "delivery-turn", "mode" => "steering"}

  defp state(writer), do: apply(Writer, :hook_feedback_state, [writer])

  defp append(writer, event, leaf),
    do: apply(Writer, :append_hook_feedback, [writer, event, leaf])
end
