defmodule Sigma.Session.ContextWindowReplayTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.Message
  alias Sigma.Session.{Log, Writer}
  alias Sigma.Session.Storage.JsonlFile

  @moduletag :tmp_dir

  defmodule FailingWindowStorage do
    @behaviour Sigma.Session.Storage

    defdelegate read(path), to: JsonlFile
    defdelegate read_with_diagnostics(path), to: JsonlFile
    def append(_path, %{"type" => "context_window"}), do: {:error, :disk_full}
    def append(path, entry), do: JsonlFile.append(path, entry)
  end

  test "a committed window preserves display history and restores only fresh provider history", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "window.jsonl")
    writer = start_writer(path)
    assert {:ok, _} = Writer.append(writer, {:message_end, Message.user("old", "Old context")})
    boundary = boundary("reset-turn", 2)
    assert {:ok, boundary_id} = Writer.append(writer, {:context_window_started, boundary})
    assert {:ok, _} = Writer.append(writer, {:message_end, Message.user("new", "New context")})

    assert {:ok, snapshot} = Log.snapshot(path)
    assert ids(snapshot.messages) == ["old", "new"]
    assert ids(Map.get(snapshot, :context_messages, [])) == ["new"]
    assert Map.get(snapshot, :context_window) == boundary
    assert snapshot.compaction == nil

    assert {:ok, entries} = JsonlFile.read(path)
    assert Enum.find(entries, &(&1["id"] == boundary_id))["type"] == "context_window"
    refute Enum.any?(entries, &(&1["type"] == "compaction"))

    GenServer.stop(writer)
    restarted = start_writer(path)

    assert {:ok, _} =
             Writer.append(restarted, {:message_end, Message.user("later", "Later turn")})

    assert {:ok, restored} = Log.snapshot(path)
    assert ids(restored.messages) == ["old", "new", "later"]
    assert ids(Map.get(restored, :context_messages, [])) == ["new", "later"]
    assert Map.get(restored, :context_window) == boundary
    GenServer.stop(restarted)
  end

  test "duplicate window delivery is idempotent before and after writer restart", %{tmp_dir: dir} do
    path = Path.join(dir, "duplicate.jsonl")
    writer = start_writer(path)
    event = {:context_window_started, boundary("reset-turn", 2)}

    assert {:ok, id} = Writer.append(writer, event)

    assert {:ok, message_id} =
             Writer.append(writer, {:message_end, Message.user("new", "New context")})

    assert {:ok, ^id} = Writer.append(writer, event)
    assert {:ok, %{active_leaf_id: ^message_id}} = Writer.flush(writer)
    GenServer.stop(writer)

    restarted = start_writer(path)
    assert {:ok, ^id} = Writer.append(restarted, event)
    assert {:ok, %{active_leaf_id: ^message_id}} = Writer.flush(restarted)
    assert {:ok, snapshot} = Log.snapshot(path)
    assert ids(Map.get(snapshot, :context_messages, [])) == ["new"]
    assert {:ok, entries} = JsonlFile.read(path)
    assert Enum.count(entries, &(&1["type"] == "context_window")) == 1
    GenServer.stop(restarted)
  end

  test "a later run may start at window two without reviving older context", %{tmp_dir: dir} do
    path = Path.join(dir, "new-run.jsonl")
    writer = start_writer(path)
    assert {:ok, _} = Writer.append(writer, {:context_window_started, boundary("first-run", 5)})
    assert {:ok, _} = Writer.append(writer, {:message_end, Message.user("first", "First window")})
    latest = boundary("second-run", 2)
    assert {:ok, _} = Writer.append(writer, {:context_window_started, latest})

    assert {:ok, _} =
             Writer.append(writer, {:message_end, Message.user("second", "Second window")})

    assert {:ok, snapshot} = Log.snapshot(path)
    assert ids(snapshot.messages) == ["first", "second"]
    assert ids(Map.get(snapshot, :context_messages, [])) == ["second"]
    assert Map.get(snapshot, :context_window) == latest
    GenServer.stop(writer)
  end

  test "a failed boundary append cannot acknowledge or change the active context", %{tmp_dir: dir} do
    path = Path.join(dir, "failed-window.jsonl")

    {:ok, writer} =
      Writer.start_link(
        storage_id: path,
        storage_mod: FailingWindowStorage,
        session_id: "context-test",
        cwd: "/repo"
      )

    assert {:ok, message_id} =
             Writer.append(writer, {:message_end, Message.user("old", "Original")})

    assert {:error, {:storage_append_failed, :disk_full}} =
             Writer.append(writer, {:context_window_started, boundary("reset", 2)})

    assert {:ok, %{active_leaf_id: ^message_id}} = Writer.flush(writer)
    assert {:ok, snapshot} = Log.snapshot(path)
    assert Map.get(snapshot, :context_window) == nil
    assert ids(Map.get(snapshot, :context_messages, [])) == ["old"]
    GenServer.stop(writer)
  end

  test "an older window from the same run cannot move the active boundary backward", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "stale.jsonl")
    writer = start_writer(path)
    latest = boundary("reset-turn", 3)
    assert {:ok, _} = Writer.append(writer, {:context_window_started, latest})

    assert {:error, _} =
             Writer.append(writer, {:context_window_started, boundary("reset-turn", 2)})

    assert {:ok, snapshot} = Log.snapshot(path)
    assert Map.get(snapshot, :context_window) == latest
    assert {:ok, entries} = JsonlFile.read(path)
    assert Enum.count(entries, &(&1["type"] == "context_window")) == 1
    GenServer.stop(writer)
  end

  test "retry before a boundary selects the original branch without its reset", %{tmp_dir: dir} do
    path = Path.join(dir, "retry-before.jsonl")
    writer = start_writer(path)

    assert {:ok, original_id} =
             Writer.append(writer, {:message_end, Message.user("old", "Original")})

    assert {:ok, boundary_id} =
             Writer.append(writer, {:context_window_started, boundary("reset", 2)})

    assert :ok = Writer.checkout(writer, original_id, boundary_id)
    assert {:ok, selected} = Writer.context_snapshot(writer)
    assert selected.context_window == nil
    assert ids(selected.context_messages) == ["old"]
    assert {:ok, _} = Writer.append(writer, {:message_end, Message.user("retry", "Retry")})

    assert {:ok, retried} = Log.snapshot(path)
    assert ids(retried.messages) == ["old", "retry"]
    assert ids(Map.get(retried, :context_messages, [])) == ["old", "retry"]
    assert Map.get(retried, :context_window) == nil

    assert {:ok, original} = Log.snapshot(path, leaf_id: boundary_id)
    assert ids(original.messages) == ["old"]
    assert Map.get(original, :context_messages) == []
    assert Map.get(original, :context_window) == boundary("reset", 2)
    GenServer.stop(writer)
  end

  test "retry after a boundary excludes sibling windows from provider history", %{tmp_dir: dir} do
    path = Path.join(dir, "retry-after.jsonl")
    writer = start_writer(path)
    assert {:ok, _} = Writer.append(writer, {:message_end, Message.user("old", "Original")})
    first = boundary("first", 2)
    assert {:ok, first_id} = Writer.append(writer, {:context_window_started, first})

    assert {:ok, sibling_id} =
             Writer.append(writer, {:context_window_started, boundary("sibling", 2)})

    assert :ok = Writer.checkout(writer, first_id, sibling_id)
    assert {:ok, _} = Writer.append(writer, {:message_end, Message.user("retry", "Retry")})

    assert {:ok, retried} = Log.snapshot(path)
    assert ids(retried.messages) == ["old", "retry"]
    assert ids(Map.get(retried, :context_messages, [])) == ["retry"]
    assert Map.get(retried, :context_window) == first
    GenServer.stop(writer)
  end

  test "later compaction summarizes only the active window and retains older display history", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "window-compaction.jsonl")
    writer = start_writer(path)

    assert {:ok, _} =
             Writer.append(writer, {:message_end, Message.user("old", "Old display history")})

    assert {:ok, _} = Writer.append(writer, {:context_window_started, boundary("reset", 2)})

    assert {:ok, _} =
             Writer.append(writer, {:message_end, Message.user("fresh", "Fresh context")})

    assert {:ok, _} = Writer.append(writer, {:message_end, Message.user("kept", "Keep this")})
    assert {:ok, _} = Writer.append(writer, {:compact, %{content: "Fresh summary"}, "kept"})
    assert {:ok, snapshot} = Log.snapshot(path)

    assert [%{id: "old"}, %{role: :compaction_summary, content: "Fresh summary"}, %{id: "kept"}] =
             snapshot.messages

    assert [%{role: :compaction_summary, content: "Fresh summary"}, %{id: "kept"}] =
             snapshot.context_messages

    GenServer.stop(writer)
  end

  test "multiple resets retain earlier display windows around intermediate compaction", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "multiple-window-compaction.jsonl")
    writer = start_writer(path)

    assert {:ok, _} =
             Writer.append(writer, {:message_end, Message.user("original", "Original display")})

    assert {:ok, _} = Writer.append(writer, {:context_window_started, boundary("first", 2)})

    assert {:ok, _} =
             Writer.append(writer, {:message_end, Message.user("fresh", "Fresh context")})

    assert {:ok, _} = Writer.append(writer, {:message_end, Message.user("kept", "Keep this")})
    assert {:ok, _} = Writer.append(writer, {:compact, %{content: "Fresh summary"}, "kept"})
    assert {:ok, _} = Writer.append(writer, {:context_window_started, boundary("second", 2)})

    assert {:ok, _} =
             Writer.append(writer, {:message_end, Message.user("latest", "Latest context")})

    assert {:ok, snapshot} = Log.snapshot(path)

    assert [%{id: "original"}, %{role: :compaction_summary}, %{id: "kept"}, %{id: "latest"}] =
             snapshot.messages

    assert [%{id: "latest"}] = snapshot.context_messages
    GenServer.stop(writer)
  end

  defp start_writer(path) do
    {:ok, writer} = Writer.start_link(storage_id: path, session_id: "context-test", cwd: "/repo")
    writer
  end

  defp boundary(run_id, window), do: %{run_id: run_id, incarnation: 1, window: window}
  defp ids(messages), do: Enum.map(messages, & &1.id)
end
