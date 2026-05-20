defmodule PiSession.LogTest do
  use ExUnit.Case
  alias PiSession.Log
  alias PiAgent.Message

  @storage_path "test_session.jsonl"

  setup do
    on_exit(fn ->
      File.rm(@storage_path)
    end)
    :ok
  end

  test "persists agent_start (header) and message_end events" do
    # 1. Persist agent_start
    assert :ok == Log.persist_event(@storage_path, {:agent_start, "/tmp"})

    # 2. Persist a message
    msg = Message.user("user_1", "Hello")
    assert :ok == Log.persist_event(@storage_path, {:message_end, msg})

    # 3. Replay
    {:ok, messages} = Log.replay(@storage_path)
    assert length(messages) == 1
    [replayed_msg] = messages
    assert replayed_msg.id == "user_1"
    assert replayed_msg.role == :user
    assert replayed_msg.content == "Hello"
  end

  test "maintains parentId in linear fashion" do
    Log.persist_event(@storage_path, {:agent_start, "/tmp"})

    msg1 = Message.user("user_1", "One")
    Log.persist_event(@storage_path, {:message_end, msg1})

    msg2 = Message.assistant("assistant_1", %{content: [%{type: :text, text: "Two"}]})
    Log.persist_event(@storage_path, {:message_end, msg2})

    # Check entries directly
    {:ok, entries} = PiSession.Storage.JsonlFile.read(@storage_path)
    assert length(entries) == 3
    [header, e1, e2] = entries

    assert header["type"] == "session"
    assert e1["type"] == "message"
    assert e1["parentId"] == nil

    assert e2["type"] == "message"
    assert e2["parentId"] == e1["id"]
  end

  test "reconstructs complex assistant messages" do
    Log.persist_event(@storage_path, {:agent_start, "/tmp"})

    msg = %Message{
      id: "assistant_1",
      role: :assistant,
      content: [
        %{type: :thinking, thinking: "I should say hello", redacted: false},
        %{type: :text, text: "Hello!"}
      ],
      model: "gpt-4",
      usage: %{
        input: 10,
        output: 20,
        total_tokens: 30,
        cost: %{total: 0.001}
      }
    }

    Log.persist_event(@storage_path, {:message_end, msg})

    {:ok, [replayed]} = Log.replay(@storage_path)
    assert replayed.id == "assistant_1"
    assert replayed.role == :assistant
    assert is_list(replayed.content)
    assert length(replayed.content) == 2
    [c1, c2] = replayed.content
    assert c1.type == :thinking
    assert c2.type == :text
    assert replayed.usage.input == 10
    assert replayed.usage.cost.total == 0.001
  end
end
