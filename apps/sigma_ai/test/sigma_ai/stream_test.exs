defmodule Sigma.Ai.StreamTest do
  use ExUnit.Case
  alias Sigma.Ai.Stream

  test "replays anthropic_hello.txt fixture" do
    path = Path.expand("../fixtures/sse/anthropic_hello.txt", __DIR__)
    content = File.read!(path)

    {events, remaining} = Stream.decode("", content)

    assert remaining == ""
    assert length(events) > 0

    # First event should be message_start
    [first | _] = events
    assert first["type"] == "message_start"

    # Check for text_delta in content_block_delta
    deltas = Enum.filter(events, fn e -> e["type"] == "content_block_delta" end)
    assert length(deltas) > 0
    
    # One of them should have thinking_delta
    assert Enum.any?(deltas, fn d -> d["delta"]["type"] == "thinking_delta" end)
    
    # One of them should have text_delta
    assert Enum.any?(deltas, fn d -> d["delta"]["type"] == "text_delta" end)

    # Last event should be message_stop
    last = List.last(events)
    assert last["type"] == "message_stop"
  end
end
