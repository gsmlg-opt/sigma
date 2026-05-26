defmodule PiSession.Storage.JsonlFileTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

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

  test "read file with invalid json skips the line and returns ok with empty list", %{
    test_file: test_file
  } do
    File.write!(test_file, "invalid json\n")
    {result, _log} = with_log(fn -> JsonlFile.read(test_file) end)
    assert {:ok, []} = result
  end

  test "tolerates interior corrupt line and torn trailing line, returns valid entries in order",
       %{test_file: path} do
    entry1 = %{"type" => "session", "id" => "s1"}
    entry2 = %{"type" => "message", "id" => "m1"}
    entry3 = %{"type" => "message", "id" => "m2"}

    # line 1: valid, line 2: valid, line 3: interior garbage,
    # line 4: valid, line 5: torn tail (no trailing newline)
    File.write!(path, [
      Jason.encode!(entry1),
      "\n",
      Jason.encode!(entry2),
      "\n",
      "not-valid-json\n",
      Jason.encode!(entry3),
      "\n",
      "{torn"
    ])

    # Interior bad line (line 3) fires a Logger.warning, captured at default test level.
    # Trailing torn line (line 5) fires Logger.debug; we verify it's handled by
    # checking all three valid entries are returned rather than asserting on the
    # debug log (suppressed by `config :logger, level: :warning` in test.exs).
    {result, log} = with_log(fn -> JsonlFile.read(path) end)

    assert {:ok, [^entry1, ^entry2, ^entry3]} = result
    assert log =~ "Skipping corrupt line 3"
    refute log =~ "Skipping corrupt line 5"
  end
end
