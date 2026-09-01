defmodule Sigma.Agent.ActiveTurnControlTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.Message

  defmodule BlockingProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params) do
      test_pid = Keyword.fetch!(params.options, :test_pid)
      cancellation_ref = Keyword.fetch!(params.options, :cancellation_ref)

      prompt =
        params.context.messages
        |> Enum.reverse()
        |> Enum.find(&(&1.role == :user))
        |> Map.fetch!(:content)

      Stream.resource(
        fn -> :waiting end,
        fn
          :done ->
            {:halt, :done}

          :waiting ->
            send(test_pid, {:provider_waiting, self(), prompt})

            receive do
              {:release_provider, response} ->
                message = ai_message(response)
                {[{:start, %{message | content: []}}, {:text_delta, 0, response, message}, {:done, :stop, message}], :done}

              {:cancel, ^cancellation_ref} ->
                {[{:provider_error, Sigma.Ai.ProviderError.from_reason(:cancelled)}], :done}
            end
        end,
        fn _state -> :ok end
      )
    end

    def ai_message(text) do
      %{
        role: :assistant,
        content: [%{type: :text, text: text}],
        model: "mock-model",
        provider: "mock-provider",
        api: "mock-api",
        usage: %{
          input: 1,
          output: 1,
          cache_read: 0,
          cache_write: 0,
          total_tokens: 2,
          cost: %{total: 0.0}
        },
        stop_reason: :stop,
        timestamp: System.system_time(:millisecond)
      }
    end
  end

  defmodule ToolProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params) do
      last = List.last(params.context.messages)

      content =
        if last && last.role == :tool_result do
          [%{type: :text, text: "done"}]
        else
          [%{type: :tool_call, id: "blocking-tool", name: "blocking", arguments: %{}}]
        end

      reason = if last && last.role == :tool_result, do: :stop, else: :tool_use
      message = BlockingProvider.ai_message("")
      message = %{message | content: content, stop_reason: reason}
      [{:start, %{message | content: []}}, {:done, reason, message}]
    end
  end

  defmodule NonCooperativeProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params) do
      test_pid = Keyword.fetch!(params.options, :test_pid)
      send(test_pid, {:noncooperative_provider_waiting, self()})

      receive do
        :release_noncooperative ->
          message = BlockingProvider.ai_message("released")
          [{:start, %{message | content: []}}, {:done, :stop, message}]
      end
    end
  end

  defmodule SteeringToolProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params) do
      last = List.last(params.context.messages)

      {content, reason} =
        case last do
          %{role: :user, content: "initial"} ->
            {[%{type: :tool_call, id: "blocking-tool", name: "blocking", arguments: %{}}],
             :tool_use}

          _message ->
            {[%{type: :text, text: "steering consumed"}], :stop}
        end

      message = BlockingProvider.ai_message("")
      message = %{message | content: content, stop_reason: reason}
      [{:start, %{message | content: []}}, {:done, reason, message}]
    end
  end

  defmodule BlockingTool do
    @behaviour Sigma.Coding.Tool

    @impl true
    def name, do: "blocking"
    @impl true
    def description, do: "blocking tool"
    @impl true
    def schema, do: %{}
    @impl true
    def metadata, do: %{effect: :process, concurrency: :exclusive, default_deadline_ms: 5_000}

    @impl true
    def execute(id, _params, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:tool_waiting, self()})
      cancellation_ref = Keyword.fetch!(opts, :signal)

      receive do
        {:abort, ^cancellation_ref} -> {:error, :cancelled}
        {:release_tool, ^id} -> {:ok, %{content: [%{type: :text, text: "released"}], details: %{}}}
      end
    end
  end

  setup do
    model = %{id: "mock-model", api: "mock-api", provider: "mock-provider"}

    {:ok, agent} =
      Sigma.Agent.start_link(
        model: model,
        provider: BlockingProvider,
        options: [test_pid: self()]
      )

    Sigma.Agent.subscribe(agent)
    {:ok, agent: agent}
  end

  test "admits steering and follow-up explicitly and consumes both FIFO", %{agent: agent} do
    assert {:accepted, %{message_id: initial_id, turn_id: first_turn}} =
             Sigma.Agent.prompt(agent, "initial")

    assert is_binary(initial_id)
    assert_receive {:provider_waiting, first_provider, "initial"}

    assert {:queued_as_steering, %{message_id: steering_id, turn_id: ^first_turn}} =
             Sigma.Agent.steer(agent, "steer")

    assert {:queued_as_follow_up, %{message_id: follow_up_id}} =
             Sigma.Agent.follow_up(agent, "follow")

    send(first_provider, {:release_provider, "first response"})
    assert_receive {:provider_waiting, steering_provider, "steer"}
    send(steering_provider, {:release_provider, "steered response"})

    assert_receive {:agent_end, first_messages}, 1_000

    assert Enum.map(first_messages, & &1.role) == [:user, :assistant, :user, :assistant]
    assert Enum.at(first_messages, 0).id == initial_id
    assert Enum.at(first_messages, 2).id == steering_id

    assert_receive {:provider_waiting, follow_up_provider, "follow"}
    send(follow_up_provider, {:release_provider, "follow response"})
    assert_receive {:agent_end, all_messages}, 1_000
    assert Enum.at(all_messages, 4).id == follow_up_id
  end

  test "multiple steering messages preserve FIFO order", %{agent: agent} do
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "initial")
    assert_receive {:provider_waiting, first_provider, "initial"}
    assert {:queued_as_steering, _} = Sigma.Agent.steer(agent, "one")
    assert {:queued_as_steering, _} = Sigma.Agent.steer(agent, "two")

    send(first_provider, {:release_provider, "initial response"})
    assert_receive {:provider_waiting, second_provider, "one"}
    send(second_provider, {:release_provider, "one response"})
    assert_receive {:provider_waiting, third_provider, "two"}
    send(third_provider, {:release_provider, "two response"})

    assert_receive {:agent_end, messages}, 1_000

    assert Enum.map(Enum.filter(messages, &(&1.role == :user)), & &1.content) ==
             ["initial", "one", "two"]
  end

  test "cancellation during provider streaming is idempotent and starts the preserved follow-up", %{
    agent: agent
  } do
    assert {:accepted, %{turn_id: turn_id}} = Sigma.Agent.prompt(agent, "initial")
    assert_receive {:provider_waiting, _provider, "initial"}
    assert {:queued_as_follow_up, _} = Sigma.Agent.follow_up(agent, "later")

    assert {:cancelling, ^turn_id} = Sigma.Agent.cancel(agent)
    assert {:already_cancelling, ^turn_id} = Sigma.Agent.cancel(agent)
    assert_receive {:turn_cancelled}, 1_000
    refute_receive {:turn_cancelled}, 100

    assert_receive {:provider_waiting, follow_up_provider, "later"}, 1_000
    assert %{follow_up_queue_count: 0} = Sigma.Agent.status(agent)
    send(follow_up_provider, {:release_provider, "followed"})
    assert_receive {:agent_end, _cancelled_messages}, 1_000
    assert_receive {:agent_end, _follow_up_messages}, 1_000

    assert {:accepted, _} = Sigma.Agent.prompt(agent, "usable again")
    assert_receive {:provider_waiting, provider, "usable again"}
    send(provider, {:release_provider, "ok"})
    assert_receive {:agent_end, _messages}, 1_000
  end

  test "cancellation during tool execution terminates the tool and keeps Agent alive" do
    model = %{id: "mock-model", api: "mock-api", provider: "mock-provider"}

    {:ok, agent} =
      Sigma.Agent.start_link(
        model: model,
        provider: ToolProvider,
        tools: [BlockingTool],
        dispatcher_opts: [test_pid: self()]
      )

    Sigma.Agent.subscribe(agent)
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "run tool")
    assert_receive {:tool_waiting, tool_pid}, 1_000
    assert {:cancelling, _turn_id} = Sigma.Agent.cancel(agent)
    assert_receive {:turn_cancelled}, 1_000
    refute Process.alive?(tool_pid)
    assert Process.alive?(agent)
  end

  test "steering during tool execution is consumed at the completed tool boundary" do
    model = %{id: "mock-model", api: "mock-api", provider: "mock-provider"}

    {:ok, agent} =
      Sigma.Agent.start_link(
        model: model,
        provider: SteeringToolProvider,
        tools: [BlockingTool],
        dispatcher_opts: [test_pid: self()]
      )

    Sigma.Agent.subscribe(agent)
    assert {:accepted, %{turn_id: turn_id}} = Sigma.Agent.prompt(agent, "initial")
    assert_receive {:tool_waiting, tool_pid}, 1_000

    assert {:queued_as_steering, %{turn_id: ^turn_id, message_id: steering_id}} =
             Sigma.Agent.steer(agent, "change course")

    send(tool_pid, {:release_tool, "blocking-tool"})
    assert_receive {:prompt_consumed, :steering, %{message_id: ^steering_id}}, 1_000
    assert_receive {:agent_end, messages}, 1_000

    assert Enum.map(Enum.filter(messages, &(&1.role == :user)), & &1.content) ==
             ["initial", "change course"]
  end

  test "cancellation while waiting for permission resolves the request without running the tool" do
    model = %{id: "mock-model", api: "mock-api", provider: "mock-provider"}
    {:ok, policy} = Sigma.Coding.PermissionPolicy.start_link(default: :allow)
    :ok = Sigma.Coding.PermissionPolicy.ask_tool(policy, "blocking")

    {:ok, agent} =
      Sigma.Agent.start_link(
        model: model,
        provider: ToolProvider,
        tools: [BlockingTool],
        policy: policy,
        dispatcher_opts: [test_pid: self()]
      )

    Sigma.Agent.subscribe(agent)
    test_pid = self()

    permission_request_fn = fn tool_call ->
      send(test_pid, {:permission_waiting, self(), tool_call.name})

      request = %{
        kind: :permission,
        question: "Allow #{tool_call.name}?",
        options: [%{label: "Allow", value: "allow", description: "Run it"}]
      }

      case Sigma.Agent.ask_user_question(agent, request, timeout: 5_000) do
        {:ok, "allow"} -> :allow
        {:error, reason} -> {:deny, reason}
      end
    end

    assert {:accepted, %{turn_id: turn_id}} =
             Sigma.Agent.prompt(agent, "run tool",
               dispatcher_opts: [permission_request_fn: permission_request_fn]
             )

    assert_receive {:permission_waiting, permission_pid, "blocking"}, 1_000
    assert %{phase: :waiting_permission} = Sigma.Agent.status(agent)
    assert {:cancelling, ^turn_id} = Sigma.Agent.cancel(agent)
    assert_receive {:turn_cancelled}, 1_000
    refute_receive {:tool_waiting, _tool_pid}, 100
    refute Process.alive?(permission_pid)
    assert Process.alive?(agent)
  end

  test "failed durable steering append keeps the queued message", %{agent: agent} do
    :sys.replace_state(agent, fn state ->
      %{state | on_event: fn
        {:message_end, %Message{content: "steer"}} -> {:error, :disk_full}
        _event -> :ok
      end}
    end)

    assert {:accepted, _} = Sigma.Agent.prompt(agent, "initial")
    assert_receive {:provider_waiting, provider, "initial"}
    assert {:queued_as_steering, _} = Sigma.Agent.steer(agent, "steer")
    send(provider, {:release_provider, "response"})

    assert_receive {:turn_error, {:event_persistence_failed, :message, :disk_full}}, 1_000
    assert %{steering_queue_count: 1} = Sigma.Agent.status(agent)

    assert Enum.map(:sys.get_state(agent).messages, & &1.role) == [:user, :assistant]
    assert Enum.map(:sys.get_state(agent).messages, & &1.content) == ["initial", [%{type: :text, text: "response"}]]
  end

  test "context reload is explicit and cannot change an active provider request", %{agent: agent} do
    old_context = Sigma.Agent.SessionContext.new(agents_context: "old rules")
    new_context = Sigma.Agent.SessionContext.new(agents_context: "new rules")
    assert :ok = Sigma.Agent.reload_context(agent, old_context)

    assert {:accepted, _admission} = Sigma.Agent.prompt(agent, "keep old request stable")
    assert_receive {:provider_waiting, _provider, provider_prompt}
    assert List.last(provider_prompt) == %{type: :text, text: "keep old request stable"}
    assert {:error, :session_busy} = Sigma.Agent.reload_context(agent, new_context)
    assert Sigma.Agent.context_preview(agent).text =~ "old rules"
    refute Sigma.Agent.context_preview(agent).text =~ "new rules"

    assert {:cancelling, _turn_id} = Sigma.Agent.cancel(agent)
    assert_receive {:turn_cancelled}, 1_000
    assert :ok = Sigma.Agent.reload_context(agent, new_context)
    assert Sigma.Agent.context_preview(agent).text =~ "new rules"
  end

  test "forced cancellation starts a preserved follow-up instead of stranding it" do
    model = %{id: "mock-model", api: "mock-api", provider: "mock-provider"}

    {:ok, agent} =
      Sigma.Agent.start_link(
        model: model,
        provider: NonCooperativeProvider,
        options: [test_pid: self()]
      )

    Sigma.Agent.subscribe(agent)
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "blocked")
    assert_receive {:noncooperative_provider_waiting, first_provider}, 1_000
    assert {:queued_as_follow_up, _} = Sigma.Agent.follow_up(agent, "preserved")
    assert {:cancelling, _turn_id} = Sigma.Agent.cancel(agent)
    assert_receive {:turn_cancelled}, 3_000
    refute Process.alive?(first_provider)
    assert_receive {:noncooperative_provider_waiting, follow_up_provider}, 1_000
    assert %{follow_up_queue_count: 0} = Sigma.Agent.status(agent)
    send(follow_up_provider, :release_noncooperative)
    assert_receive {:agent_end, _messages}, 1_000
  end
end
