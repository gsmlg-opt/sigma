defmodule Sigma.Session.AsyncInteractionsTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.Backplane.AsyncInbox
  alias Sigma.Agent.Message
  alias Sigma.Protocol.AsyncInteractions
  alias Sigma.Session.{Journal, Log, Writer}
  alias Sigma.Session.Storage.JsonlFile

  @moduletag :tmp_dir

  defmodule FaultStorage do
    @behaviour Sigma.Session.Storage

    @impl true
    def read({path, _fault}), do: JsonlFile.read(path)

    @impl true
    def read_with_diagnostics({path, _fault}), do: JsonlFile.read_with_diagnostics(path)

    @impl true
    def append({path, fault}, entry) do
      if entry["type"] == "async_interaction" and Agent.get(fault, & &1),
        do: {:error, :disk_full},
        else: JsonlFile.append(path, entry)
    end
  end

  test "a failed receipt or answer append leaves the durable projection unchanged", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "failed-ack.jsonl")
    fault = start_supervised!({Agent, fn -> false end})
    writer = start_writer(path, storage_id: {path, fault}, storage_mod: FaultStorage)
    anchor = append_user(writer, "root-user", "root-run")
    event = received(anchor, "root-run")
    assert {:ok, before} = Writer.async_interaction_state(writer)
    bytes = File.read!(path)

    Agent.update(fault, fn _ -> true end)

    assert {:error, {:storage_append_failed, :disk_full}} =
             Writer.append_async_interaction(writer, event, anchor)

    assert {:ok, ^before} = Writer.async_interaction_state(writer)
    assert File.read!(path) == bytes

    Agent.update(fault, fn _ -> false end)
    assert {:ok, receipt_id} = Writer.append_async_interaction(writer, event, anchor)
    assert {:ok, acknowledged} = Writer.async_interaction_state(writer)
    assert acknowledged.leaf_id == anchor
    item = acknowledged.projection.items[event["item_id"]]
    assert {:ok, reply} = AsyncInteractions.reply(reply_payload(), item)
    assert {:ok, saved} = AsyncInteractions.fact(item, "reply_saved", %{"reply" => reply})
    bytes = File.read!(path)

    Agent.update(fault, fn _ -> true end)

    assert {:error, {:storage_append_failed, :disk_full}} =
             Writer.append_async_interaction(writer, saved, anchor)

    assert {:ok, ^acknowledged} = Writer.async_interaction_state(writer)
    assert File.read!(path) == bytes

    Agent.update(fault, fn _ -> false end)
    assert {:ok, saved_id} = Writer.append_async_interaction(writer, saved, anchor)
    assert saved_id != receipt_id
    assert {:ok, final} = Writer.async_interaction_state(writer)
    assert final.leaf_id == anchor
    assert final.projection.items[event["item_id"]]["status"] == "saved"
    assert final.projection.items[event["item_id"]]["reply"] == reply
  end

  test "the exact event returns its original receipt while conflicting identity is rejected", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "idempotency.jsonl")
    writer = start_writer(path)
    anchor = append_user(writer, "root-user", "root-run")
    event = received(anchor, "root-run")
    assert {:ok, receipt_id} = Writer.append_async_interaction(writer, event, anchor)
    assert {:ok, original} = Writer.async_interaction_state(writer)
    bytes = File.read!(path)

    assert {:ok, ^receipt_id} = Writer.append_async_interaction(writer, event, anchor)
    conflict = put_in(event, ["questions", Access.at(0), "title"], "Changed")

    assert {:error, :async_interaction_conflict} =
             Writer.append_async_interaction(writer, conflict, anchor)

    assert {:error, :async_interaction_conflict} =
             Writer.append_async_interaction(
               writer,
               %{conflict | "event_id" => "different-event"},
               anchor
             )

    assert {:ok, ^original} = Writer.async_interaction_state(writer)
    assert File.read!(path) == bytes

    GenServer.stop(writer)
    reopened = start_writer(path)
    assert {:ok, ^receipt_id} = Writer.append_async_interaction(reopened, event, anchor)
    assert {:ok, ^original} = Writer.async_interaction_state(reopened)
    assert File.read!(path) == bytes
  end

  test "expected leaf and trusted session are checked before accepting an async fact", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "scope.jsonl")
    writer = start_writer(path)
    anchor = append_user(writer, "root-user", "root-run")
    event = received(anchor, "root-run")
    bytes = File.read!(path)

    assert {:error, :invalid_async_interaction_scope} =
             Writer.append_async_interaction(writer, event, nil)

    assert {:error, :invalid_async_interaction_scope} =
             Writer.append_async_interaction(writer, %{event | "session_id" => "foreign"}, anchor)

    assert {:error, :async_interaction_requires_expected_leaf} =
             Writer.append(writer, {:async_interaction, event})

    assert {:ok, state} = Writer.async_interaction_state(writer)
    assert state.projection == AsyncInteractions.new()
    assert state.leaf_id == anchor
    assert File.read!(path) == bytes
  end

  test "a raw sibling anchor cannot receive a new card or answer a historical card", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "sibling-scope.jsonl")
    writer = start_writer(path)
    original_anchor = append_user(writer, "original-user", "original-run")
    historical = received(original_anchor, "original-run")
    assert {:ok, _} = Writer.append_async_interaction(writer, historical, original_anchor)
    assert {:ok, original} = Writer.async_interaction_state(writer)
    item = original.projection.items[historical["item_id"]]
    assert {:ok, reply} = AsyncInteractions.reply(reply_payload(), item)
    assert {:ok, saved} = AsyncInteractions.fact(item, "reply_saved", %{"reply" => reply})

    assert :ok = Writer.checkout(writer, nil, original_anchor)
    sibling_anchor = append_user(writer, "sibling-user", "sibling-run")
    bytes = File.read!(path)
    forged = received(original_anchor, "original-run", "new-sibling-card")

    assert {:error, :invalid_async_interaction_scope} =
             Writer.append_async_interaction(writer, forged, sibling_anchor)

    assert {:error, :invalid_async_interaction_scope} =
             Writer.append_async_interaction(writer, saved, sibling_anchor)

    assert {:error, :invalid_async_interaction_scope} =
             Writer.append_async_interaction(writer, saved, original_anchor)

    assert {:ok, state} = Writer.async_interaction_state(writer)
    assert state.projection.items == %{}
    assert state.leaf_id == sibling_anchor
    assert File.read!(path) == bytes
  end

  test "a shared ancestor card cannot expose or redispatch a sibling answer", %{tmp_dir: dir} do
    path = Path.join(dir, "shared-ancestor.jsonl")
    writer = start_writer(path)
    anchor = append_user(writer, "common-user", "common-run")
    event = received(anchor, "common-run")
    assert {:ok, _} = Writer.append_async_interaction(writer, event, anchor)
    first_leaf = append_user(writer, "branch-a", "branch-a-run")
    assert {:ok, state} = Writer.async_interaction_state(writer)
    item = state.projection.items[event["item_id"]]
    assert {:ok, reply} = AsyncInteractions.reply(reply_payload(), item)
    assert {:ok, saved} = AsyncInteractions.fact(item, "reply_saved", %{"reply" => reply})
    assert {:ok, saved_id} = Writer.append_async_interaction(writer, saved, first_leaf)
    assert :ok = Writer.checkout(writer, anchor, first_leaf)
    second_leaf = append_user(writer, "branch-b", "branch-b-run")
    assert {:ok, selected} = Writer.async_interaction_state(writer)
    assert selected.projection.items == %{}
    assert {:ok, second} = Log.snapshot(path, leaf_id: second_leaf)
    assert second.async_interactions.items == %{}
    assert {:ok, first} = Log.snapshot(path, leaf_id: first_leaf)
    assert first.async_interactions.items[event["item_id"]]["reply"] == reply
    before = File.read!(path)

    assert {:error, :invalid_async_interaction_scope} =
             Writer.append_async_interaction(writer, saved, second_leaf)

    assert File.read!(path) == before
    GenServer.stop(writer)
    writer = start_writer(path)
    assert {:ok, selected} = Writer.async_interaction_state(writer)
    assert selected.projection.items == %{}
    assert :ok = Writer.checkout(writer, first_leaf, second_leaf)
    assert {:ok, ^saved_id} = Writer.append_async_interaction(writer, saved, first_leaf)
    assert File.read!(path) == before
  end

  test "a received fact on a sibling stays hidden even when its origin is a shared ancestor", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "shared-receipt.jsonl")
    writer = start_writer(path)
    anchor = append_user(writer, "common-user", "common-run")
    first_leaf = append_user(writer, "branch-a", "branch-a-run")
    event = received(anchor, "common-run")
    assert {:ok, _} = Writer.append_async_interaction(writer, event, first_leaf)
    assert :ok = Writer.checkout(writer, anchor, first_leaf)
    second_leaf = append_user(writer, "branch-b", "branch-b-run")
    assert {:ok, selected} = Writer.async_interaction_state(writer)
    assert selected.projection.items == %{}
    assert {:ok, snapshot} = Log.snapshot(path, leaf_id: second_leaf)
    assert snapshot.async_interactions.items == %{}

    assert {:error, :invalid_async_interaction_scope} =
             Writer.append_async_interaction(writer, event, second_leaf)
  end

  test "replay rejects a raw receipt whose origin anchor belongs to a different sibling", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "raw-sibling-corruption.jsonl")
    writer = start_writer(path)
    first_anchor = append_user(writer, "first-user", "first-run")
    assert :ok = Writer.checkout(writer, nil, first_anchor)
    second_anchor = append_user(writer, "second-user", "second-run")
    GenServer.stop(writer)

    forged = received(first_anchor, "first-run", "crossed-sibling")
    assert :ok = JsonlFile.append(path, envelope("crossed-sibling-fact", second_anchor, forged))
    assert {:ok, entries} = JsonlFile.read(path)
    assert {:ok, snapshot} = Journal.replay(entries)
    assert Enum.any?(snapshot.diagnostics, &(&1.kind == :invalid_async_interaction))
    assert snapshot.async_interactions.items == %{}
    bytes = File.read!(path)
    reopened = start_writer(path)

    assert {:error, {:invalid_journal, _}} = Writer.async_interaction_state(reopened)

    assert {:error, {:invalid_journal, _}} =
             Writer.append(reopened, {:message_end, Message.user("later", "Later")})

    assert File.read!(path) == bytes
  end

  test "auxiliary facts preserve the conversation leaf and reopen recovers branch-filtered cards",
       %{
         tmp_dir: dir
       } do
    path = Path.join(dir, "branches.jsonl")
    writer = start_writer(path)
    first_anchor = append_user(writer, "first-user", "first-run")
    first = received(first_anchor, "first-run", "first")
    assert {:ok, first_fact_id} = Writer.append_async_interaction(writer, first, first_anchor)
    assert {:ok, %{active_leaf_id: ^first_anchor}} = Writer.flush(writer)

    assert {:ok, [%{leaf_id: ^first_anchor, active?: true, branch_point_id: nil}]} =
             Log.branch_summaries(path)

    assert :ok = Writer.checkout(writer, nil, first_anchor)
    second_anchor = append_user(writer, "second-user", "second-run")
    second = received(second_anchor, "second-run", "second")
    assert {:ok, second_fact_id} = Writer.append_async_interaction(writer, second, second_anchor)
    assert {:ok, state} = Writer.async_interaction_state(writer)
    item = state.projection.items[second["item_id"]]
    assert {:ok, reply} = AsyncInteractions.reply(reply_payload(), item)
    assert {:ok, saved} = AsyncInteractions.fact(item, "reply_saved", %{"reply" => reply})
    assert {:ok, saved_fact_id} = Writer.append_async_interaction(writer, saved, second_anchor)
    assert {:ok, %{active_leaf_id: ^second_anchor}} = Writer.flush(writer)
    assert {:ok, summaries} = Log.branch_summaries(path)

    assert Enum.map(summaries, &{&1.leaf_id, &1.active?}) ==
             [{second_anchor, true}, {first_anchor, false}]

    assert {:ok, entries} = JsonlFile.read(path)

    for id <- [first_fact_id, second_fact_id, saved_fact_id] do
      assert Enum.find(entries, &(&1["id"] == id))["type"] == "async_interaction"
    end

    assert Enum.find(entries, &(&1["id"] == first_fact_id))["parentId"] == first_anchor
    assert Enum.find(entries, &(&1["id"] == second_fact_id))["parentId"] == second_anchor
    assert Enum.find(entries, &(&1["id"] == saved_fact_id))["parentId"] == second_anchor
    assert {:ok, durable} = Log.snapshot(path)
    assert durable.active_leaf_id == second_anchor
    assert map_size(durable.async_interactions.items) == 1
    assert map_size(durable.async_interaction_history.items) == 2

    assert [visible] =
             AsyncInteractions.snapshot(durable.async_interactions, durable.branch_entry_ids)

    assert visible["item_id"] == second["item_id"]
    assert visible["status"] == "saved"

    GenServer.stop(writer)
    reopened = start_writer(path)
    assert {:ok, restored} = Writer.async_interaction_state(reopened)
    assert restored.leaf_id == second_anchor
    assert restored.projection == durable.async_interactions
    assert {:ok, ^summaries} = Log.branch_summaries(path)
    assert :ok = Writer.checkout(reopened, first_anchor, second_anchor)
    assert {:ok, selected} = Log.snapshot(path, leaf_id: first_anchor)

    assert [visible] =
             AsyncInteractions.snapshot(selected.async_interactions, selected.branch_entry_ids)

    assert visible["item_id"] == first["item_id"]

    assert {:ok, %{projection: projection, leaf_id: ^first_anchor}} =
             Writer.async_interaction_state(reopened)

    assert map_size(projection.items) == 1
    assert projection.events == durable.async_interaction_history.events
    assert {:ok, ^first_fact_id} = Writer.append_async_interaction(reopened, first, first_anchor)
  end

  test "malformed, conflicting and invalid-origin async history blocks all durable appends", %{
    tmp_dir: dir
  } do
    for corruption <- [:malformed, :conflict, :invalid_anchor] do
      path = Path.join(dir, "corrupt-#{corruption}.jsonl")
      writer = start_writer(path)
      anchor = append_user(writer, "root-user", "root-run")
      event = received(anchor, "root-run")
      assert {:ok, _} = Writer.append_async_interaction(writer, event, anchor)
      GenServer.stop(writer)

      invalid =
        case corruption do
          :malformed -> Map.put(event, "questions", [])
          :conflict -> put_in(event, ["questions", Access.at(0), "title"], "Changed")
          :invalid_anchor -> received("missing-anchor", "root-run", "bad-anchor")
        end

      assert :ok = JsonlFile.append(path, envelope("corrupt-fact", anchor, invalid))
      assert {:ok, snapshot} = Log.snapshot(path)
      assert Enum.any?(snapshot.diagnostics, &(&1.kind == :invalid_async_interaction))
      bytes = File.read!(path)
      reopened = start_writer(path)

      assert {:error, {:invalid_journal, diagnostics}} = Writer.async_interaction_state(reopened)
      assert Enum.any?(diagnostics, &(&1.kind == :invalid_async_interaction))

      assert {:error, {:invalid_journal, _}} =
               Writer.append(reopened, {:message_end, Message.user("later", "Later")})

      assert {:error, {:invalid_journal, _}} =
               Writer.append_async_interaction(
                 reopened,
                 received(anchor, "root-run", "later"),
                 anchor
               )

      assert File.read!(path) == bytes
      GenServer.stop(reopened)
    end
  end

  test "legacy invalid payload remains recoverable while async corruption is blocking", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "legacy-payload.jsonl")
    writer = start_writer(path)
    anchor = append_user(writer, "root-user", "root-run")
    GenServer.stop(writer)

    legacy = %{
      "type" => "model_change",
      "id" => "invalid-legacy-model",
      "parentId" => anchor,
      "timestamp" => "2026-10-25T00:00:00Z",
      "model" => 123
    }

    assert :ok = JsonlFile.append(path, legacy)
    assert {:ok, snapshot} = Log.snapshot(path)
    assert Enum.any?(snapshot.diagnostics, &(&1.kind == :invalid_payload))
    refute Enum.any?(snapshot.diagnostics, &(&1.kind == :invalid_async_interaction))
    reopened = start_writer(path)
    assert {:ok, _} = Writer.append(reopened, {:message_end, Message.user("later", "Later")})
  end

  test "copied foreign history is visible without granting reply or fact ownership", %{
    tmp_dir: dir
  } do
    original_path = Path.join(dir, "foreign.jsonl")
    original = start_writer(original_path, session_id: "foreign-session")
    anchor = append_user(original, "foreign-user", "foreign-run")
    event = received(anchor, "foreign-run", "foreign", "foreign-session")
    assert {:ok, _} = Writer.append_async_interaction(original, event, anchor)
    GenServer.stop(original)

    copied_path = Path.join(dir, "copied.jsonl")
    assert :ok = File.cp(original_path, copied_path)
    writer = start_writer(copied_path, session_id: "new-session")
    assert {:ok, state} = Writer.async_interaction_state(writer)
    assert state.session_id == "new-session"
    assert [item] = AsyncInteractions.snapshot(state.projection, [anchor])
    assert item["session_id"] == "foreign-session"
    assert item["questions"] == event["questions"]
    bytes = File.read!(copied_path)

    assert {:error, _} =
             AsyncInbox.prepare_reply(writer, item["item_id"], reply_payload(), anchor)

    assert {:ok, reply} = AsyncInteractions.reply(reply_payload(), item)
    assert {:ok, saved} = AsyncInteractions.fact(item, "reply_saved", %{"reply" => reply})

    assert {:error, :invalid_async_interaction_scope} =
             Writer.append_async_interaction(writer, event, anchor)

    assert {:error, :invalid_async_interaction_scope} =
             Writer.append_async_interaction(writer, saved, anchor)

    assert {:error, :async_interaction_conflict} =
             Writer.append_async_interaction(
               writer,
               %{saved | "session_id" => "new-session"},
               anchor
             )

    assert {:ok, ^state} = Writer.async_interaction_state(writer)
    assert File.read!(copied_path) == bytes
  end

  defp start_writer(path, opts \\ []) do
    options =
      Keyword.merge([storage_id: path, session_id: "session", cwd: Path.dirname(path)], opts)

    spec = Supervisor.child_spec({Writer, options}, id: make_ref(), restart: :temporary)
    start_supervised!(spec)
  end

  defp append_user(writer, id, run_id) do
    message = Message.user(id, "Prompt") |> Map.put(:metadata, %{turn_id: run_id})
    assert {:ok, anchor} = Writer.append(writer, {:message_end, message})
    anchor
  end

  defp received(anchor, run_id, suffix \\ "one", session_id \\ "session") do
    %{
      "version" => 1,
      "fact" => "received",
      "event_id" => "received:" <> suffix,
      "item_id" => "item:" <> suffix,
      "session_id" => session_id,
      "origin" => %{
        "run_id" => run_id,
        "incarnation" => 1,
        "turn_id" => "turn:" <> suffix,
        "step_id" => "step:" <> suffix,
        "attempt_id" => "attempt:" <> suffix,
        "invocation_id" => "invocation:" <> suffix,
        "tool_call_id" => "call:" <> suffix,
        "tool_name" => "request_user_input_async",
        "branch_entry_id" => anchor
      },
      "questions" => [%{"title" => "Continue?", "options" => ["A", "B"]}]
    }
  end

  defp reply_payload do
    %{"replyId" => "reply", "answers" => [%{"questionIndex" => 0, "answer" => "  原文\n"}]}
  end

  defp envelope(id, parent, event) do
    %{
      "type" => "async_interaction",
      "id" => id,
      "parentId" => parent,
      "timestamp" => "2026-10-25T00:00:00Z",
      "event" => event
    }
  end
end
