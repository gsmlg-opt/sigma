defmodule Sigma.Agent.PromptQueueTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.PromptQueue

  test "keeps steering and follow-up queues FIFO and independent" do
    queue =
      PromptQueue.new()
      |> PromptQueue.enqueue(:steering, %{message_id: "s1"})
      |> PromptQueue.enqueue(:follow_up, %{message_id: "f1"})
      |> PromptQueue.enqueue(:steering, %{message_id: "s2"})

    assert %{message_id: "s1"} = PromptQueue.peek(queue, :steering)
    assert %{message_id: "f1"} = PromptQueue.peek(queue, :follow_up)

    assert {:ok, queue} = PromptQueue.ack(queue, :steering, "s1")
    assert %{message_id: "s2"} = PromptQueue.peek(queue, :steering)
    assert %{steering: 1, follow_up: 1} = PromptQueue.counts(queue)
  end

  test "does not remove a reserved prompt when acknowledgement does not match" do
    queue = PromptQueue.new() |> PromptQueue.enqueue(:steering, %{message_id: "s1"})
    assert {:error, :prompt_not_reserved} = PromptQueue.ack(queue, :steering, "other")
    assert %{message_id: "s1"} = PromptQueue.peek(queue, :steering)
  end
end
