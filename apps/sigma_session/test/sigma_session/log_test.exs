defmodule Sigma.Session.LogTest do
  use ExUnit.Case
  alias Sigma.Session.Log
  alias Sigma.Agent.Message

  defmodule ReadOnlyStorage do
    @behaviour Sigma.Session.Storage

    @impl true
    def append(path, entry), do: Sigma.Session.Storage.JsonlFile.append(path, entry)

    @impl true
    def read(path), do: Sigma.Session.Storage.JsonlFile.read(path)
  end

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
    {:ok, entries} = Sigma.Session.Storage.JsonlFile.read(@storage_path)
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

  @tag :tmp_dir
  test "snapshot selects an explicit active leaf while replay keeps the latest leaf", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "branched.jsonl")

    entries = [
      %{
        "type" => "session",
        "version" => 3,
        "id" => "session",
        "timestamp" => "2026-07-21T00:00:00Z",
        "cwd" => "/repo"
      },
      %{
        "type" => "message",
        "id" => "root",
        "parentId" => nil,
        "timestamp" => "2026-07-21T00:00:01Z",
        "message" => %{
          "id" => "message-root",
          "role" => "user",
          "content" => "root",
          "timestamp" => 1
        }
      },
      %{
        "type" => "message",
        "id" => "left",
        "parentId" => "root",
        "timestamp" => "2026-07-21T00:00:02Z",
        "message" => %{
          "id" => "message-left",
          "role" => "assistant",
          "content" => "left",
          "timestamp" => 2
        }
      },
      %{
        "type" => "message",
        "id" => "right",
        "parentId" => "root",
        "timestamp" => "2026-07-21T00:00:03Z",
        "message" => %{
          "id" => "message-right",
          "role" => "assistant",
          "content" => "right",
          "timestamp" => 3
        }
      }
    ]

    Enum.each(entries, &Sigma.Session.Storage.JsonlFile.append(path, &1))

    assert {:ok, snapshot} = Log.snapshot(path, leaf_id: "left")
    assert snapshot.active_leaf_id == "left"
    assert Enum.map(snapshot.messages, & &1.id) == ["message-root", "message-left"]

    assert {:ok, latest_messages} = Log.replay(path, ReadOnlyStorage)
    assert Enum.map(latest_messages, & &1.id) == ["message-root", "message-right"]
  end

  @tag :tmp_dir
  test "snapshot includes storage diagnostics while replay remains tolerant", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "torn.jsonl")

    caller_diagnostic = %{
      kind: :invalid_entry,
      entry_index: 0,
      entry_id: nil,
      reason: :caller_diagnostic
    }

    File.write!(path, [
      Jason.encode!(%{
        "type" => "session",
        "version" => 3,
        "id" => "session",
        "timestamp" => "2026-07-21T00:00:00Z",
        "cwd" => "/repo"
      }),
      "\n{torn"
    ])

    assert {:ok, snapshot} = Log.snapshot(path, diagnostics: [caller_diagnostic])

    assert snapshot.diagnostics == [
             %{kind: :trailing_incomplete_json, line: 2},
             caller_diagnostic
           ]

    assert {:ok, []} = Log.replay(path)
  end
end
