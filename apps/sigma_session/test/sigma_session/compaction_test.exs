defmodule Sigma.Session.CompactionTest do
  use ExUnit.Case

  alias Sigma.Session.Log
  alias Sigma.Agent.Message

  @test_storage "test_session_compaction.jsonl"

  setup do
    on_exit(fn ->
      File.rm(@test_storage)
    end)
  end

  test "compact appends entry and replay handles it" do
    # 1. Create session with some messages
    Log.persist_event(@test_storage, {:agent_start, "/tmp"})
    msg1 = Message.user("m1", "hello")
    Log.persist_event(@test_storage, {:message_end, msg1})
    msg2 = Message.assistant("m2", %{content: "hi"})
    Log.persist_event(@test_storage, {:message_end, msg2})
    msg3 = Message.user("m3", "keep me")
    Log.persist_event(@test_storage, {:message_end, msg3})

    # 2. Compact, keeping only m3
    Log.compact(@test_storage, "Summary of early conversation", "m3")

    # 3. Check storage
    {:ok, entries} = Sigma.Session.Storage.JsonlFile.read(@test_storage)
    assert Enum.any?(entries, fn e -> e["type"] == "compaction" end)

    # 4. Replay and verify filtering
    {:ok, messages} = Log.replay(@test_storage)
    
    # Should have compaction_summary + m3
    assert Enum.count(messages) == 2
    assert Enum.at(messages, 0).role == :compaction_summary
    assert Enum.at(messages, 0).content == "Summary of early conversation"
    assert Enum.at(messages, 1).id == "m3"
  end

  test "multiple compactions" do
    Log.persist_event(@test_storage, {:agent_start, "/tmp"})
    Log.persist_event(@test_storage, {:message_end, Message.user("m1", "1")})
    Log.persist_event(@test_storage, {:message_end, Message.user("m2", "2")})
    
    Log.compact(@test_storage, "Summary 1", "m2")
    
    Log.persist_event(@test_storage, {:message_end, Message.user("m3", "3")})
    
    Log.compact(@test_storage, "Summary 2", "m3")
    
    {:ok, messages} = Log.replay(@test_storage)
    
    # Should have Summary 2 + m3
    assert Enum.count(messages) == 2
    assert Enum.at(messages, 0).content == "Summary 2"
    assert Enum.at(messages, 1).id == "m3"
  end
end
