defmodule Sigma.Session.SessionFilesTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.Message
  alias Sigma.Session.Log
  alias Sigma.Session.SessionFiles
  alias Sigma.Session.Storage.JsonlFile

  @moduletag :tmp_dir

  test "jsonl_path rejects traversal and slash-containing ids", %{tmp_dir: tmp_dir} do
    assert {:error, :invalid_session_id} = SessionFiles.jsonl_path(tmp_dir, "../escape")
    assert {:error, :invalid_session_id} = SessionFiles.jsonl_path(tmp_dir, "nested/name")
    assert {:error, :invalid_session_id} = SessionFiles.jsonl_path(tmp_dir, "nested\\name")
    assert {:error, :invalid_session_id} = SessionFiles.jsonl_path(tmp_dir, "bad" <> <<0>>)
    assert {:error, :invalid_session_id} = SessionFiles.meta_path(tmp_dir, "..")

    assert {:ok, pr_path} = SessionFiles.jsonl_path(tmp_dir, "PR#5")
    assert pr_path == Path.join(tmp_dir, "PR#5.jsonl")

    assert {:ok, path} = SessionFiles.jsonl_path(tmp_dir, "session.1_ok-2")
    assert path == Path.join(tmp_dir, "session.1_ok-2.jsonl")
  end

  test "rename moves jsonl and metadata together", %{tmp_dir: tmp_dir} do
    metadata = %{
      "cwd" => "/tmp/worktree",
      "branch" => "feature/session-files",
      "worktree" => true,
      "mcp_server_ids" => ["local"]
    }

    File.write!(jsonl_path(tmp_dir, "old"), "log\n")
    write_meta!(tmp_dir, "old", metadata)

    assert :ok = SessionFiles.rename(tmp_dir, "old", "new")

    assert File.read!(jsonl_path(tmp_dir, "new")) == "log\n"
    assert read_meta!(tmp_dir, "new") == metadata
    refute File.exists?(jsonl_path(tmp_dir, "old"))
    refute File.exists?(meta_path(tmp_dir, "old"))
  end

  test "rename refuses an existing target jsonl", %{tmp_dir: tmp_dir} do
    File.write!(jsonl_path(tmp_dir, "old"), "old\n")
    File.write!(jsonl_path(tmp_dir, "new"), "new\n")
    write_meta!(tmp_dir, "old", %{"cwd" => "/tmp/old"})

    assert {:error, :already_exists} = SessionFiles.rename(tmp_dir, "old", "new")

    assert File.read!(jsonl_path(tmp_dir, "old")) == "old\n"
    assert File.read!(jsonl_path(tmp_dir, "new")) == "new\n"
    assert read_meta!(tmp_dir, "old") == %{"cwd" => "/tmp/old"}
  end

  test "rename refuses an existing target metadata file", %{tmp_dir: tmp_dir} do
    File.write!(jsonl_path(tmp_dir, "old"), "old\n")
    write_meta!(tmp_dir, "old", %{"cwd" => "/tmp/old"})
    write_meta!(tmp_dir, "new", %{"cwd" => "/tmp/new"})

    assert {:error, :already_exists} = SessionFiles.rename(tmp_dir, "old", "new")

    assert File.read!(jsonl_path(tmp_dir, "old")) == "old\n"
    assert read_meta!(tmp_dir, "old") == %{"cwd" => "/tmp/old"}
    assert read_meta!(tmp_dir, "new") == %{"cwd" => "/tmp/new"}
    refute File.exists?(jsonl_path(tmp_dir, "new"))
  end

  test "rename refuses a jsonl target created after preflight", %{tmp_dir: tmp_dir} do
    File.write!(jsonl_path(tmp_dir, "old"), "old\n")
    write_meta!(tmp_dir, "old", %{"cwd" => "/tmp/old"})

    with_session_file_hook(
      fn
        :before_jsonl_move, %{target: target} -> File.write!(target, "raced\n")
        _event, _paths -> :ok
      end,
      fn ->
        assert {:error, :already_exists} = SessionFiles.rename(tmp_dir, "old", "new")
      end
    )

    assert File.read!(jsonl_path(tmp_dir, "old")) == "old\n"
    assert File.read!(jsonl_path(tmp_dir, "new")) == "raced\n"
    assert read_meta!(tmp_dir, "old") == %{"cwd" => "/tmp/old"}
    refute File.exists?(meta_path(tmp_dir, "new"))
  end

  test "rename rolls back jsonl when metadata target appears after preflight", %{
    tmp_dir: tmp_dir
  } do
    File.write!(jsonl_path(tmp_dir, "old"), "old\n")
    write_meta!(tmp_dir, "old", %{"cwd" => "/tmp/old"})

    with_session_file_hook(
      fn
        :before_meta_move, %{target: target} ->
          File.write!(target, Jason.encode!(%{"cwd" => "/tmp/raced"}))

        _event, _paths ->
          :ok
      end,
      fn ->
        assert {:error, :already_exists} = SessionFiles.rename(tmp_dir, "old", "new")
      end
    )

    assert File.read!(jsonl_path(tmp_dir, "old")) == "old\n"
    refute File.exists?(jsonl_path(tmp_dir, "new"))
    assert read_meta!(tmp_dir, "old") == %{"cwd" => "/tmp/old"}
    assert read_meta!(tmp_dir, "new") == %{"cwd" => "/tmp/raced"}
  end

  test "delete removes jsonl and metadata together", %{tmp_dir: tmp_dir} do
    File.write!(jsonl_path(tmp_dir, "gone"), "log\n")
    write_meta!(tmp_dir, "gone", %{"cwd" => "/tmp/worktree"})

    assert :ok = SessionFiles.delete(tmp_dir, "gone")

    refute File.exists?(jsonl_path(tmp_dir, "gone"))
    refute File.exists?(meta_path(tmp_dir, "gone"))
  end

  test "delete preserves metadata when jsonl removal fails", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(jsonl_path(tmp_dir, "broken"))
    metadata = %{"cwd" => "/tmp/worktree"}
    write_meta!(tmp_dir, "broken", metadata)

    assert {:error, _reason} = SessionFiles.delete(tmp_dir, "broken")

    assert read_meta!(tmp_dir, "broken") == metadata
    assert File.dir?(jsonl_path(tmp_dir, "broken"))
  end

  test "fork copies metadata and preserves worktree fields by default", %{tmp_dir: tmp_dir} do
    source_jsonl = jsonl_path(tmp_dir, "source")

    metadata = %{
      "cwd" => "/tmp/project/.trees/feature",
      "branch" => "feature",
      "worktree" => true,
      "mcp_server_ids" => ["project", "worktree"]
    }

    :ok = Log.persist_event(source_jsonl, {:agent_start, "/tmp/project"})
    :ok = Log.persist_event(source_jsonl, {:message_end, Message.user("msg_1", "hello")})
    write_meta!(tmp_dir, "source", metadata)

    assert {:ok, _new_log_session_id} = SessionFiles.fork(tmp_dir, "source", "target", :all)

    assert read_meta!(tmp_dir, "target") == metadata

    assert {:ok, entries} = JsonlFile.read(jsonl_path(tmp_dir, "target"))
    assert %{"type" => "session", "cwd" => "/tmp/project/.trees/feature"} = List.last(entries)

    assert {:ok, [%Message{id: "msg_1"}]} = Log.replay(jsonl_path(tmp_dir, "target"))
  end

  test "fork refuses an existing target jsonl", %{tmp_dir: tmp_dir} do
    write_session!(tmp_dir, "source")
    File.write!(jsonl_path(tmp_dir, "target"), "existing\n")

    assert {:error, :already_exists} = SessionFiles.fork(tmp_dir, "source", "target", :all)

    assert File.read!(jsonl_path(tmp_dir, "target")) == "existing\n"
  end

  test "fork refuses an existing target metadata file", %{tmp_dir: tmp_dir} do
    write_session!(tmp_dir, "source")
    write_meta!(tmp_dir, "target", %{"cwd" => "/tmp/existing"})

    assert {:error, :already_exists} = SessionFiles.fork(tmp_dir, "source", "target", :all)

    refute File.exists?(jsonl_path(tmp_dir, "target"))
    assert read_meta!(tmp_dir, "target") == %{"cwd" => "/tmp/existing"}
  end

  test "fork refuses target metadata created after preflight and removes jsonl", %{
    tmp_dir: tmp_dir
  } do
    write_session!(tmp_dir, "source")
    write_meta!(tmp_dir, "source", %{"cwd" => "/tmp/source"})

    with_session_file_hook(
      fn
        :before_meta_publish, %{target: target} ->
          File.write!(target, Jason.encode!(%{"cwd" => "/tmp/raced"}))

        _event, _paths ->
          :ok
      end,
      fn ->
        assert {:error, :already_exists} = SessionFiles.fork(tmp_dir, "source", "target", :all)
      end
    )

    refute File.exists?(jsonl_path(tmp_dir, "target"))
    assert read_meta!(tmp_dir, "target") == %{"cwd" => "/tmp/raced"}
  end

  test "fork refuses a missing source jsonl", %{tmp_dir: tmp_dir} do
    write_meta!(tmp_dir, "source", %{"cwd" => "/tmp/source"})

    assert {:error, :enoent} = SessionFiles.fork(tmp_dir, "source", "target", :all)

    refute File.exists?(jsonl_path(tmp_dir, "target"))
    refute File.exists?(meta_path(tmp_dir, "target"))
  end

  test "fork rewrites copied metadata cwd only when explicitly requested", %{tmp_dir: tmp_dir} do
    source_jsonl = jsonl_path(tmp_dir, "source")

    metadata = %{
      "cwd" => "/tmp/project/.trees/feature",
      "branch" => "feature",
      "worktree" => true,
      "mcp_server_ids" => ["project", "worktree"]
    }

    :ok = Log.persist_event(source_jsonl, {:agent_start, "/tmp/project"})
    write_meta!(tmp_dir, "source", metadata)

    assert {:ok, _new_log_session_id} =
             SessionFiles.fork(tmp_dir, "source", "target", :all, rewrite_cwd: "/tmp/project")

    assert read_meta!(tmp_dir, "target") == %{metadata | "cwd" => "/tmp/project"}

    assert {:ok, entries} = JsonlFile.read(jsonl_path(tmp_dir, "target"))
    assert %{"type" => "session", "cwd" => "/tmp/project"} = List.last(entries)
  end

  defp jsonl_path(dir, id), do: Path.join(dir, "#{id}.jsonl")
  defp meta_path(dir, id), do: Path.join(dir, "#{id}.meta.json")

  defp write_meta!(dir, id, metadata) do
    File.write!(meta_path(dir, id), Jason.encode!(metadata))
  end

  defp write_session!(dir, id) do
    jsonl_path = jsonl_path(dir, id)
    :ok = Log.persist_event(jsonl_path, {:agent_start, "/tmp/project"})
    :ok = Log.persist_event(jsonl_path, {:message_end, Message.user("msg_1", "hello")})
    jsonl_path
  end

  defp with_session_file_hook(hook, fun) do
    Process.put({SessionFiles, :operation_hook}, hook)

    try do
      fun.()
    after
      Process.delete({SessionFiles, :operation_hook})
    end
  end

  defp read_meta!(dir, id) do
    dir
    |> meta_path(id)
    |> File.read!()
    |> Jason.decode!()
  end
end
