defmodule Sigma.Session.BranchingTest do
  use ExUnit.Case

  alias Sigma.Session.Log
  alias Sigma.Agent.Message
  alias Sigma.Session.Storage.JsonlFile

  defmodule FailingAppendStorage do
    def read(path), do: Sigma.Session.Storage.JsonlFile.read(path)
    def append(_path, _entry), do: {:error, :forced_failure}
  end

  defmodule RacingAppendStorage do
    def read(path), do: Sigma.Session.Storage.JsonlFile.read(path)

    def append(path, entry) do
      unless Process.get({__MODULE__, :raced?}) do
        Process.put({__MODULE__, :raced?}, true)
        target = Process.get({__MODULE__, :target}) || raise "target path not configured"
        File.write!(target, "raced\n")
      end

      Sigma.Session.Storage.JsonlFile.append(path, entry)
    end
  end

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
        msg = Message.assistant(id, %{content: "message #{i}"})
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

  test "fork writes one fresh header followed by the selected branch" do
    # 1. Create source session
    Log.persist_event(@test_storage, {:agent_start, "/tmp"})
    msg1 = Message.user("m1", "hello")
    Log.persist_event(@test_storage, {:message_end, msg1})
    msg2 = Message.assistant("m2", %{content: "hi"})
    Log.persist_event(@test_storage, {:message_end, msg2})
    msg3 = Message.user("m3", "how are you?")
    Log.persist_event(@test_storage, {:message_end, msg3})

    # 2. Fork after the first completed assistant response.
    # entries: [session_header, m1, m2, m3]
    # index 1 means [session_header, m1]
    {:ok, new_session_id} = Log.fork(@test_storage, @target_storage, 2, "/tmp")

    # 3. Check target storage
    {:ok, target_entries} = Sigma.Session.Storage.JsonlFile.read(@target_storage)

    assert Enum.count(target_entries) == 3
    assert Enum.at(target_entries, 0)["type"] == "session"
    assert Enum.at(target_entries, 0)["id"] == new_session_id
    assert Enum.at(target_entries, 0)["parentSession"] != nil
    assert Enum.at(target_entries, 1)["type"] == "message"
    assert Enum.at(target_entries, 1)["message"]["id"] == "m1"
    assert Enum.at(target_entries, 2)["message"]["id"] == "m2"

    # 4. Replay target
    {:ok, messages} = Log.replay(@target_storage)
    assert Enum.count(messages) == 2
    assert Enum.at(messages, 0).id == "m1"
    assert Enum.at(messages, 1).id == "m2"
  end

  @tag :tmp_dir
  test "fork preserves selected lineage request facts as inherited usage", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "source.jsonl")
    target = Path.join(tmp_dir, "target.jsonl")

    assert :ok = Log.persist_event(source, {:agent_start, "/tmp"})
    assert {:ok, source_snapshot} = Log.snapshot(source)

    first_user = %{Message.user("u1", "first") | metadata: %{turn_id: "turn-1"}}
    first_answer = %{Message.assistant("a1", %{content: "one"}) | metadata: %{turn_id: "turn-1"}}
    second_user = %{Message.user("u2", "second") | metadata: %{turn_id: "turn-2"}}

    assert :ok = Log.persist_event(source, {:message_end, first_user})
    assert :ok = Log.persist_event(source, {:message_end, first_answer})

    assert :ok =
             Log.persist_event(
               source,
               {:metrics, :request_finished,
                %{
                  request_id: "request-1",
                  message_id: "a1",
                  session_id: source_snapshot.session_id,
                  turn_id: "turn-1",
                  revision: 1,
                  status: :completed,
                  input_tokens_total: 10,
                  output_tokens_total: 5,
                  elapsed_ms: 100
                }}
             )

    assert :ok = Log.persist_event(source, {:message_end, second_user})

    assert :ok =
             Log.persist_event(
               source,
               {:metrics, :request_finished,
                %{
                  request_id: "request-2",
                  session_id: source_snapshot.session_id,
                  turn_id: "turn-2",
                  revision: 1,
                  status: :completed,
                  input_tokens_total: 100,
                  output_tokens_total: 50,
                  elapsed_ms: 100
                }}
             )

    source_bytes = File.read!(source)
    assert {:ok, _fork_id} = Log.fork_at_message(source, target, "a1", "/fork")
    assert File.read!(source) == source_bytes
    assert {:ok, child_snapshot} = Log.snapshot(target)

    metrics = Sigma.Session.Metrics.snapshot(child_snapshot.metrics)
    assert metrics.own_usage.total_tokens == 0
    assert metrics.inherited_usage.total_tokens == 15
    assert metrics.inherited_usage.request_count == 1
    assert Map.has_key?(child_snapshot.metrics.requests, "request-1")
    refute Map.has_key?(child_snapshot.metrics.requests, "request-2")

    prompt_target = Path.join(tmp_dir, "prompt-fork.jsonl")
    assert {:ok, _} = Log.fork_at_message(source, prompt_target, "u2", "/fork")
    assert {:ok, prompt_snapshot} = Log.snapshot(prompt_target)
    assert Enum.map(prompt_snapshot.messages, & &1.id) == ["u1", "a1", "u2"]
    assert Map.has_key?(prompt_snapshot.metrics.requests, "request-1")
    refute Map.has_key?(prompt_snapshot.metrics.requests, "request-2")
  end

  @tag :tmp_dir
  test "fork_at_message rejects an unknown message id and leaves no target", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "source.jsonl")
    target = Path.join(tmp_dir, "target.jsonl")

    Log.persist_event(source, {:agent_start, "/tmp"})
    Log.persist_event(source, {:message_end, Message.user("m1", "hello")})

    assert {:error, :message_not_found} =
             Log.fork_at_message(source, target, "missing", "/tmp")

    refute File.exists?(target)
    assert File.ls!(tmp_dir) == ["source.jsonl"]
  end

  @tag :tmp_dir
  test "fork preserves unknown entries, ids, and parents only on the selected branch", %{
    tmp_dir: tmp_dir
  } do
    source = Path.join(tmp_dir, "source.jsonl")
    target = Path.join(tmp_dir, "target.jsonl")

    entries = [
      %{
        "type" => "session",
        "version" => 3,
        "id" => "source-session",
        "timestamp" => "2026-09-01T00:00:00Z",
        "cwd" => "/repo"
      },
      journal_message("root", nil, "message-root", "root"),
      %{
        "type" => "future_state",
        "id" => "unknown",
        "parentId" => "root",
        "timestamp" => "2026-09-01T00:00:02Z",
        "payload" => %{"kept" => true}
      },
      journal_message("left", "unknown", "message-left", "left", "assistant"),
      journal_message("right", "root", "message-right", "right", "assistant")
    ]

    Enum.each(entries, &JsonlFile.append(source, &1))
    source_bytes = File.read!(source)

    assert {:ok, new_session_id} =
             Log.fork_at_message(source, target, "message-left", "/fork")

    assert File.read!(source) == source_bytes
    assert {:ok, [new_header, root, unknown, left]} = JsonlFile.read(target)

    assert %{
             "type" => "session",
             "id" => ^new_session_id,
             "cwd" => "/fork",
             "parentSession" => "source-session"
           } = new_header

    assert root == Enum.at(entries, 1)
    assert unknown == Enum.at(entries, 2)
    assert left == Enum.at(entries, 3)
  end

  @tag :tmp_dir
  test "fork rejects ambiguous message ids without publication", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "source.jsonl")
    target = Path.join(tmp_dir, "target.jsonl")

    entries = [
      %{
        "type" => "session",
        "version" => 3,
        "id" => "source-session",
        "timestamp" => "2026-09-01T00:00:00Z",
        "cwd" => "/repo"
      },
      journal_message("first", nil, "duplicate-message", "first"),
      journal_message("second", "first", "duplicate-message", "second")
    ]

    Enum.each(entries, &JsonlFile.append(source, &1))

    assert {:error, :ambiguous_message_id} =
             Log.fork_at_message(source, target, "duplicate-message", "/fork")

    refute File.exists?(target)
  end

  @tag :tmp_dir
  test "fork isolates a recoverable corrupt sibling and preserves source bytes", %{
    tmp_dir: tmp_dir
  } do
    source = Path.join(tmp_dir, "source.jsonl")
    target = Path.join(tmp_dir, "target.jsonl")

    Log.persist_event(source, {:agent_start, "/tmp"})
    File.write!(source, "{invalid}\n", [:append])
    source_bytes = File.read!(source)

    assert {:ok, _fork_id} = Log.fork_at_message(source, target, :all, "/fork")

    assert File.read!(source) == source_bytes
    assert {:ok, [%{"type" => "session", "cwd" => "/fork"}]} = JsonlFile.read(target)
    assert Enum.sort(File.ls!(tmp_dir)) == ["source.jsonl", "target.jsonl"]
  end

  @tag :tmp_dir
  test "fork refuses an existing target without overwriting it", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "source.jsonl")
    target = Path.join(tmp_dir, "target.jsonl")

    Log.persist_event(source, {:agent_start, "/tmp"})
    Log.persist_event(source, {:message_end, Message.user("m1", "hello")})
    Log.persist_event(source, {:message_end, Message.assistant("m2", %{content: "done"})})
    File.write!(target, "existing\n")

    assert {:error, :already_exists} = Log.fork(source, target, 2, "/tmp")
    assert File.read!(target) == "existing\n"
  end

  @tag :tmp_dir
  test "fork removes the temp file when append fails", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "source.jsonl")
    target = Path.join(tmp_dir, "target.jsonl")

    Log.persist_event(source, {:agent_start, "/tmp"})
    Log.persist_event(source, {:message_end, Message.user("m1", "hello")})
    Log.persist_event(source, {:message_end, Message.assistant("m2", %{content: "done"})})

    assert {:error, :forced_failure} =
             Log.fork(source, target, 2, "/tmp", FailingAppendStorage)

    refute File.exists?(target)
    assert File.ls!(tmp_dir) == ["source.jsonl"]
  end

  @tag :tmp_dir
  test "fork refuses a target created during the write without overwriting it", %{
    tmp_dir: tmp_dir
  } do
    source = Path.join(tmp_dir, "source.jsonl")
    target = Path.join(tmp_dir, "target.jsonl")

    Process.put({RacingAppendStorage, :target}, target)
    Process.delete({RacingAppendStorage, :raced?})

    Log.persist_event(source, {:agent_start, "/tmp"})
    Log.persist_event(source, {:message_end, Message.user("m1", "hello")})
    Log.persist_event(source, {:message_end, Message.assistant("m2", %{content: "done"})})

    assert {:error, :already_exists} =
             Log.fork(source, target, 2, "/tmp", RacingAppendStorage)

    assert File.read!(target) == "raced\n"
    assert File.ls!(tmp_dir) |> Enum.sort() == ["source.jsonl", "target.jsonl"]
  end

  @tag :tmp_dir
  test "fork rejects a checkpoint before the turn has completed", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "source.jsonl")
    target = Path.join(tmp_dir, "target.jsonl")

    assert :ok = Log.persist_event(source, {:agent_start, "/tmp"})
    assert :ok = Log.persist_event(source, {:message_end, Message.user("user", "unfinished")})

    assert {:error, {:invalid_fork_boundary, :turn_not_completed}} =
             Log.fork_at_message(source, target, :all, "/tmp")

    refute File.exists?(target)
  end

  @tag :tmp_dir
  test "fork rejects an assistant tool call without its result", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "source.jsonl")
    target = Path.join(tmp_dir, "target.jsonl")

    assistant =
      Message.assistant("assistant", %{
        content: [%{type: :tool_call, id: "call-1", name: "read", arguments: %{}}]
      })

    assert :ok = Log.persist_event(source, {:agent_start, "/tmp"})
    assert :ok = Log.persist_event(source, {:message_end, Message.user("user", "inspect")})
    assert :ok = Log.persist_event(source, {:message_end, assistant})

    assert {:error, {:invalid_fork_boundary, {:unpaired_tool_call, "call-1"}}} =
             Log.fork_at_message(source, target, :all, "/tmp")

    refute File.exists?(target)
  end

  @tag :tmp_dir
  test "recovery forks preserve unfinished history without allowing an incomplete message cut",
       %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "source.jsonl")
    target = Path.join(tmp_dir, "recovered.jsonl")
    cut = Path.join(tmp_dir, "cut.jsonl")

    assistant =
      Message.assistant("unfinished", %{
        content: [%{type: :tool_call, id: "pending", name: "exec_command", arguments: %{}}]
      })

    assert :ok = Log.persist_event(source, {:agent_start, tmp_dir})
    assert :ok = Log.persist_event(source, {:message_end, Message.user("user", "inspect")})
    assert :ok = Log.persist_event(source, {:message_end, assistant})
    original = File.read!(source)

    assert {:error, {:invalid_fork_boundary, {:unpaired_tool_call, "pending"}}} =
             Log.fork_at_message(source, cut, "unfinished", tmp_dir, JsonlFile, recovery: true)

    refute File.exists?(cut)

    assert {:ok, _} =
             Log.fork_at_message(source, target, :all, tmp_dir, JsonlFile, recovery: true)

    assert File.read!(source) == original
    assert {:ok, source_entries} = JsonlFile.read(source)
    assert {:ok, target_entries} = JsonlFile.read(target)
    assert tl(target_entries) == tl(source_entries)
    assert {:ok, snapshot} = Log.snapshot(target)
    assert Enum.all?(snapshot.context_messages, &(&1.role != :tool_result))

    refute Enum.any?(snapshot.context_messages, fn message ->
             Enum.any?(List.wrap(message.content), &match?(%{type: :tool_call}, &1))
           end)
  end

  defp journal_message(entry_id, parent_id, message_id, content, role \\ "user") do
    %{
      "type" => "message",
      "id" => entry_id,
      "parentId" => parent_id,
      "timestamp" => "2026-09-01T00:00:01Z",
      "message" => %{
        "id" => message_id,
        "role" => role,
        "content" => content,
        "timestamp" => 1
      }
    }
  end
end
