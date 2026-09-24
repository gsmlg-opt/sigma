defmodule Sigma.AgentTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.Message
  alias Sigma.Agent.SessionContext
  alias Sigma.Coding.Hooks.Spec
  alias Sigma.Coding.Hooks.Spec.Command

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
          visible_output: 0,
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
          usage: %{delta_msg.usage | output: 1, visible_output: 1, total_tokens: 11}
      }

      [
        {:start, initial_msg},
        {:text_delta, 0, "Hello", delta_msg},
        {:done, :stop, done_msg}
      ]
    end
  end

  defmodule CapturingProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params) do
      send(params.options[:test_pid], {:provider_params, params})
      MockProvider.stream(params)
    end
  end

  test "preserves rich user content for the provider and final history" do
    model = %{id: "mock-model", api: "mock-api", provider: "mock-provider"}
    image = %{type: :image, data: "iVBORw0KGgo=", mime_type: "image/png"}

    {:ok, agent} =
      Sigma.Agent.start_link(
        model: model,
        provider: CapturingProvider,
        options: [test_pid: self()]
      )

    Sigma.Agent.subscribe(agent)
    Sigma.Agent.prompt(agent, [%{type: :text, text: "Describe"}, image])

    assert_receive {:provider_params, %{context: %{messages: [%{content: content}]}}}
    assert content == [%{type: :text, text: "Describe"}, image]
    assert_receive {:agent_end, [%{role: :user, content: ^content} | _]}
  end

  test "hook context is leading text while preserving rich content" do
    model = %{id: "mock-model", api: "mock-api", provider: "mock-provider"}
    image = %{type: :image, data: "iVBORw0KGgo=", mime_type: "image/png"}
    spec = hook_spec("echo '{\"hookSpecificOutput\":{\"additionalContext\":\"extra\"}}'")

    {:ok, agent} =
      Sigma.Agent.start_link(
        model: model,
        provider: CapturingProvider,
        options: [test_pid: self()]
      )

    Sigma.Agent.subscribe(agent)
    :sys.replace_state(agent, &%{&1 | hook_specs: [spec]})
    malformed = %{type: :text, text: 42}

    Sigma.Agent.prompt(agent, [
      %{type: :text, text: "Describe"},
      %{type: :text, text: ""},
      image,
      malformed,
      %{type: :text, text: "more"}
    ])

    assert_receive {:provider_params, %{context: %{messages: [%{content: content}]}}}

    assert content == [
             %{type: :text, text: "Describe\n\nmore\n\n[Additional context from hook]\nextra"},
             image,
             malformed
           ]

    assert_receive {:agent_end, _}

    {:ok, image_only_agent} =
      Sigma.Agent.start_link(
        model: model,
        provider: CapturingProvider,
        options: [test_pid: self()]
      )

    :sys.replace_state(image_only_agent, &%{&1 | hook_specs: [spec]})
    Sigma.Agent.prompt(image_only_agent, [image])

    assert_receive {:provider_params, %{context: %{messages: [%{content: image_only}]}}}

    assert image_only == [
             %{type: :text, text: "[Additional context from hook]\nextra"},
             image
           ]
  end

  test "blocking user prompt hook cancels the rich turn" do
    model = %{id: "mock-model", api: "mock-api", provider: CapturingProvider}
    image = %{type: :image, data: "iVBORw0KGgo=", mime_type: "image/png"}
    spec = hook_spec("sh -c 'printf blocked >&2; exit 2'")

    {:ok, agent} =
      Sigma.Agent.start_link(
        model: model,
        provider: CapturingProvider,
        options: [test_pid: self()]
      )

    :sys.replace_state(agent, &%{&1 | hook_specs: [spec]})
    Sigma.Agent.subscribe(agent)
    Sigma.Agent.prompt(agent, [%{type: :text, text: "Describe"}, image])

    assert_receive {:turn_blocked, _}
    refute_receive {:provider_params, _}, 100
    assert_receive {:agent_end, []}
  end

  defp hook_spec(cmd) do
    %Spec{
      event: :user_prompt_submit,
      matcher: :any,
      handler: %Command{cmd: cmd, timeout_ms: 1_000},
      origin: {:user, "test"},
      dialect: :claude,
      trusted?: true
    }
  end

  defmodule EmptyProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(_params), do: []
  end

  defmodule BlockingStatusProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params) do
      send(params.options[:test_pid], {:provider_running, self()})

      receive do
        :release_provider -> MockProvider.stream(params)
      end
    end
  end

  defmodule LeafWriter do
    use GenServer

    def start_link(active_leaf), do: GenServer.start_link(__MODULE__, active_leaf)
    def put_leaf(writer, active_leaf), do: GenServer.call(writer, {:put_leaf, active_leaf})

    @impl true
    def init(active_leaf), do: {:ok, active_leaf}

    @impl true
    def handle_call(:flush, _from, active_leaf) do
      {:reply, {:ok, %{active_leaf_id: active_leaf}}, active_leaf}
    end

    def handle_call({:put_leaf, active_leaf}, _from, _previous) do
      {:reply, :ok, active_leaf}
    end
  end

  defmodule RaisingRuntimeProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(_params), do: raise("provider exploded")
  end

  defmodule PartialToolCallProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(_params) do
      msg = %{
        role: :assistant,
        content: [
          %{
            type: :tool_call,
            id: "partial_tool_call",
            name: "capture_prompt_opts",
            partial_json: "{}"
          }
        ],
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
        stop_reason: :tool_use,
        timestamp: System.system_time(:millisecond)
      }

      [{:start, msg}, {:done, :tool_use, msg}]
    end
  end

  defmodule PromptDispatcherProvider do
    @behaviour Sigma.Ai.Provider

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
    @behaviour Sigma.Coding.Tool

    @impl true
    def name, do: "capture_prompt_opts"

    @impl true
    def description, do: "Captures dispatcher options."

    @impl true
    def schema, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def execute(_tool_call_id, _params, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)

      send(test_pid, {:dispatcher_opts_seen, opts[:per_prompt_value]})

      if Keyword.get(opts, :capture_transcript_path) do
        send(test_pid, {:transcript_path_seen, opts[:transcript_path]})
      end

      {:ok, %{content: [%{type: :text, text: "captured"}]}}
    end
  end

  defmodule PartialPromptDispatcherTool do
    @behaviour Sigma.Coding.Tool

    @impl true
    def name, do: "capture_prompt_opts"
    @impl true
    def description, do: "Streams partial output."
    @impl true
    def schema, do: %{}
    @impl true
    def metadata, do: %{effect: :read, concurrency: :shared, default_deadline_ms: 1_000}

    @impl true
    def execute(_tool_call_id, _params, opts) do
      update = Keyword.fetch!(opts, :on_update)
      update.(%{content: [%{type: :text, text: "first"}], details: %{}})
      update.(%{content: [%{type: :text, text: "second"}], details: %{}})
      {:ok, %{content: [%{type: :text, text: "done"}], details: %{}}}
    end
  end

  defmodule CrashingPromptDispatcherTool do
    @behaviour Sigma.Coding.Tool

    @impl true
    def name, do: "capture_prompt_opts"
    @impl true
    def description, do: "Crashes for isolation coverage."
    @impl true
    def schema, do: %{}

    @impl true
    def execute(_tool_call_id, _params, _opts), do: raise("tool exploded")
  end

  defmodule LoopBreakerProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params) do
      tool_result_count = Enum.count(params.context.messages, &(&1.role == :tool_result))

      content =
        if tool_result_count < 3 do
          [
            %{
              type: :tool_call,
              id: "tc_loop_#{tool_result_count}",
              name: "mcp__test__fail",
              arguments: %{"query" => "same"}
            }
          ]
        else
          [%{type: :text, text: "Stopped"}]
        end

      stop_reason = if tool_result_count < 3, do: :tool_use, else: :stop
      msg = ai_msg(content, stop_reason)
      [{:start, msg}, {:done, stop_reason, msg}]
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

  defmodule TransportFailureTool do
    @behaviour Sigma.Coding.Tool

    @impl true
    def name, do: "mcp__test__fail"
    @impl true
    def description, do: "Always fails at the transport boundary."
    @impl true
    def schema, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def execute(_tool_call_id, _params, _opts) do
      {:transport_failure, "Send failure", name(), "test", %{original_reason: :closed}}
    end
  end

  test "agent manages a turn and emits events" do
    model = %{id: "mock-model", api: "mock-api", provider: "mock-provider"}

    {:ok, agent} =
      Sigma.Agent.start_link(
        model: model,
        provider: MockProvider,
        system_prompt: "You are a helpful assistant."
      )

    Sigma.Agent.subscribe(agent)

    Sigma.Agent.prompt(agent, "Hi")

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
    assert assistant.metadata.turn_id =~ "turn_"
  end

  test "persists one provider request fact with normalized usage and timing" do
    model = %{id: "mock-model", api: "mock-api", provider: "mock-provider"}
    test_pid = self()

    {:ok, agent} =
      Sigma.Agent.start_link(
        model: model,
        provider: MockProvider,
        on_event: fn event ->
          send(test_pid, {:agent_fact, event})
          :ok
        end
      )

    Sigma.Agent.prompt(agent, "facts")

    assert_receive {:agent_fact, {:metrics, :request_started, started}},
                   5_000

    assert is_binary(started.request_id)
    assert started.turn_id =~ "turn_"
    assert started.status == :running

    assert_receive {:agent_fact, {:metrics, :request_finished, finished}},
                   5_000

    assert finished.request_id == started.request_id
    assert is_binary(finished.message_id)
    assert finished.status == :completed
    assert finished.elapsed_ms >= 0
    assert finished.first_output_ms >= 0
    assert finished.ttft_ms >= 0
    assert finished.input_tokens_total == 10
    assert finished.output_tokens_total == 1
    assert finished.visible_output_tokens == 1
    assert finished.usage_status == :reported
  end

  test "publishes durable turn lifecycle facts and authoritative context state" do
    test_pid = self()

    {:ok, writer} = LeafWriter.start_link("leaf-1")

    model = %{
      id: "mock-model",
      api: "mock-api",
      provider: "mock-provider",
      context_window: 100_000,
      max_output_tokens: 1_000
    }

    {:ok, agent} =
      Sigma.Agent.start_link(
        session_id: "runtime-context",
        active_leaf: "leaf-1",
        context_revision: 7,
        model: model,
        provider: MockProvider,
        writer: writer,
        on_event: fn
          {:message_end, %{role: :user}} = event ->
            LeafWriter.put_leaf(writer, "leaf-user")
            send(test_pid, {:fact, event})

          {:message_end, %{role: :assistant}} = event ->
            LeafWriter.put_leaf(writer, "leaf-assistant")
            send(test_pid, {:fact, event})

          event ->
            send(test_pid, {:fact, event})
        end
      )

    Sigma.Agent.subscribe(agent)
    assert {:accepted, %{turn_id: turn_id}} = Sigma.Agent.prompt(agent, "facts")

    assert_receive {:fact,
                    {:metrics, :turn_started,
                     %{
                       turn_id: ^turn_id,
                       session_id: "runtime-context",
                       revision: 0,
                       status: :running,
                       reason: nil,
                       started_at: started_at
                     }}},
                   5_000

    assert {:ok, _started_at, 0} = DateTime.from_iso8601(started_at)

    assert_receive {:fact,
                    {:metrics, :turn_finished,
                     %{
                       turn_id: ^turn_id,
                       session_id: "runtime-context",
                       revision: 1,
                       status: :completed,
                       reason: nil,
                       started_at: ^started_at,
                       finished_at: finished_at,
                       wall_ms: wall_ms
                     }}},
                   5_000

    assert {:ok, _finished_at, 0} = DateTime.from_iso8601(finished_at)
    assert is_integer(wall_ms) and wall_ms >= 0
    assert_receive {:agent_end, _messages}, 5_000

    status = Sigma.Agent.status(agent)

    assert %Sigma.Agent.ContextPolicy{
             active_leaf: active_leaf,
             context_revision: revision,
             model: ^model,
             source: :provider_usage,
             last_request_input_tokens: 10,
             stale: true
           } = status.context_snapshot

    assert active_leaf == "leaf-assistant"
    assert revision > 7
    assert status.context_policy.check_phase == :before_provider_dispatch
    assert status.context_policy.estimate_stale
    assert status.context_policy.overflow == :within_budget

    Sigma.Agent.set_model(agent, %{id: "replacement", context_window: 200_000})
    changed = Sigma.Agent.status(agent).context_snapshot
    assert changed.model.id == "replacement"
    assert changed.source == :model_change
    assert changed.stale
  end

  test "status exposes the live request until its terminal fact is accepted" do
    test_pid = self()

    {:ok, agent} =
      Sigma.Agent.start_link(
        session_id: "live-request-status",
        model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
        provider: BlockingStatusProvider,
        options: [test_pid: test_pid],
        on_event: fn event -> send(test_pid, {:live_request_fact, event}) end
      )

    assert {:accepted, %{turn_id: turn_id}} = Sigma.Agent.prompt(agent, "wait")
    assert_receive {:provider_running, provider_task}, 5_000

    assert %{
             turn_id: ^turn_id,
             current_request_id: request_id,
             phase: :streaming_provider
           } = Sigma.Agent.status(agent)

    assert is_binary(request_id)
    send(provider_task, :release_provider)

    assert_receive {:live_request_fact,
                    {:metrics, :request_finished, %{request_id: ^request_id, status: :completed}}},
                   5_000

    assert_receive {:live_request_fact, {:metrics, :turn_finished, %{status: :completed}}}, 5_000

    assert %{
             current_request_id: nil,
             context_snapshot: %{last_request_id: ^request_id}
           } = Sigma.Agent.status(agent)
  end

  test "meters MCP sampling as an auxiliary provider request" do
    test_pid = self()

    {:ok, agent} =
      Sigma.Agent.start_link(
        session_id: "sampling-session",
        model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
        provider: MockProvider,
        on_event: fn event -> send(test_pid, {:sampling_fact, event}) end
      )

    assert {:ok, %{"content" => %{"text" => "Hello"}, "stopReason" => "endTurn"}} =
             GenServer.call(
               agent,
               {:mcp_sampling, %{"messages" => [%{"content" => "sample this"}]}},
               5_000
             )

    assert_receive {:sampling_fact,
                    {:metrics, :request_started,
                     %{request_id: request_id, purpose: :auxiliary, status: :running}}},
                   1_000

    assert_receive {:sampling_fact,
                    {:metrics, :request_finished,
                     %{
                       request_id: ^request_id,
                       purpose: :auxiliary,
                       status: :completed,
                       input_tokens_total: 10,
                       output_tokens_total: 1,
                       visible_output_tokens: 1
                     }}},
                   1_000
  end

  test "provider exceptions finish the same durable request as failed" do
    model = %{id: "mock-model", api: "mock-api", provider: "mock-provider"}
    test_pid = self()

    {:ok, agent} =
      Sigma.Agent.start_link(
        model: model,
        provider: RaisingRuntimeProvider,
        on_event: fn event ->
          send(test_pid, {:agent_fact, event})
          :ok
        end
      )

    Sigma.Agent.prompt(agent, "fail")

    assert_receive {:agent_fact, {:metrics, :request_started, started}}, 1_000
    assert_receive {:agent_fact, {:metrics, :request_finished, finished}}, 1_000
    assert finished.request_id == started.request_id
    assert finished.status == :failed
    assert finished.elapsed_ms >= 0
  end

  test "known hard context overflow fails before provider dispatch" do
    model = %{
      id: "mock-model",
      api: "mock-api",
      provider: "mock-provider",
      context_window: 10,
      max_output_tokens: 8
    }

    {:ok, agent} =
      Sigma.Agent.start_link(
        model: model,
        provider: CapturingProvider,
        system_prompt: "x",
        options: [test_pid: self()]
      )

    Sigma.Agent.subscribe(agent)
    Sigma.Agent.prompt(agent, "This request cannot fit in ten tokens")

    assert_receive {:turn_error, %Sigma.Ai.ProviderError{kind: :context_limit}}, 1_000
    refute_receive {:provider_params, _}, 100
    assert_receive {:agent_end, _messages}, 1_000
  end

  test "persists one tool fact at the dispatcher execution boundary" do
    model = %{id: "mock-model", api: "mock-api", provider: "mock-provider"}
    test_pid = self()

    {:ok, agent} =
      Sigma.Agent.start_link(
        model: model,
        provider: PromptDispatcherProvider,
        tools: [PromptDispatcherTool],
        dispatcher_opts: [test_pid: test_pid],
        on_event: fn event ->
          send(test_pid, {:agent_fact, event})
          :ok
        end
      )

    Sigma.Agent.prompt(agent, "tool facts")

    assert_receive {:agent_fact, {:metrics, :tool_finished, fact}}, 1_000
    assert fact.tool_id == "tc_prompt_opts"
    assert fact.turn_id =~ "turn_"
    assert fact.status == :completed
    assert is_integer(fact.elapsed_ms) and fact.elapsed_ms >= 0
    refute_receive {:agent_fact, {:metrics, :tool_finished, _}}, 100
  end

  test "agent reports an error when provider returns no assistant message" do
    model = %{id: "mock-model", api: "mock-api", provider: "mock-provider"}
    test_pid = self()

    {:ok, agent} =
      Sigma.Agent.start_link(
        model: model,
        provider: EmptyProvider,
        on_event: fn event -> send(test_pid, {:empty_provider_fact, event}) end
      )

    Sigma.Agent.subscribe(agent)
    Sigma.Agent.prompt(agent, "Hi")

    assert_receive {:turn_error,
                    %Sigma.Ai.ProviderError{
                      kind: :malformed_stream,
                      message: "stream_ended_without_terminal"
                    }}

    assert_receive {:empty_provider_fact, {:metrics, :request_finished, %{status: :failed}}}

    assert_receive {:agent_end, [%Message{role: :user, content: "Hi"}]}
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
      Sigma.Agent.start_link(
        model: model,
        provider: CapturingProvider,
        session_context: session_context,
        options: [test_pid: self()]
      )

    Sigma.Agent.subscribe(agent)
    Sigma.Agent.prompt(agent, "Hi")

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

    assert system_identity == "You are Sigma, an Elixir-based AI coding agent."
    assert system_policy =~ "You are an interactive agent"
    assert system_prompt =~ system_identity
    assert system_prompt =~ system_policy

    assert skills_reminder =~ "<name>repo-skill</name>"
    assert skills_reminder =~ "<description>Repository scoped skill</description>"
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
      Sigma.Agent.start_link(
        model: model,
        provider: MockProvider
      )

    Sigma.Agent.subscribe(agent)

    Sigma.Agent.prompt(agent, "First")
    # Wait for turn to complete
    assert_receive {:agent_end, _}

    Sigma.Agent.prompt(agent, "Second")
    assert_receive {:agent_end, messages}

    # Should have 4 messages: User, Assistant, User, Assistant
    assert length(messages) == 4
    assert Enum.map(messages, & &1.role) == [:user, :assistant, :user, :assistant]
    assert Enum.at(messages, 0).content == "First"
    assert Enum.at(messages, 2).content == "Second"
  end

  test "prompt accepts dispatcher opts scoped to the current turn" do
    model = %{id: "mock-model", api: "mock-api", provider: "mock-provider"}

    {:ok, agent} =
      Sigma.Agent.start_link(
        model: model,
        provider: PromptDispatcherProvider,
        tools: [PromptDispatcherTool]
      )

    Sigma.Agent.subscribe(agent)

    Sigma.Agent.prompt(agent, "Hi",
      dispatcher_opts: [test_pid: self(), per_prompt_value: :current_turn]
    )

    assert_receive {:dispatcher_opts_seen, :current_turn}
    assert_receive {:agent_end, messages}

    assert Enum.any?(
             messages,
             &(&1.role == :tool_result and &1.tool_name == "capture_prompt_opts")
           )
  end

  test "an explicit ask policy uses the per-turn approval resolver before tool execution" do
    model = %{id: "mock-model", api: "mock-api", provider: "mock-provider"}
    {:ok, policy} = Sigma.Coding.PermissionPolicy.start_link(default: :allow)
    Sigma.Coding.PermissionPolicy.ask_tool(policy, "capture_prompt_opts")
    test_pid = self()

    {:ok, agent} =
      Sigma.Agent.start_link(
        model: model,
        provider: PromptDispatcherProvider,
        tools: [PromptDispatcherTool],
        policy: policy
      )

    Sigma.Agent.subscribe(agent)

    Sigma.Agent.prompt(agent, "Hi",
      dispatcher_opts: [
        test_pid: test_pid,
        per_prompt_value: :approved,
        permission_request_fn: fn tool_call ->
          send(test_pid, {:permission_requested, tool_call.name})
          :allow
        end
      ]
    )

    assert_receive {:permission_requested, "capture_prompt_opts"}
    assert_receive {:dispatcher_opts_seen, :approved}
    assert_receive {:agent_end, messages}
    assert Enum.any?(messages, &(&1.role == :tool_result))
  end

  test "normalized partial tool updates reach Agent subscribers in order" do
    model = %{id: "mock-model", api: "mock-api", provider: "mock-provider"}

    {:ok, agent} =
      Sigma.Agent.start_link(
        model: model,
        provider: PromptDispatcherProvider,
        tools: [PartialPromptDispatcherTool]
      )

    Sigma.Agent.subscribe(agent)
    Sigma.Agent.prompt(agent, "Hi")

    assert_receive {:tool_execution_update, "tc_prompt_opts", "capture_prompt_opts", %{},
                    %Sigma.Coding.ToolUpdate{sequence: 1, content: [%{text: "first"}]}}

    assert_receive {:tool_execution_update, "tc_prompt_opts", "capture_prompt_opts", %{},
                    %Sigma.Coding.ToolUpdate{sequence: 2, content: [%{text: "second"}]}}

    assert_receive {:agent_end, _messages}
  end

  @tag :capture_log
  test "a crashing tool becomes an error result without crashing the Agent" do
    model = %{id: "mock-model", api: "mock-api", provider: "mock-provider"}

    {:ok, agent} =
      Sigma.Agent.start_link(
        model: model,
        provider: PromptDispatcherProvider,
        tools: [CrashingPromptDispatcherTool]
      )

    Sigma.Agent.subscribe(agent)
    Sigma.Agent.prompt(agent, "Hi")

    assert_receive {:agent_end, messages}
    assert Process.alive?(agent)

    assert Enum.any?(messages, fn
             %Message{role: :tool_result, is_error: true, content: [%{text: text}]} ->
               text =~ "tool exploded"

             _message ->
               false
           end)
  end

  test "injects a loop-breaker nudge after three identical transport failures" do
    model = %{id: "mock-model", api: "mock-api", provider: "mock-provider"}

    {:ok, agent} =
      Sigma.Agent.start_link(
        model: model,
        provider: LoopBreakerProvider,
        tools: [TransportFailureTool]
      )

    Sigma.Agent.subscribe(agent)
    Sigma.Agent.prompt(agent, "Hi")

    assert_receive {:message_end, %Message{role: :user, content: "[Loop breaker]" <> _ = nudge}},
                   3_000

    assert nudge =~ "`mcp__test__fail` has failed 3 times"
    assert_receive {:agent_end, messages}, 3_000
    assert Enum.count(messages, &(&1.role == :tool_result)) == 3

    assert Enum.count(
             messages,
             &match?(%Message{role: :user, content: "[Loop breaker]" <> _}, &1)
           ) == 1
  end

  test "tool transcript path uses the provided transcript path" do
    session_id = "shared-session"
    transcript_path = Path.join(System.tmp_dir!(), "provided-transcript.jsonl")
    cwd = File.cwd!()

    captured_path = captured_transcript_path(cwd, session_id, transcript_path)

    assert captured_path == transcript_path
  end

  test "agent does not dispatch partial tool call blocks" do
    model = %{id: "mock-model", api: "mock-api", provider: "mock-provider"}

    {:ok, agent} =
      Sigma.Agent.start_link(
        model: model,
        provider: PartialToolCallProvider,
        tools: [PromptDispatcherTool],
        dispatcher_opts: [test_pid: self()]
      )

    Sigma.Agent.subscribe(agent)
    Sigma.Agent.prompt(agent, "Hi")

    assert_receive {:agent_end, messages}
    refute_received {:dispatcher_opts_seen, _}
    refute_received {:turn_error, _}

    assert [
             %Message{role: :user, content: "Hi"},
             %Message{
               role: :assistant,
               content: [
                 %{
                   type: :tool_call,
                   id: "partial_tool_call",
                   partial_json: "{}"
                 }
               ]
             }
           ] = messages
  end

  defmodule CompactMockProvider do
    @behaviour Sigma.Ai.Provider

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

  defmodule CompactFailingSummaryProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(%{purpose: :compaction}) do
      [{:provider_error, Sigma.Ai.ProviderError.from_reason(:upstream_error)}]
    end

    def stream(params), do: CompactMockProvider.stream(params)
  end

  test "triggers compaction when input usage exceeds threshold" do
    model = %{id: "mock-model", api: "mock-api", provider: "mock-provider"}

    {:ok, agent} =
      Sigma.Agent.start_link(
        model: model,
        provider: CompactMockProvider,
        messages: compact_pre_messages()
      )

    Sigma.Agent.subscribe(agent)
    Sigma.Agent.prompt(agent, "Hi")

    assert_receive {:compact, %Message{role: :compaction_summary}, _first_kept_id}, 3000
    assert_receive {:agent_end, messages}, 3000
    assert Enum.any?(messages, &(&1.role == :compaction_summary))

    assert %{context_snapshot: %{source: :compaction, stale: false}} = Sigma.Agent.status(agent)
  end

  test "records durable compaction start and commit facts" do
    test_pid = self()

    {:ok, agent} =
      Sigma.Agent.start_link(
        model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
        provider: CompactMockProvider,
        messages: compact_pre_messages(),
        on_event: fn event -> send(test_pid, {:agent_event, event}) end
      )

    Sigma.Agent.prompt(agent, "Hi")

    assert_receive {:agent_event,
                    {:metrics, :compaction,
                     %{compaction_id: compaction_id, revision: 0, status: :started}}},
                   3_000

    assert_receive {:agent_event,
                    {:metrics, :request_started,
                     %{request_id: request_id, purpose: :compaction, status: :running}}},
                   3_000

    assert_receive {:agent_event,
                    {:metrics, :compaction,
                     %{
                       compaction_id: ^compaction_id,
                       revision: 1,
                       status: :committed,
                       summary_id: summary_id,
                       request_ids: [^request_id],
                       after_source: :estimated
                     }}},
                   3_000

    assert is_binary(summary_id)
    assert is_binary(request_id)

    assert_receive {:agent_event,
                    {:metrics, :request_finished,
                     %{
                       request_id: ^request_id,
                       purpose: :compaction,
                       status: :completed,
                       input_tokens_total: 0,
                       output_tokens_total: 5
                     }}},
                   3_000
  end

  test "links a failed compaction provider request to the failed compaction fact" do
    test_pid = self()

    {:ok, agent} =
      Sigma.Agent.start_link(
        model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
        provider: CompactFailingSummaryProvider,
        messages: compact_pre_messages(),
        on_event: fn event -> send(test_pid, {:agent_event, event}) end
      )

    Sigma.Agent.prompt(agent, "Hi")

    assert_receive {:agent_event,
                    {:metrics, :request_finished,
                     %{request_id: request_id, purpose: :compaction, status: :failed}}},
                   3_000

    assert_receive {:agent_event,
                    {:metrics, :compaction,
                     %{status: :failed, request_ids: [^request_id], failure_reason: reason}}},
                   3_000

    assert reason =~ "upstream_error"
  end

  test "does not compact below a large model context window" do
    model = %{
      id: "mock-model",
      api: "mock-api",
      provider: "mock-provider",
      context_window: 1_000_000
    }

    {:ok, agent} =
      Sigma.Agent.start_link(
        model: model,
        provider: CompactMockProvider,
        messages: compact_pre_messages()
      )

    Sigma.Agent.subscribe(agent)
    Sigma.Agent.prompt(agent, "Hi")

    assert_receive {:agent_end, messages}, 3000
    refute_receive {:compact, %Message{role: :compaction_summary}, _first_kept_id}, 200
    refute Enum.any?(messages, &(&1.role == :compaction_summary))
  end

  test "keeps a user question pending until it is answered" do
    {:ok, agent} =
      Sigma.Agent.start_link(
        model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
        provider: EmptyProvider
      )

    Sigma.Agent.subscribe(agent)

    task =
      Task.async(fn ->
        Sigma.Agent.ask_user_question(
          agent,
          %{question: "Pick one", options: [%{label: "A", value: "a"}], allow_freeform: true},
          timeout: 1_000
        )
      end)

    assert_receive {:ask_user_question, question_id, %{question: "Pick one"}}, 1_000
    assert [%{id: ^question_id, question: "Pick one"}] = Sigma.Agent.pending_user_questions(agent)

    assert :ok = Sigma.Agent.answer_user_question(agent, question_id, {:ok, "a"})
    assert {:ok, "a"} = Task.await(task)
    assert_receive {:ask_user_question_resolved, ^question_id}, 1_000
    assert [] = Sigma.Agent.pending_user_questions(agent)
  end

  test "handles MCP elicitation accept and decline" do
    {:ok, agent} =
      Sigma.Agent.start_link(
        model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
        provider: EmptyProvider
      )

    Sigma.Agent.subscribe(agent)

    schema = %{
      "type" => "object",
      "properties" => %{"name" => %{"type" => "string", "title" => "Name"}}
    }

    task =
      Task.async(fn ->
        Sigma.Agent.request_mcp_elicitation(agent, "What is your name?", schema, timeout: 1_000)
      end)

    assert_receive {:mcp_elicitation, elicitation_id, %{message: "What is your name?"}}, 1_000

    assert [%{id: ^elicitation_id, fields: [%{name: "name", type: "string"}]}] =
             Sigma.Agent.pending_mcp_elicitations(agent)

    assert :ok =
             Sigma.Agent.answer_mcp_elicitation(
               agent,
               elicitation_id,
               {:accept, %{"name" => "Ada"}}
             )

    assert {:accept, %{"name" => "Ada"}} = Task.await(task)
    assert_receive {:mcp_elicitation_resolved, ^elicitation_id}, 1_000
    assert [] = Sigma.Agent.pending_mcp_elicitations(agent)

    decline_task =
      Task.async(fn ->
        Sigma.Agent.request_mcp_elicitation(agent, "Confirm?", schema, timeout: 1_000)
      end)

    assert_receive {:mcp_elicitation, decline_id, %{message: "Confirm?"}}, 1_000
    assert :ok = Sigma.Agent.answer_mcp_elicitation(agent, decline_id, :decline)
    assert :decline = Task.await(decline_task)
  end

  test "rejects unsupported MCP elicitation schemas" do
    {:ok, agent} =
      Sigma.Agent.start_link(
        model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
        provider: EmptyProvider
      )

    assert {:error, :unsupported_schema} =
             Sigma.Agent.request_mcp_elicitation(agent, "Nested?", %{
               "type" => "object",
               "properties" => %{"nested" => %{"type" => "object"}}
             })
  end

  test "ignores tools/list_changed when no MCP subscriptions are active" do
    {:ok, agent} =
      Sigma.Agent.start_link(
        model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
        provider: EmptyProvider
      )

    send(agent, {:mcp_subscription, :unused, %{"method" => "notifications/tools/list_changed"}})
    assert Process.alive?(agent)
    assert :sys.get_state(agent).tools == []
  end

  test "handles pending user questions after hot reload from older state" do
    {:ok, agent} =
      Sigma.Agent.start_link(
        model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
        provider: EmptyProvider
      )

    Sigma.Agent.subscribe(agent)
    :sys.replace_state(agent, &Map.delete(&1, :pending_user_questions))

    assert [] = Sigma.Agent.pending_user_questions(agent)

    task =
      Task.async(fn ->
        Sigma.Agent.ask_user_question(agent, %{question: "Continue?"}, timeout: 1_000)
      end)

    assert_receive {:ask_user_question, question_id, %{question: "Continue?"}}, 1_000

    assert [%{id: ^question_id, question: "Continue?"}] =
             Sigma.Agent.pending_user_questions(agent)

    assert :ok = Sigma.Agent.answer_user_question(agent, question_id, {:ok, "yes"})
    assert {:ok, "yes"} = Task.await(task)
  end

  test "keeps a default user question pending until answered" do
    {:ok, agent} =
      Sigma.Agent.start_link(
        model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
        provider: EmptyProvider
      )

    Sigma.Agent.subscribe(agent)

    task = Task.async(fn -> Sigma.Agent.ask_user_question(agent, %{question: "Continue?"}) end)

    assert_receive {:ask_user_question, question_id, %{question: "Continue?"}}, 1_000
    assert is_nil(Task.yield(task, 50))
    assert :ok = Sigma.Agent.answer_user_question(agent, question_id, {:ok, "yes"})
    assert {:ok, "yes"} = Task.await(task)
  end

  defp compact_pre_messages do
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
  end

  defp captured_transcript_path(cwd, session_id, transcript_path) do
    model = %{id: "mock-model", api: "mock-api", provider: "mock-provider"}

    {:ok, agent} =
      Sigma.Agent.start_link(
        model: model,
        provider: PromptDispatcherProvider,
        tools: [PromptDispatcherTool],
        cwd: cwd,
        session_id: session_id,
        transcript_path: transcript_path,
        dispatcher_opts: [test_pid: self(), capture_transcript_path: true]
      )

    Sigma.Agent.subscribe(agent)
    Sigma.Agent.prompt(agent, "Hi")

    assert_receive {:transcript_path_seen, transcript_path}
    assert_receive {:agent_end, _messages}

    transcript_path
  end
end
