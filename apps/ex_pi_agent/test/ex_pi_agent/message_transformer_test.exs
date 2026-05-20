defmodule PiAgent.MessageTransformerTest do
  use ExUnit.Case, async: true
  alias PiAgent.Message, as: AgentMessage
  alias PiAgent.MessageTransformer

  test "standard message conversion" do
    messages = [
      AgentMessage.user("1", "hello"),
      AgentMessage.assistant("2", %{
        content: "hi",
        api: "anthropic",
        provider: "anthropic",
        model: "claude-3"
      })
    ]

    converted = MessageTransformer.convert_to_llm(messages)

    assert length(converted) == 2
    assert Enum.at(converted, 0).role == :user
    assert Enum.at(converted, 0).content == "hello"
    assert Enum.at(converted, 1).role == :assistant
    assert Enum.at(converted, 1).content == [%{type: :text, text: "hi"}]
  end

  test "system message conversion" do
    messages = [
      AgentMessage.system("1", "you are a bot"),
      AgentMessage.user("2", "hello")
    ]

    converted = MessageTransformer.convert_to_llm(messages)

    assert length(converted) == 2
    assert Enum.at(converted, 0).role == :system
    assert Enum.at(converted, 0).content == "you are a bot"
    assert Enum.at(converted, 1).role == :user
  end

  test "redacted messages are dropped" do
    messages = [
      AgentMessage.user("1", "hello"),
      %AgentMessage{id: "2", role: :user, content: "secret", redacted: true},
      AgentMessage.user("3", "world")
    ]

    converted = MessageTransformer.convert_to_llm(messages)

    assert length(converted) == 2
    assert Enum.at(converted, 0).content == "hello"
    assert Enum.at(converted, 1).content == "world"
  end

  test "UI-only messages are dropped" do
    messages = [
      AgentMessage.user("1", "hello"),
      AgentMessage.status("2", "working"),
      AgentMessage.notification("3", "done"),
      AgentMessage.assistant("4", %{
        content: "hi",
        api: "anthropic",
        provider: "anthropic",
        model: "claude-3"
      })
    ]

    converted = MessageTransformer.convert_to_llm(messages)

    assert length(converted) == 2
    assert Enum.at(converted, 0).role == :user
    assert Enum.at(converted, 1).role == :assistant
  end

  test "thought messages are merged into next assistant message" do
    messages = [
      AgentMessage.user("1", "hello"),
      AgentMessage.thought("2", "thinking hard"),
      AgentMessage.thought("3", "still thinking"),
      AgentMessage.assistant("4", %{
        content: "hi",
        api: "anthropic",
        provider: "anthropic",
        model: "claude-3"
      })
    ]

    converted = MessageTransformer.convert_to_llm(messages)

    assert length(converted) == 2
    assistant = Enum.at(converted, 1)
    assert assistant.role == :assistant

    assert assistant.content == [
             %{type: :thinking, thinking: "thinking hard", redacted: false},
             %{type: :thinking, thinking: "still thinking", redacted: false},
             %{type: :text, text: "hi"}
           ]
  end

  test "orphaned thought messages are dropped" do
    messages = [
      AgentMessage.user("1", "hello"),
      AgentMessage.thought("2", "thinking hard")
    ]

    converted = MessageTransformer.convert_to_llm(messages)

    assert length(converted) == 1
    assert Enum.at(converted, 0).role == :user
  end

  test "tool result conversion" do
    messages = [
      AgentMessage.tool_result("1", %{tool_call_id: "tc1", tool_name: "test", content: "result"})
    ]

    converted = MessageTransformer.convert_to_llm(messages)

    assert length(converted) == 1
    msg = Enum.at(converted, 0)
    assert msg.role == :tool_result
    assert msg.tool_call_id == "tc1"
    assert msg.content == [%{type: :text, text: "result"}]
  end

  describe "transform_context/2" do
    test "returns messages unchanged by default" do
      messages = [AgentMessage.user("1", "hello")]
      assert MessageTransformer.transform_context(messages) == messages
    end

    test "applies transformations sequentially" do
      messages = [AgentMessage.user("1", "hello")]

      add_msg = fn msgs -> msgs ++ [AgentMessage.user("2", "world")] end

      upcase_last = fn msgs ->
        last = List.last(msgs)
        List.replace_at(msgs, -1, %{last | content: String.upcase(last.content)})
      end

      transformed =
        MessageTransformer.transform_context(messages, transforms: [add_msg, upcase_last])

      assert length(transformed) == 2
      assert Enum.at(transformed, 1).content == "WORLD"
    end
  end

  describe "prune_redacted/1" do
    test "removes redacted messages" do
      messages = [
        AgentMessage.user("1", "hello"),
        %AgentMessage{id: "2", role: :user, content: "secret", redacted: true},
        AgentMessage.user("3", "world")
      ]

      pruned = MessageTransformer.prune_redacted(messages)

      assert length(pruned) == 2
      assert Enum.at(pruned, 0).id == "1"
      assert Enum.at(pruned, 1).id == "3"
    end
  end

  describe "inject_system/2" do
    test "adds system message at the beginning" do
      messages = [AgentMessage.user("1", "hello")]
      injected = MessageTransformer.inject_system(messages, "you are a bot")

      assert length(injected) == 2
      assert Enum.at(injected, 0).role == :system
      assert Enum.at(injected, 0).content == "you are a bot"
      assert Enum.at(injected, 1).id == "1"
    end
  end

  describe "truncate_context/2" do
    test "limits messages to last n" do
      messages = [
        AgentMessage.user("1", "a"),
        AgentMessage.user("2", "b"),
        AgentMessage.user("3", "c")
      ]

      truncated = MessageTransformer.truncate_context(messages, 2)

      assert length(truncated) == 2
      assert Enum.at(truncated, 0).id == "2"
      assert Enum.at(truncated, 1).id == "3"
    end
  end

  describe "compaction_summary handling" do
    test "compaction_summary is converted to assistant role for valid alternation" do
      summary = %PiAgent.Message{
        id: "compaction_1",
        role: :compaction_summary,
        content: "Earlier we read lib/foo.ex and edited it.",
        timestamp: 0
      }

      user_msg = AgentMessage.user("u1", "what next?")

      converted = MessageTransformer.convert_to_llm([summary, user_msg])

      assert length(converted) == 2
      assert Enum.at(converted, 0).role == :assistant

      assert Enum.at(converted, 0).content == [
               %{
                 type: :text,
                 text:
                   "[Summary of earlier conversation]\n\nEarlier we read lib/foo.ex and edited it."
               }
             ]

      assert Enum.at(converted, 1).role == :user
    end
  end
end
