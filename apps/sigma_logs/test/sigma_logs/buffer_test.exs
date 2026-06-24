defmodule Sigma.Logs.BufferTest do
  use ExUnit.Case, async: true

  setup do
    session_id = "test_session_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Sigma.Logs.Buffer.start_link(session_id: session_id)
    %{session_id: session_id}
  end

  test "all/1 returns empty list on new session", %{session_id: sid} do
    assert Sigma.Logs.Buffer.all(sid) == []
  end

  test "push/2 adds entries, all/1 returns newest first", %{session_id: sid} do
    e1 = Sigma.Logs.Entry.new(sid, :llm, :request_start, %{})
    e2 = Sigma.Logs.Entry.new(sid, :tool, :call_start, %{})
    Sigma.Logs.Buffer.push(sid, e1)
    Sigma.Logs.Buffer.push(sid, e2)

    [first | _] = Sigma.Logs.Buffer.all(sid)
    assert first.id == e2.id
  end

  test "ring cap keeps exactly 500 entries when over limit", %{session_id: sid} do
    for _ <- 1..505 do
      Sigma.Logs.Buffer.push(sid, Sigma.Logs.Entry.new(sid, :llm, :request_start, %{}))
    end

    entries = Sigma.Logs.Buffer.all(sid)
    assert length(entries) == 500
  end

  test "ring cap drops the oldest entry first", %{session_id: sid} do
    entries = for i <- 1..502, do: Sigma.Logs.Entry.new(sid, :llm, :start, %{seq: i})
    Enum.each(entries, &Sigma.Logs.Buffer.push(sid, &1))

    all = Sigma.Logs.Buffer.all(sid)
    assert Enum.all?(all, fn e -> e.metadata.seq > 2 end)
  end

  test "search/2 filters by category", %{session_id: sid} do
    Sigma.Logs.Buffer.push(sid, Sigma.Logs.Entry.new(sid, :llm, :request_start, %{}))
    Sigma.Logs.Buffer.push(sid, Sigma.Logs.Entry.new(sid, :tool, :call_start, %{}))

    results = Sigma.Logs.Buffer.search(sid, category: :llm)
    assert length(results) == 1
    assert hd(results).category == :llm
  end

  test "search/2 with nil category returns all entries", %{session_id: sid} do
    Sigma.Logs.Buffer.push(sid, Sigma.Logs.Entry.new(sid, :llm, :request_start, %{}))
    Sigma.Logs.Buffer.push(sid, Sigma.Logs.Entry.new(sid, :tool, :call_start, %{}))

    results = Sigma.Logs.Buffer.search(sid, category: nil)
    assert length(results) == 2
  end

  test "search/2 filters by text in metadata", %{session_id: sid} do
    Sigma.Logs.Buffer.push(
      sid,
      Sigma.Logs.Entry.new(sid, :llm, :request_start, %{model: "claude-3-opus"})
    )

    Sigma.Logs.Buffer.push(sid, Sigma.Logs.Entry.new(sid, :llm, :request_start, %{model: "gpt-4"}))

    results = Sigma.Logs.Buffer.search(sid, text: "claude")
    assert length(results) == 1
  end

  test "search/2 with empty string text returns all entries", %{session_id: sid} do
    Sigma.Logs.Buffer.push(sid, Sigma.Logs.Entry.new(sid, :llm, :request_start, %{model: "claude"}))
    Sigma.Logs.Buffer.push(sid, Sigma.Logs.Entry.new(sid, :tool, :call_start, %{}))

    results = Sigma.Logs.Buffer.search(sid, text: "")
    assert length(results) == 2
  end
end
