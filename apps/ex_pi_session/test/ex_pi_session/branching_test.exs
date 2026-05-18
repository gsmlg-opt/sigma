defmodule ExPiSession.BranchingTest do
  use ExUnit.Case

  alias ExPiSession.Log
  alias ExPiAgent.Message

  @test_storage "test_session_source.jsonl"
  @target_storage "test_session_target.jsonl"

  setup do
    on_exit(fn ->
      File.rm(@test_storage)
      File.rm(@target_storage)
    end)
  end

  test "fork_at_message at 0-based index 3 of 10-message session yields 4 messages" do
    Log.persist_event(@test_storage, {:agent_start, "/tmp"})

    ids =
      for i <- 0..9 do
        id = "msg_#{i}"
        msg = Message.user(id, "message #{i}")
        Log.persist_event(@test_storage, {:message_end, msg})
        id
      end

    target_id = Enum.at(ids, 3)
    {:ok, _} = Log.fork_at_message(@test_storage, @target_storage, target_id, "/tmp")

    {:ok, messages} = Log.replay(@target_storage)
    assert length(messages) == 4
    assert Enum.at(messages, 0).id == Enum.at(ids, 0)
    assert Enum.at(messages, 3).id == target_id
  end

  test "fork copies prefix and appends new header" do
    # 1. Create source session
    Log.persist_event(@test_storage, {:agent_start, "/tmp"})
    msg1 = Message.user("m1", "hello")
    Log.persist_event(@test_storage, {:message_end, msg1})
    msg2 = Message.assistant("m2", %{content: "hi"})
    Log.persist_event(@test_storage, {:message_end, msg2})
    msg3 = Message.user("m3", "how are you?")
    Log.persist_event(@test_storage, {:message_end, msg3})

    # 2. Fork at index 1 (session header + msg1)
    # entries: [session_header, m1, m2, m3]
    # index 1 means [session_header, m1]
    {:ok, new_session_id} = Log.fork(@test_storage, @target_storage, 1, "/tmp")

    # 3. Check target storage
    {:ok, target_entries} = ExPiSession.Storage.JsonlFile.read(@target_storage)

    assert Enum.count(target_entries) == 3
    assert Enum.at(target_entries, 0)["type"] == "session"
    assert Enum.at(target_entries, 1)["type"] == "message"
    assert Enum.at(target_entries, 1)["message"]["id"] == "m1"
    assert Enum.at(target_entries, 2)["type"] == "session"
    assert Enum.at(target_entries, 2)["id"] == new_session_id
    assert Enum.at(target_entries, 2)["parentSession"] != nil

    # 4. Replay target
    {:ok, messages} = Log.replay(@target_storage)
    assert Enum.count(messages) == 1
    assert Enum.at(messages, 0).id == "m1"
  end
end
