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

    File.write!(path, Enum.map_join([header, filler, model, user], "\n", &Jason.encode!/1) <> "\n")
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
