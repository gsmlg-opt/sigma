defmodule PiSession.Storage.JsonlFileTest do
  use ExUnit.Case, async: true

  alias PiSession.Storage.JsonlFile

  setup do
    tmp_dir = System.tmp_dir!()
    test_file = Path.join(tmp_dir, "test_session_#{:erlang.phash2(make_ref())}.jsonl")
    on_exit(fn -> File.rm(test_file) end)
    {:ok, test_file: test_file}
  end

  test "append and read entries", %{test_file: test_file} do
    header = %{
      "type" => "session",
      "version" => 3,
      "id" => "session-123",
      "timestamp" => "2023-10-27T10:00:00Z",
      "cwd" => "/test/cwd"
    }

    message = %{
      "type" => "message",
      "id" => "msg-1",
      "parentId" => "session-123",
      "timestamp" => "2023-10-27T10:00:01Z",
      "message" => %{
        "role" => "user",
        "content" => "hello"
      }
    }

    assert :ok = JsonlFile.append(test_file, header)
    assert :ok = JsonlFile.append(test_file, message)

    assert {:ok, entries} = JsonlFile.read(test_file)
    assert length(entries) == 2
    assert Enum.at(entries, 0) == header
    assert Enum.at(entries, 1) == message
  end

  test "read non-existent file returns empty list", %{test_file: test_file} do
    assert {:ok, []} = JsonlFile.read(test_file)
  end

  test "read file with empty lines", %{test_file: test_file} do
    entry = %{"type" => "test", "id" => "1"}
    {:ok, json} = Jason.encode(entry)
    File.write!(test_file, json <> "\n\n" <> json <> "\n")

    assert {:ok, entries} = JsonlFile.read(test_file)
    assert length(entries) == 2
    assert Enum.at(entries, 0) == entry
    assert Enum.at(entries, 1) == entry
  end

  test "read file with invalid json returns error", %{test_file: test_file} do
    File.write!(test_file, "invalid json\n")
    assert {:error, %Jason.DecodeError{}} = JsonlFile.read(test_file)
  end
end
