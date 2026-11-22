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

  @tag :tmp_dir
  test "resolves a retry checkpoint without appending or moving the active leaf", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "retry-checkpoint.jsonl")

    user = %{
      Message.user("user-1", [%{type: :text, text: "Retry this"}])
      | attachments: [%{"name" => "context.txt", "size" => 12}],
        metadata: %{turn_id: "turn-original"}
    }

    assistant = Message.assistant("assistant-1", %{content: "old answer"})

    assert :ok = Log.persist_event(path, {:agent_start, "/tmp"})
    assert :ok = Log.persist_event(path, {:message_end, user})
    assert :ok = Log.persist_event(path, {:message_end, assistant})
    assert {:ok, before} = Log.snapshot(path)
    before_bytes = File.read!(path)
    assert {:ok, checkpoint} = Log.retry_checkpoint(path, "user-1")
    assert checkpoint.message_id == "user-1"
    assert checkpoint.retry_of_turn_id == "turn-original"
    assert checkpoint.content == [%{type: :text, text: "Retry this"}]
    assert checkpoint.attachments == [%{"name" => "context.txt", "size" => 12}]
    assert checkpoint.message.content == checkpoint.content
    assert checkpoint.message.attachments == checkpoint.attachments
    assert checkpoint.source_entry_id in before.branch_entry_ids
    assert checkpoint.checkpoint_entry_id in [nil | before.branch_entry_ids]
    assert checkpoint.source_leaf_id == before.active_leaf_id
    assert checkpoint.branch_entry_ids == Enum.take(before.branch_entry_ids, 1)
    assert {:ok, after_snapshot} = Log.snapshot(path)
    assert after_snapshot.active_leaf_id == before.active_leaf_id
    assert File.read!(path) == before_bytes
  end

  @tag :tmp_dir
  test "rejects a non-user retry target", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "retry-invalid.jsonl")
    assert :ok = Log.persist_event(path, {:agent_start, "/tmp"})

    assert :ok =
             Log.persist_event(path, {:message_end, Message.assistant("a", %{content: "answer"})})

    assert {:error, :not_retryable} = Log.retry_checkpoint(path, "a")
  end

  @tag :tmp_dir
  test "round trips metrics facts without changing the conversation leaf", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "metrics.jsonl")

    assert :ok = Log.persist_event(path, {:agent_start, "/tmp"})
    assert :ok = Log.persist_event(path, {:message_end, Message.user("user-1", "Hello")})
    assert {:ok, _model_entry_id} = Log.append_model_change(path, "anthropic", "opus")

    assert :ok =
             Log.persist_event(
               path,
               {:metrics, :request_finished,
                %{
                  request_id: "req-1",
                  session_id: "session-1",
                  revision: 1,
                  status: :completed,
                  input_tokens_total: 10,
                  output_tokens_total: 20,
                  elapsed_ms: 1_000
                }}
             )

    assert :ok =
             Log.persist_event(
               path,
               {:metrics, :tool_finished,
                %{tool_id: "tool-1", turn_id: "turn-1", status: :completed, elapsed_ms: 10}}
             )

    assert {:ok, entries} = Sigma.Session.Storage.JsonlFile.read(path)
    model_entry = Enum.find(entries, &(&1["type"] == "model_change"))
    assert {:ok, snapshot} = Log.snapshot(path)
    assert snapshot.active_leaf_id == model_entry["id"]
    assert snapshot.provider_id == "anthropic"
    assert snapshot.model_id == "opus"
    assert %{requests: %{"req-1" => request}} = snapshot.metrics
    assert request.output_tokens_total == 20
    assert [%{tool_id: "tool-1"}] = snapshot.metrics.tools |> Map.values()
    assert snapshot.metrics.facts == 2
    assert snapshot.messages |> Enum.map(& &1.id) == ["user-1"]
  end

  @tag :tmp_dir
  test "round trips operation completion records without changing the conversation leaf", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "operation.jsonl")

    assert :ok = Log.persist_event(path, {:agent_start, "/tmp"})
    assert :ok = Log.persist_event(path, {:message_end, Message.user("user-1", "Hello")})
    {:ok, before} = Log.snapshot(path)

    assert :ok =
             Log.persist_event(path, {
               :operation_finished,
               %{
                 operation_id: "op-1",
                 operation: :fork,
                 source_session_id: "session-1",
                 status: :completed,
                 result: %{session_id: "target-1"}
               }
             })

    assert {:ok,
            [%{operation_id: "op-1", status: :completed, result: %{"session_id" => "target-1"}}]} =
             Log.operation_results(path)

    assert {:ok, after_snapshot} = Log.snapshot(path)
    assert after_snapshot.active_leaf_id == before.active_leaf_id
    assert after_snapshot.messages |> Enum.map(& &1.id) == ["user-1"]
  end

  @tag :tmp_dir
  test "persists and replays rich text and image content", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "rich-content.jsonl")

    content = [
      %{type: :text, text: "Describe"},
      %{type: :image, mime_type: "image/png", data: "iVBORw0KGgo="}
    ]

    message = Message.user("user_rich", content)

    assert :ok = Log.persist_event(path, {:message_end, message})
    assert File.read!(path) =~ ~s("type":"image")
    assert {:ok, [replayed]} = Log.replay(path)
    assert replayed.content == content
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
  test "appends a model change after replay repairs an orphaned tool call", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "repaired-model-change.jsonl")
    assert :ok = Log.persist_event(path, {:agent_start, "/tmp"})

    assistant = %Message{
      id: "assistant",
      role: :assistant,
      content: [%{type: :tool_call, id: "orphan", name: "bash", arguments: %{}}],
      timestamp: 1
    }

    assert :ok = Log.persist_event(path, {:message_end, assistant})
    assert {:ok, entry_id} = Log.append_model_change(path, "anthropic", "opus")
    assert {:ok, snapshot} = Log.snapshot(path)
    assert snapshot.active_leaf_id == entry_id

    assert [%{kind: :message_repair, reason: {:orphaned_tool_call, "orphan"}}] =
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
  test "lists bounded retry branch summaries without treating metrics siblings as leaves", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "branch-summaries.jsonl")

    entries = [
      %{
        "type" => "session",
        "version" => 3,
        "id" => "session",
        "timestamp" => "2026-09-09T00:00:00Z",
        "cwd" => "/repo"
      },
      message_entry("root", nil, "user-root", "user", "Try this", %{
        "turn_id" => "turn-original"
      }),
      message_entry(
        "original-answer",
        "root",
        "assistant-original",
        "assistant",
        "Original answer that is longer than the summary limit",
        %{"turn_id" => "turn-original"}
      ),
      %{
        "type" => "metrics",
        "fact" => "request_started",
        "id" => "metrics-sibling",
        "parentId" => "original-answer",
        "timestamp" => "2026-09-09T00:00:03Z",
        "data" => %{"request_id" => "request-original", "status" => "running"}
      },
      message_entry(
        "retry-user",
        "root",
        "user-retry",
        "user",
        [
          %{"type" => "image", "data" => "private-image-data", "mime_type" => "image/png"},
          %{"type" => "text", "text" => "Retry with a safer answer"}
        ],
        %{"turn_id" => "turn-retry", "retry_of_turn_id" => "turn-original"}
      ),
      message_entry(
        "retry-answer",
        "retry-user",
        "assistant-retry",
        "assistant",
        [%{"type" => "text", "text" => "Replacement answer"}],
        %{"turn_id" => "turn-retry", "retry_of_turn_id" => "turn-original"}
      )
    ]

    Enum.each(entries, &Sigma.Session.Storage.JsonlFile.append(path, &1))
    before_bytes = File.read!(path)

    assert {:ok, summaries} = Log.branch_summaries(path, summary_length: 12)

    assert [
             %{
               leaf_id: "retry-answer",
               active?: true,
               parent_leaf_id: "retry-user",
               branch_point_id: "root",
               turn_id: "turn-retry",
               retry_of_turn_id: "turn-original",
               last_user: %{message_id: "user-retry", text: retry_text},
               last_assistant: %{
                 message_id: "assistant-retry",
                 text: replacement_text
               }
             },
             %{
               leaf_id: "original-answer",
               active?: false,
               parent_leaf_id: "root",
               branch_point_id: "root",
               turn_id: "turn-original",
               retry_of_turn_id: nil,
               last_user: %{message_id: "user-root", text: "Try this"},
               last_assistant: %{
                 message_id: "assistant-original",
                 text: original_text
               }
             }
           ] = summaries

    assert retry_text == "Retry with a"
    assert replacement_text == "Replacement "
    assert original_text == "Original ans"
    refute inspect(summaries) =~ "private-image-data"
    assert File.read!(path) == before_bytes
  end

  @tag :tmp_dir
  test "branch summaries tolerate legacy metadata and invalid message payloads", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "legacy-branch-summaries.jsonl")

    entries = [
      %{
        "type" => "session",
        "version" => 3,
        "id" => "session",
        "timestamp" => "2026-09-09T00:00:00Z",
        "cwd" => "/repo"
      },
      message_entry("root", nil, "legacy-user", "user", "Legacy prompt"),
      message_entry("valid-leaf", "root", "legacy-assistant", "assistant", nil),
      %{
        "type" => "message",
        "id" => "invalid-leaf",
        "parentId" => "root",
        "timestamp" => "2026-09-09T00:00:03Z",
        "message" => %{"role" => "assistant"}
      }
    ]

    Enum.each(entries, &Sigma.Session.Storage.JsonlFile.append(path, &1))

    assert {:ok,
            [
              %{
                leaf_id: "invalid-leaf",
                active?: true,
                turn_id: nil,
                retry_of_turn_id: nil,
                last_user: %{message_id: "legacy-user", text: "Legacy prompt"},
                last_assistant: nil
              },
              %{
                leaf_id: "valid-leaf",
                active?: false,
                turn_id: nil,
                retry_of_turn_id: nil,
                last_user: %{message_id: "legacy-user", text: "Legacy prompt"},
                last_assistant: %{message_id: "legacy-assistant", text: nil}
              }
            ]} = Log.branch_summaries(path)
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
      Formata.JSON.encode!(%{
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

  defp message_entry(id, parent_id, message_id, role, content, metadata \\ nil) do
    message = %{
      "id" => message_id,
      "role" => role,
      "content" => content,
      "timestamp" => 1
    }

    message = if is_map(metadata), do: Map.put(message, "metadata", metadata), else: message

    %{
      "type" => "message",
      "id" => id,
      "parentId" => parent_id,
      "timestamp" => "2026-09-09T00:00:01Z",
      "message" => message
    }
  end
end
