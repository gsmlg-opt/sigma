defmodule Sigma.Session.CompleteCompactionReplayTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.Message
  alias Sigma.Session.{Log, Writer}

  @moduletag :tmp_dir

  test "a complete compaction excludes the old batch and retains messages appended afterward",
       c do
    path = Path.join(c.tmp_dir, "complete.jsonl")
    {:ok, writer} = Writer.start_link(storage_id: path, session_id: "complete", cwd: c.tmp_dir)

    assert {:ok, original_leaf} =
             Writer.append(writer, {:message_end, Message.user("old", "Read a fixture")})

    original = File.read!(path)
    assert {:ok, _} = Writer.append(writer, {:compact, %{content: "The fixture was read."}, nil})
    assert {:ok, first} = Log.snapshot(path)
    assert first.diagnostics == []
    assert [%{role: :compaction_summary}] = first.context_messages
    assert {:ok, _} = Writer.append(writer, {:message_end, Message.user("new", "Continue")})
    GenServer.stop(writer)

    assert {:ok, snapshot} = Log.snapshot(path)
    assert snapshot.diagnostics == []
    assert [%{role: :compaction_summary}, %{id: "new"}] = snapshot.context_messages
    assert String.starts_with?(File.read!(path), original)

    bytes = File.read!(path)
    assert {:ok, ^snapshot} = Log.snapshot(path)
    assert File.read!(path) == bytes
    assert {:ok, original_branch} = Log.snapshot(path, leaf_id: original_leaf)
    assert [%{id: "old"}] = original_branch.context_messages
    assert original_branch.compaction == nil
    assert File.read!(path) == bytes

    assert {:ok, entries} = Sigma.Session.Storage.JsonlFile.read(path)

    invalid =
      Enum.map(entries, fn
        %{"type" => "compaction", "id" => id} = entry -> Map.put(entry, "firstKeptEntryId", id)
        entry -> entry
      end)

    assert {:ok, invalid_snapshot} = Sigma.Session.Journal.replay(invalid)
    assert Enum.any?(invalid_snapshot.diagnostics, &(&1.reason == :invalid_compaction_target))
  end
end
