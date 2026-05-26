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

  defmodule EmptyProvider do
    @behaviour PiAi.Provider

    @impl true
    def stream(_params), do: []
  end

  defmodule PromptDispatcherProvider do
    @behaviour PiAi.Provider

    @impl true
    def stream(params) do
      last_msg = List.last(params.context.messages)

      if last_msg && last_msg.role == :tool_result do
        msg = ai_msg([%{type: :text, text: "Done"}], :stop)
        [{:start, msg}, {:done, :stop, msg}]
      else
        msg =
          ai_msg(
            [
              %{
                type: :tool_call,
                id: "tc_prompt_opts",
                name: "capture_prompt_opts",
                arguments: %{}
              }
            ],
            :tool_use
          )

        [{:start, msg}, {:done, :tool_use, msg}]
      end
    end

    defp ai_msg(content, stop_reason) do
      %{
        role: :assistant,
        content: content,
        model: "mock-model",
        provider: "mock-provider",
        api: "mock-api",
        usage: %{
          input: 0,
          output: 0,
          cache_read: 0,
          cache_write: 0,
          total_tokens: 0,
          cost: %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0, total: 0.0}
        },
        stop_reason: stop_reason,
        timestamp: System.system_time(:millisecond)
      }
    end
  end

  defmodule PromptDispatcherTool do
    @behaviour PiCoding.Tool

    @impl true
    def name, do: "capture_prompt_opts"

    @impl true
    def description, do: "Captures dispatcher options."

    @impl true
    def schema, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def execute(_tool_call_id, _params, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:dispatcher_opts_seen, opts[:per_prompt_value]})
      {:ok, %{content: [%{type: :text, text: "captured"}]}}
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

  test "agent reports an error when provider returns no assistant message" do
    model = %{id: "mock-model", api: "mock-api", provider: "mock-provider"}

    {:ok, agent} =
      PiAgent.start_link(
        model: model,
        provider: EmptyProvider
      )

    PiAgent.subscribe(agent)
    PiAgent.prompt(agent, "Hi")

    assert_receive {:turn_error, "AI provider returned no response."}, 1000
    assert_receive {:agent_end, [%Message{role: :user, content: "Hi"}]}, 1000
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
                    }},
                   1000

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

  test "prompt accepts dispatcher opts scoped to the current turn" do
    model = %{id: "mock-model", api: "mock-api", provider: "mock-provider"}

    {:ok, agent} =
      PiAgent.start_link(
        model: model,
        provider: PromptDispatcherProvider,
        tools: [PromptDispatcherTool]
      )

    PiAgent.subscribe(agent)

    PiAgent.prompt(agent, "Hi",
      dispatcher_opts: [test_pid: self(), per_prompt_value: :current_turn]
    )

    assert_receive {:dispatcher_opts_seen, :current_turn}, 1000
    assert_receive {:agent_end, messages}, 1000

    assert Enum.any?(
             messages,
             &(&1.role == :tool_result and &1.tool_name == "capture_prompt_opts")
           )
  end

  defmodule CompactMockProvider do
    @behaviour PiAi.Provider

    @impl true
    def stream(params) do
      if summary_request?(params) do
        msg = ai_msg([%{type: :text, text: "Compacted session summary."}], :stop, 0, 5)
        [{:start, msg}, {:done, :stop, msg}]
      else
        msg = ai_msg([%{type: :text, text: "Reply"}], :stop, 100_000, 20)
        [{:start, msg}, {:done, :stop, msg}]
      end
    end

    defp summary_request?(params) do
      case params.context.messages do
        [%{role: :user, content: [%{type: :text, text: "Create a detailed summary" <> _}]}] ->
          true

        _ ->
          false
      end
    end

    defp ai_msg(content, stop_reason, input, output) do
      %{
        role: :assistant,
        content: content,
        model: "mock-model",
        provider: "mock",
        api: "mock",
        usage: %{
          input: input,
          output: output,
          cache_read: 0,
          cache_write: 0,
          total_tokens: input + output,
          cost: %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0, total: 0.0}
        },
        stop_reason: stop_reason,
        timestamp: System.system_time(:millisecond)
      }
    end
  end

  test "triggers compaction when input usage exceeds threshold" do
    model = %{id: "mock-model", api: "mock-api", provider: "mock-provider"}

    # Pre-populate enough messages so find_compact_boundary has something to summarize
    pre_messages =
      Enum.flat_map(1..11, fn i ->
        [
          %Message{
            id: "u#{i}",
            role: :user,
            content: "msg #{i}",
            timestamp: i,
            metadata: %{}
          },
          %Message{
            id: "a#{i}",
            role: :assistant,
            content: [%{type: :text, text: "r#{i}"}],
            timestamp: i,
            usage: %{
              input: 100,
              output: 10,
              cache_read: 0,
              cache_write: 0,
              total_tokens: 110,
              cost: %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0, total: 0.0}
            }
          }
        ]
      end)

    {:ok, agent} =
      PiAgent.start_link(
        model: model,
        provider: CompactMockProvider,
        messages: pre_messages
      )

    PiAgent.subscribe(agent)
    PiAgent.prompt(agent, "Hi")

    assert_receive {:compact, %Message{role: :compaction_summary}, _first_kept_id}, 3000
    assert_receive {:agent_end, messages}, 3000
    assert Enum.any?(messages, &(&1.role == :compaction_summary))
  end

  test "keeps a user question pending until it is answered" do
    {:ok, agent} =
      PiAgent.start_link(
        model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
        provider: EmptyProvider
      )

    PiAgent.subscribe(agent)

    task =
      Task.async(fn ->
        PiAgent.ask_user_question(
          agent,
          %{question: "Pick one", options: [%{label: "A", value: "a"}], allow_freeform: true},
          timeout: 1_000
        )
      end)

    assert_receive {:ask_user_question, question_id, %{question: "Pick one"}}, 1_000
    assert [%{id: ^question_id, question: "Pick one"}] = PiAgent.pending_user_questions(agent)

    assert :ok = PiAgent.answer_user_question(agent, question_id, {:ok, "a"})
    assert {:ok, "a"} = Task.await(task)
    assert_receive {:ask_user_question_resolved, ^question_id}, 1_000
    assert [] = PiAgent.pending_user_questions(agent)
  end

  test "handles pending user questions after hot reload from older state" do
    {:ok, agent} =
      PiAgent.start_link(
        model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
        provider: EmptyProvider
      )

    PiAgent.subscribe(agent)
    :sys.replace_state(agent, &Map.delete(&1, :pending_user_questions))

    assert [] = PiAgent.pending_user_questions(agent)

    task =
      Task.async(fn ->
        PiAgent.ask_user_question(agent, %{question: "Continue?"}, timeout: 1_000)
      end)

    assert_receive {:ask_user_question, question_id, %{question: "Continue?"}}, 1_000
    assert [%{id: ^question_id, question: "Continue?"}] = PiAgent.pending_user_questions(agent)

    assert :ok = PiAgent.answer_user_question(agent, question_id, {:ok, "yes"})
    assert {:ok, "yes"} = Task.await(task)
  end
end
