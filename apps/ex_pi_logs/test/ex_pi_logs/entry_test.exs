defmodule PiLogs.EntryTest do
  use ExUnit.Case, async: true

  test "new/4 creates an entry with correct fields" do
    entry = PiLogs.Entry.new("session_abc", :llm, :request_start, %{model: "claude-3"})

    assert entry.session_id == "session_abc"
    assert entry.category == :llm
    assert entry.event == :request_start
    assert entry.metadata == %{model: "claude-3"}
    assert is_integer(entry.id)
    assert is_integer(entry.timestamp)
  end

  test "new/4 ids are strictly increasing" do
    e1 = PiLogs.Entry.new("s", :llm, :start, %{})
    e2 = PiLogs.Entry.new("s", :llm, :start, %{})
    assert e2.id > e1.id
  end
end
