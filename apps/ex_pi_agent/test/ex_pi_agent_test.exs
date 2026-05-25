defmodule PiAgentTest do
  use ExUnit.Case, async: true

  alias PiAgent.Message
  alias PiAgent.SessionContext

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

      done_msg = %{
        delta_msg
        | stop_reason: :stop,
          usage: %{delta_msg.usage | output: 1, total_tokens: 11}
      }

      [
        {:start, initial_msg},
        {:text_delta, 0, "Hello", delta_msg},
        {:done, :stop, done_msg}
      ]
    end
  end

  defmodule CapturingProvider do
    @behaviour PiAi.Provider

    @impl true
    def stream(params) do
      send(params.options[:test_pid], {:provider_params, params})
      MockProvider.stream(params)
    end
  end

  test "agent manages a turn and emits events" do
    model = %{id: "mock-model", api: "mock-api", provider: "mock-provider"}

    {:ok, agent} =
      PiAgent.start_link(
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

  test "injects project context into the first user message sent to the provider" do
    model = %{id: "mock-model", api: "mock-api", provider: "mock-provider"}

    session_context =
      SessionContext.new(
        skills: [%{name: "repo-skill", description: "Repository scoped skill"}],
        global_agents: "global rules",
        repo_agents: "# Context: /repo/AGENTS.md\n\nproject rules",
        current_date: ~D[2026-05-25]
      )

    {:ok, agent} =
      PiAgent.start_link(
        model: model,
        provider: CapturingProvider,
        session_context: session_context,
        options: [test_pid: self()]
      )

    PiAgent.subscribe(agent)
    PiAgent.prompt(agent, "Hi")

    assert_receive {:provider_params,
                    %{
                      context: %{
                        system: [
                          %{type: :text, text: system_identity},
                          %{type: :text, text: system_policy}
                        ],
                        system_prompt: system_prompt,
                        messages: [
                          %{
                            role: :user,
                            content: [
                              %{type: :text, text: skills_reminder},
                              %{type: :text, text: agents_reminder},
                              %{type: :text, text: "Hi"}
                            ]
                          }
                        ]
                      }
                    }}

    assert system_identity == "You are Pi, an Elixir-based AI coding agent."
    assert system_policy =~ "You are an interactive agent"
    assert system_prompt =~ system_identity
    assert system_prompt =~ system_policy

    assert skills_reminder =~
             "<system-reminder>\nThe following skills are available for use with the Skill tool:\n\n"

    assert skills_reminder =~ "- repo-skill: Repository scoped skill"
    assert agents_reminder =~ "<system-reminder>\nAs you answer the user's questions"
    assert agents_reminder =~ "# agentsContext"
    assert agents_reminder =~ "global rules"
    assert agents_reminder =~ "# Context: /repo/AGENTS.md\n\nproject rules"
    assert agents_reminder =~ "# currentDate\nToday's date is 2026-05-25."

    assert_receive {:agent_end,
                    [%Message{role: :user, content: "Hi"}, %Message{role: :assistant}]}
  end

  test "agent maintains history" do
    model = %{id: "mock-model", api: "mock-api", provider: "mock-provider"}

    {:ok, agent} =
      PiAgent.start_link(
        model: model,
        provider: MockProvider
      )

    PiAgent.subscribe(agent)

    PiAgent.prompt(agent, "First")
    # Wait for turn to complete
    assert_receive {:agent_end, _}, 1000

    PiAgent.prompt(agent, "Second")
    assert_receive {:agent_end, messages}, 1000

    # Should have 4 messages: User, Assistant, User, Assistant
    assert length(messages) == 4
    assert Enum.map(messages, & &1.role) == [:user, :assistant, :user, :assistant]
    assert Enum.at(messages, 0).content == "First"
    assert Enum.at(messages, 2).content == "Second"
  end
end
