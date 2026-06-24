defmodule Sigma.AgentReconstructionTest do
  use ExUnit.Case

  defmodule MockProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params) do
      # Determine which turn it is
      turn = div(length(params.context.messages) + 1, 2)
      response_text = "Response for turn #{turn}"

      # Generate events
      ai_msg = %{
        role: :assistant,
        content: [],
        api: "mock",
        provider: "mock",
        model: "mock",
        usage: %{
          input: 0,
          output: 0,
          cache_read: 0,
          cache_write: 0,
          total_tokens: 0,
          cost: %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0, total: 0.0}
        },
        stop_reason: nil,
        timestamp: System.system_time(:millisecond)
      }

      # 1. Start
      event1 = {:start, ai_msg}

      # 2. Delta
      ai_msg_delta = %{ai_msg | content: [%{type: :text, text: response_text}]}
      event2 = {:text_delta, 0, response_text, ai_msg_delta}

      # 3. Done
      ai_msg_done = %{ai_msg_delta | stop_reason: :stop}
      event3 = {:done, :stop, ai_msg_done}

      [event1, event2, event3]
    end
  end

  test "performs 3 turns and reconstructs state from events" do
    opts = [
      model: %{id: "mock-model", api: "mock", provider: "mock"},
      provider: MockProvider,
      system_prompt: "You are a helpful assistant."
    ]

    {:ok, agent} = Sigma.Agent.start_link(opts)
    Sigma.Agent.subscribe(agent)

    # Turn 1
    Sigma.Agent.prompt(agent, "Turn 1")
    events1 = collect_until_agent_end([])

    # Turn 2
    Sigma.Agent.prompt(agent, "Turn 2")
    events2 = collect_until_agent_end([])

    # Turn 3
    Sigma.Agent.prompt(agent, "Turn 3")
    events3 = collect_until_agent_end([])

    all_events = events1 ++ events2 ++ events3

    reconstructed_messages = rebuild_state(all_events)

    # Get final messages from the last agent_end event
    {:agent_end, final_messages} = List.last(events3)

    assert length(reconstructed_messages) == 6
    assert length(final_messages) == 6

    # Verify each message matches
    Enum.zip(reconstructed_messages, final_messages)
    |> Enum.each(fn {rebuilt, final} ->
      assert rebuilt.id == final.id
      assert rebuilt.role == final.role
      assert rebuilt.content == final.content
    end)
  end

  defp collect_until_agent_end(acc) do
    receive do
      {:agent_end, _} = event ->
        Enum.reverse([event | acc])

      event ->
        collect_until_agent_end([event | acc])
    after
      2000 ->
        flunk("Timed out waiting for agent_end event. Collected so far: #{inspect(Enum.reverse(acc))}")
    end
  end

  defp rebuild_state(events) do
    Enum.reduce(events, [], fn event, acc ->
      case event do
        {:message_start, msg} ->
          if Enum.any?(acc, fn m -> m.id == msg.id end) do
            # If message exists, update it (though message_start is usually the first time we see it)
            Enum.map(acc, fn m ->
              if m.id == msg.id, do: msg, else: m
            end)
          else
            # Append new message
            acc ++ [msg]
          end

        {:message_update, msg, _} ->
          Enum.map(acc, fn m ->
            if m.id == msg.id, do: msg, else: m
          end)

        {:message_end, msg} ->
          Enum.map(acc, fn m ->
            if m.id == msg.id, do: msg, else: m
          end)

        _ ->
          acc
      end
    end)
  end
end
