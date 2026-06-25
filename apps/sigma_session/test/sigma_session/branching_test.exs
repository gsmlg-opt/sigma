defmodule Sigma.Session.BranchingTest do
  use ExUnit.Case

  alias Sigma.Session.Log
  alias Sigma.Agent.Message

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
    {:ok, target_entries} = Sigma.Session.Storage.JsonlFile.read(@target_storage)

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

  @tag :tmp_dir
  test "fork refuses an existing target without overwriting it", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "source.jsonl")
    target = Path.join(tmp_dir, "target.jsonl")

    Log.persist_event(source, {:agent_start, "/tmp"})
    Log.persist_event(source, {:message_end, Message.user("m1", "hello")})
    File.write!(target, "existing\n")

    assert {:error, :already_exists} = Log.fork(source, target, 1, "/tmp")
    assert File.read!(target) == "existing\n"
  end

  @tag :tmp_dir
  test "fork removes the temp file when append fails", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "source.jsonl")
    target = Path.join(tmp_dir, "target.jsonl")

    Log.persist_event(source, {:agent_start, "/tmp"})
    Log.persist_event(source, {:message_end, Message.user("m1", "hello")})

    assert {:error, :forced_failure} =
             Log.fork(source, target, 1, "/tmp", FailingAppendStorage)

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

    assert {:error, :already_exists} =
             Log.fork(source, target, 1, "/tmp", RacingAppendStorage)

    assert File.read!(target) == "raced\n"
    assert File.ls!(tmp_dir) |> Enum.sort() == ["source.jsonl", "target.jsonl"]
  end
end
