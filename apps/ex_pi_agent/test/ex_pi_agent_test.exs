defmodule PiAgentTest do
  use ExUnit.Case, async: true

  alias PiAgent.Message

  defmodule MockProvider do
    def stream(_params) do
      # Simulate a simple assistant response: "Hello"
      initial_msg = %{
        role: :assistant,
        content: [],
        model: "mock-model",
        provider: "mock-provider",
        api: "mock-api",
        usage: %{
          input: 10,
          output: 0,
          cache_read: 0,
          cache_write: 0,
          total_tokens: 10,
          cost: %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0, total: 0.0}
        },
        stop_reason: nil,
        timestamp: System.system_time(:millisecond)
      }

      delta_msg = %{initial_msg | content: [%{type: :text, text: "Hello"}]}
      done_msg = %{delta_msg | stop_reason: :stop, usage: %{delta_msg.usage | output: 1, total_tokens: 11}}

      [
        {:start, initial_msg},
        {:text_delta, 0, "Hello", delta_msg},
        {:done, :stop, done_msg}
      ]
    end
  end

  test "agent manages a turn and emits events" do
    model = %{id: "mock-model", api: "mock-api", provider: "mock-provider"}

    {:ok, agent} = PiAgent.start_link(
      model: model,
      provider: MockProvider,
      system_prompt: "You are a helpful assistant."
    )

    PiAgent.subscribe(agent)

    PiAgent.prompt(agent, "Hi")

    assert_receive {:agent_start, _}
    assert_receive {:message_start, %Message{role: :user, content: "Hi"}}
    assert_receive {:message_end, %Message{role: :user}}

    assert_receive {:turn_start}
    assert_receive {:message_start, %Message{role: :assistant}}
    assert_receive {:message_update, %Message{role: :assistant}, {:text_delta, 0, "Hello", _}}
    assert_receive {:message_end, %Message{role: :assistant}}
    assert_receive {:turn_end, %Message{role: :assistant}, []}

    assert_receive {:agent_end, messages}

    assert length(messages) == 2
    [user, assistant] = messages

    assert user.role == :user
    assert user.content == "Hi"

    assert assistant.role == :assistant
    assert [%{type: :text, text: "Hello"}] = assistant.content
    assert assistant.stop_reason == :stop
    assert assistant.usage.total_tokens == 11
  end

  test "agent maintains history" do
    model = %{id: "mock-model", api: "mock-api", provider: "mock-provider"}

    {:ok, agent} = PiAgent.start_link(
      model: model,
      provider: MockProvider
    )

    PiAgent.subscribe(agent)

    PiAgent.prompt(agent, "First")
    # Wait for turn to complete
    assert_receive {:agent_end, _}

    PiAgent.prompt(agent, "Second")
    assert_receive {:agent_end, messages}

    # Should have 4 messages: User, Assistant, User, Assistant
    assert length(messages) == 4
    assert Enum.map(messages, & &1.role) == [:user, :assistant, :user, :assistant]
    assert Enum.at(messages, 0).content == "First"
    assert Enum.at(messages, 2).content == "Second"
  end
end
