defmodule Sigma.Session.OperationsTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.Message
  alias Sigma.Session.Log
  alias Sigma.Session.Storage.JsonlFile

  @moduletag :tmp_dir

  test "dump and export publish atomically without mutating session sources", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "source.jsonl")
    sidecar = Path.join(tmp_dir, "source.meta.json")
    dump_path = Path.join(tmp_dir, "session.json")
    export_path = Path.join(tmp_dir, "session.md")

    :ok = Log.persist_event(source, {:agent_start, "/missing/source"})
    :ok = Log.persist_event(source, {:message_end, Message.user("user-1", "hello")})
    {:ok, snapshot} = Log.snapshot(source)

    unknown = %{
      "type" => "future_contract",
      "id" => "unknown-entry",
      "parentId" => snapshot.active_leaf_id,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "payload" => %{"kept" => true}
    }

    :ok = JsonlFile.append(source, unknown)
    File.write!(sidecar, ~s({"cwd":"/missing/source","branch":"feature"}))
    source_before = File.read!(source)
    sidecar_before = File.read!(sidecar)

    assert {:ok, ^dump_path} = Log.dump(source, dump_path)
    assert {:ok, ^export_path} = Log.export(source, export_path)
    assert File.read!(source) == source_before
    assert File.read!(sidecar) == sidecar_before

    dump = dump_path |> File.read!() |> Jason.decode!()
    assert dump["format"] == "sigma.session.dump"
    assert dump["activeLeafId"] == "unknown-entry"

    assert [%{"id" => "unknown-entry", "payload" => %{"kept" => true}}] =
             dump["unknownEntries"]

    markdown = File.read!(export_path)
    assert markdown =~ "# Sigma session"
    assert markdown =~ "**Working directory:** /missing/source"
    assert markdown =~ "### User"
    assert markdown =~ "hello"

    assert {:error, :already_exists} = Log.dump(source, dump_path)
    assert {:ok, ^dump_path} = Log.dump(source, dump_path, replace: true)
  end

  test "dump captures accepted journal length and ignores later appends", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "source.jsonl")
    dump_path = Path.join(tmp_dir, "session.json")
    :ok = Log.persist_event(source, {:agent_start, tmp_dir})
    :ok = Log.persist_event(source, {:message_end, Message.user("before", "before")})

    after_capture = fn path, _accepted_length ->
      :ok = Log.persist_event(path, {:message_end, Message.user("after", "after")})
    end

    assert {:ok, ^dump_path} = Log.dump(source, dump_path, after_capture: after_capture)
    dump = dump_path |> File.read!() |> Jason.decode!()

    refute Enum.any?(dump["entries"], &(get_in(&1, ["message", "id"]) == "after"))
    assert {:ok, replayed} = Log.replay(source)
    assert Enum.any?(replayed, &(&1.id == "after"))
  end

  test "dump preserves cancelled tool-call diagnostics and original journal data as JSON", %{
    tmp_dir: tmp_dir
  } do
    source = Path.join(tmp_dir, "cancelled.jsonl")
    sidecar = Path.join(tmp_dir, "cancelled.meta.json")
    dump_path = Path.join(tmp_dir, "cancelled.json")
    timestamp = "2026-10-30T03:00:00Z"

    header = %{
      "type" => "session",
      "version" => 3,
      "id" => "cancelled-session",
      "timestamp" => timestamp,
      "cwd" => tmp_dir
    }

    messages = [
      {"user-entry", nil, %{"id" => "user-1", "role" => "user", "content" => "Wait"}},
      {"assistant-entry", "user-entry",
       %{
         "id" => "assistant-1",
         "role" => "assistant",
         "stop_reason" => "aborted",
         "metadata" => %{"turn_id" => "cancelled-turn", "retained" => [true, nil, "汉字\r\n"]},
         "content" => [
           %{"type" => "text", "text" => "Waiting 汉字\r\n"},
           %{
             "type" => "tool_call",
             "id" => "client53-1",
             "name" => "clock::sleep",
             "arguments" => %{"duration_ms" => 60_000}
           }
         ]
       }},
      {"next-user-entry", "assistant-entry",
       %{"id" => "user-2", "role" => "user", "content" => "Continue"}}
    ]

    entries =
      [header] ++
        Enum.map(messages, fn {id, parent, message} ->
          %{
            "type" => "message",
            "id" => id,
            "parentId" => parent,
            "timestamp" => timestamp,
            "message" => Map.put(message, "timestamp", 1_793_327_200_000)
          }
        end)

    unknown = %{
      "type" => "future_contract",
      "id" => "future-entry",
      "parentId" => "next-user-entry",
      "timestamp" => timestamp,
      "payload" => %{"values" => [false, nil, "exact\r\n"], "empty" => %{}}
    }

    entries = entries ++ [unknown]
    source_bytes = Enum.map_join(entries, "\n", &Jason.encode!/1) <> "\n{\"type\":"
    sidecar_bytes = ~s({"branch":"cancelled","exact":"汉字\\r\\n"})
    File.write!(source, source_bytes)
    File.write!(sidecar, sidecar_bytes)
    stat_fields = [:size, :mtime, :inode, :mode]
    source_stat = source |> File.stat!(time: :posix) |> Map.take(stat_fields)
    sidecar_stat = sidecar |> File.stat!(time: :posix) |> Map.take(stat_fields)

    assert {:ok, before_snapshot} = Log.snapshot(source)

    assert before_snapshot.diagnostics == [
             %{kind: :trailing_incomplete_json, line: 6},
             %{
               kind: :message_repair,
               entry_id: "assistant-entry",
               entry_index: 2,
               reason: {:orphaned_tool_call, "client53-1"}
             }
           ]

    assert {:ok, ^dump_path} = Log.dump(source, dump_path)
    dump = dump_path |> File.read!() |> Jason.decode!()

    assert dump["diagnostics"] == [
             %{"kind" => "trailing_incomplete_json", "line" => 6},
             %{
               "kind" => "message_repair",
               "entry_id" => "assistant-entry",
               "entry_index" => 2,
               "reason" => ["orphaned_tool_call", "client53-1"]
             }
           ]

    assert dump["acceptedLength"] == byte_size(source_bytes)
    assert dump["header"] == header
    assert dump["entries"] == tl(entries)
    assert dump["unknownEntries"] == [unknown]
    assert dump["activeLeafId"] == before_snapshot.active_leaf_id
    assert dump["branchEntryIds"] == before_snapshot.branch_entry_ids
    assert File.read!(source) == source_bytes
    assert File.read!(sidecar) == sidecar_bytes
    assert Map.take(File.stat!(source, time: :posix), stat_fields) == source_stat
    assert Map.take(File.stat!(sidecar, time: :posix), stat_fields) == sidecar_stat
    assert {:ok, ^before_snapshot} = Log.snapshot(source)
  end

  test "session summaries enforce prefix and tail read budgets and retain orphaned cwd", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "large.jsonl")
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()

    header = %{
      "type" => "session",
      "version" => 3,
      "id" => "session-header",
      "timestamp" => timestamp,
      "cwd" => "/definitely/missing/sigma-repo"
    }

    filler = %{
      "type" => "future_large_payload",
      "id" => "filler",
      "parentId" => nil,
      "timestamp" => timestamp,
      "payload" => String.duplicate("x", 8_000)
    }

    model = %{
      "type" => "model_change",
      "id" => "model",
      "parentId" => "filler",
      "timestamp" => timestamp,
      "model" => "anthropic/opus"
    }

    user = %{
      "type" => "message",
      "id" => "user-entry",
      "parentId" => "model",
      "timestamp" => timestamp,
      "message" => %{
        "id" => "user-message",
        "role" => "user",
        "content" => "latest bounded preview",
        "timestamp" => System.system_time(:millisecond)
      }
    }

    File.write!(
      path,
      Enum.map_join([header, filler, model, user], "\n", &Jason.encode!/1) <> "\n"
    )

    test_pid = self()

    range_reader = fn read_path, offset, length ->
      send(test_pid, {:range_read, read_path, offset, length})

      case File.open(read_path, [:read, :binary], fn io -> :file.pread(io, offset, length) end) do
        {:ok, {:ok, bytes}} -> {:ok, bytes}
        {:ok, :eof} -> {:ok, ""}
        {:ok, {:error, reason}} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
    end

    assert {:ok, [summary]} =
             Log.list_session_summaries(tmp_dir,
               read_budget: 1_024,
               range_reader: range_reader
             )

    reads = drain_range_reads([])
    assert length(reads) == 2
    assert Enum.all?(reads, fn {_path, _offset, length} -> length <= 1_024 end)
    assert Enum.any?(reads, fn {_path, offset, _length} -> offset == 0 end)
    assert Enum.any?(reads, fn {_path, offset, _length} -> offset > 0 end)

    assert summary.session_id == "large"
    assert summary.cwd == "/definitely/missing/sigma-repo"
    assert summary.cwd_missing?
    assert summary.provider_id == "anthropic"
    assert summary.model_id == "opus"
    assert summary.latest_user_preview == "latest bounded preview"
    assert summary.partial?
  end

  defp drain_range_reads(acc) do
    receive do
      {:range_read, path, offset, length} ->
        drain_range_reads([{path, offset, length} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
