defmodule Sigma.Session.Storage.JsonlFileTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Sigma.Session.Storage.JsonlFile

  setup do
    tmp_dir = System.tmp_dir!()
    test_file = Path.join(tmp_dir, "test_session_#{:erlang.phash2(make_ref())}.jsonl")
    on_exit(fn -> File.rm_rf(test_file) end)
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

  test "read APIs return empty lists for a non-existent file", %{test_file: test_file} do
    assert {:ok, [], []} = JsonlFile.read_with_diagnostics(test_file)
    assert {:ok, []} = JsonlFile.read(test_file)
  end

  test "read_with_diagnostics returns tagged I/O errors", %{test_file: path} do
    File.mkdir!(path)

    assert {:error, reason} = JsonlFile.read_with_diagnostics(path)
    refute reason == :enoent
  end

  test "read returns tagged I/O errors", %{test_file: path} do
    File.mkdir!(path)

    assert {:error, reason} = JsonlFile.read(path)
    refute reason == :enoent
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

  test "classifies a newline-terminated malformed final record as invalid JSON", %{
    test_file: path
  } do
    File.write!(path, "invalid json\n")

    {result, log} = with_log(fn -> JsonlFile.read_with_diagnostics(path) end)

    assert {:ok, [], [%{kind: :invalid_json, line: 1}]} = result
    assert log =~ "Skipping corrupt line 1"
  end

  test "returns physical line numbers when blank lines precede corruption", %{test_file: path} do
    entry1 = %{"type" => "session", "id" => "s1"}
    entry2 = %{"type" => "message", "id" => "m1"}

    File.write!(path, [
      Jason.encode!(entry1),
      "\r\n\r\n",
      "not-valid-json\r\n",
      Jason.encode!(entry2),
      "\r\n"
    ])

    {result, _log} = with_log(fn -> JsonlFile.read_with_diagnostics(path) end)

    assert {:ok, [^entry1, ^entry2], [%{kind: :invalid_json, line: 3}]} = result
  end

  test "returns structured diagnostics for interior corruption and a torn tail", %{
    test_file: path
  } do
    entry1 = %{"type" => "session", "id" => "s1"}
    entry2 = %{"type" => "message", "id" => "m1"}
    entry3 = %{"type" => "message", "id" => "m2"}

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

    {result, log} = with_log([level: :debug], fn -> JsonlFile.read_with_diagnostics(path) end)

    assert {:ok, [^entry1, ^entry2, ^entry3], diagnostics} = result

    assert diagnostics == [
             %{kind: :invalid_json, line: 3},
             %{kind: :trailing_incomplete_json, line: 5}
           ]

    assert log =~ "Skipping corrupt line 3"
    refute log =~ "not-valid-json"
    refute log =~ "{torn"

    {compatibility_result, compatibility_log} = with_log(fn -> JsonlFile.read(path) end)

    assert {:ok, [^entry1, ^entry2, ^entry3]} = compatibility_result
    assert compatibility_log =~ "Skipping corrupt line 3"
    refute compatibility_log =~ "not-valid-json"
    refute compatibility_log =~ "{torn"
  end
end
