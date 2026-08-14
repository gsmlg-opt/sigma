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

  defmodule ReadFailureStorage do
    @behaviour Sigma.Session.Storage

    @impl true
    def append(_path, _entry), do: :ok

    @impl true
    def read(_path), do: {:error, :unavailable}
  end

  defmodule AppendFailureStorage do
    @behaviour Sigma.Session.Storage

    @impl true
    def append(_path, _entry), do: {:error, :disk_full}

    @impl true
    def read(_path) do
      {:ok,
       [
         %{
           "type" => "session",
           "version" => 3,
           "id" => "session",
           "timestamp" => "2026-08-11T00:00:00Z",
           "cwd" => "/tmp"
         }
       ]}
    end
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

  @tag :tmp_dir
  test "persists a model change on the active journal leaf", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "model-change.jsonl")

    assert :ok = Log.persist_event(path, {:agent_start, "/tmp"})
    assert :ok = Log.persist_event(path, {:message_end, Message.user("user_1", "Hello")})

    assert {:ok, entry_id} = Log.append_model_change(path, "anthropic", "claude/opus")

    assert {:ok, [_header, message_entry, model_entry]} =
             Sigma.Session.Storage.JsonlFile.read(path)

    assert %{
             "type" => "model_change",
             "id" => ^entry_id,
             "model" => "anthropic/claude/opus",
             "parentId" => parent_id,
             "timestamp" => timestamp
           } = model_entry

    assert parent_id == message_entry["id"]
    assert {:ok, _timestamp, 0} = DateTime.from_iso8601(timestamp)

    assert {:ok, snapshot} = Log.snapshot(path)

    assert %{
             active_leaf_id: ^entry_id,
             provider_id: "anthropic",
             model_id: "claude/opus"
           } = snapshot
  end

  @tag :tmp_dir
  test "parents a model change directly to a header-only journal", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "header-only-model-change.jsonl")

    assert :ok = Log.persist_event(path, {:agent_start, "/tmp"})
    assert {:ok, entry_id} = Log.append_model_change(path, "anthropic", "opus")

    assert {:ok, [_header, model_entry]} = Sigma.Session.Storage.JsonlFile.read(path)
    assert %{"id" => ^entry_id, "parentId" => nil} = model_entry
  end

  @tag :tmp_dir
  test "parents the next persisted message to the model change", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "message-after-model-change.jsonl")

    assert :ok = Log.persist_event(path, {:agent_start, "/tmp"})
    assert {:ok, model_entry_id} = Log.append_model_change(path, "anthropic", "opus")
    assert :ok = Log.persist_event(path, {:message_end, Message.user("user_1", "Hello")})

    assert {:ok, [_header, _model_entry, message_entry]} =
             Sigma.Session.Storage.JsonlFile.read(path)

    assert message_entry["parentId"] == model_entry_id

    assert {:ok, snapshot} = Log.snapshot(path)
    assert %{provider_id: "anthropic", model_id: "opus"} = snapshot
  end

  @tag :tmp_dir
  test "rejects a model change when the journal has no session header", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "missing-header.jsonl")

    assert {:error, {:invalid_journal, :missing_session_header}} =
             Log.append_model_change(path, "anthropic", "opus")

    assert {:ok, []} = Sigma.Session.Storage.JsonlFile.read(path)
  end

  @tag :tmp_dir
  test "rejects invalid model change identifiers without writing", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "invalid-model-change.jsonl")
    assert :ok = Log.persist_event(path, {:agent_start, "/tmp"})
    original = File.read!(path)

    assert {:error, {:invalid_model_change, :provider_id}} =
             Log.append_model_change(path, "", "opus")

    assert {:error, {:invalid_model_change, :provider_id}} =
             Log.append_model_change(path, nil, "opus")

    assert {:error, {:invalid_model_change, :model_id}} =
             Log.append_model_change(path, "anthropic", "")

    assert {:error, {:invalid_model_change, :model_id}} =
             Log.append_model_change(path, "anthropic", nil)

    assert File.read!(path) == original
  end

  test "tags storage failures while appending a model change" do
    assert {:error, {:storage_read_failed, :unavailable}} =
             Log.append_model_change("ignored", "anthropic", "opus", ReadFailureStorage)

    assert {:error, {:storage_append_failed, :disk_full}} =
             Log.append_model_change("ignored", "anthropic", "opus", AppendFailureStorage)
  end

  @tag :tmp_dir
  test "refuses to append a model change to a corrupt journal", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "corrupt-model-change.jsonl")
    assert :ok = Log.persist_event(path, {:agent_start, "/tmp"})
    File.write!(path, "{torn", [:append])
    original = File.read!(path)

    assert {:error, {:invalid_journal, diagnostics}} =
             Log.append_model_change(path, "anthropic", "opus")

    assert [%{kind: :trailing_incomplete_json, line: 2}] = diagnostics
    assert File.read!(path) == original
  end

  @tag :tmp_dir
  test "appends a model change after a recoverable payload diagnostic", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "recoverable-model-change.jsonl")
    assert :ok = Log.persist_event(path, {:agent_start, "/tmp"})

    assert :ok =
             Sigma.Session.Storage.JsonlFile.append(path, %{
               "type" => "model_change",
               "id" => "invalid-model",
               "parentId" => nil,
               "timestamp" => "2026-08-11T00:00:00Z",
               "model" => "invalid"
             })

    assert {:ok, entry_id} = Log.append_model_change(path, "anthropic", "opus")
    assert {:ok, snapshot} = Log.snapshot(path)

    assert %{
             active_leaf_id: ^entry_id,
             provider_id: "anthropic",
             model_id: "opus"
           } = snapshot

    assert [%{kind: :invalid_payload, entry_id: "invalid-model", reason: :invalid_model}] =
             snapshot.diagnostics
  end

  @tag :tmp_dir
  test "refuses a model change after interior invalid JSON", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "interior-invalid-json.jsonl")
    assert :ok = Log.persist_event(path, {:agent_start, "/tmp"})
    File.write!(path, "{invalid}\n", [:append])
    original = File.read!(path)

    assert {:error, {:invalid_journal, diagnostics}} =
             Log.append_model_change(path, "anthropic", "opus")

    assert [%{kind: :invalid_json, line: 2}] = diagnostics
    assert File.read!(path) == original
  end

  @tag :tmp_dir
  test "refuses a model change after a broken parent", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "broken-parent.jsonl")
    assert :ok = Log.persist_event(path, {:agent_start, "/tmp"})

    assert :ok =
             Sigma.Session.Storage.JsonlFile.append(path, %{
               "type" => "model_change",
               "id" => "orphan",
               "parentId" => "missing",
               "timestamp" => "2026-08-11T00:00:00Z",
               "model" => "anthropic/opus"
             })

    original = File.read!(path)

    assert {:error, {:invalid_journal, diagnostics}} =
             Log.append_model_change(path, "anthropic", "opus")

    assert [%{kind: :invalid_entry, entry_id: "orphan", reason: :missing_parent}] = diagnostics
    assert File.read!(path) == original
  end

  @tag :tmp_dir
  test "refuses a model change after a duplicate entry ID", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "duplicate-entry.jsonl")
    assert :ok = Log.persist_event(path, {:agent_start, "/tmp"})

    entry = %{
      "type" => "model_change",
      "id" => "duplicate",
      "parentId" => nil,
      "timestamp" => "2026-08-11T00:00:00Z",
      "model" => "anthropic/opus"
    }

    assert :ok = Sigma.Session.Storage.JsonlFile.append(path, entry)
    assert :ok = Sigma.Session.Storage.JsonlFile.append(path, entry)
    original = File.read!(path)

    assert {:error, {:invalid_journal, diagnostics}} =
             Log.append_model_change(path, "anthropic", "opus")

    assert [%{kind: :duplicate_id, entry_id: "duplicate", reason: :duplicate_id}] = diagnostics
    assert File.read!(path) == original
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
