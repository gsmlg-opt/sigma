defmodule Sigma.Coding.IntegrationTest do
  use ExUnit.Case

  alias Sigma.Agent.Message

  @moduletag :tmp_dir

  defmodule IntegrationProbe do
    @behaviour Sigma.Coding.Tool

    @impl true
    def name, do: "integration_probe"
    @impl true
    def description, do: "Echoes a test payload"
    @impl true
    def schema do
      %{
        "type" => "object",
        "properties" => %{"text" => %{"type" => "string"}},
        "required" => ["text"]
      }
    end

    @impl true
    def metadata, do: %{effect: :read, concurrency: :shared, interruptible: true}

    @impl true
    def execute(_id, %{"text" => text}, _opts) do
      {:ok, %{content: [%{type: :text, text: text}], details: %{}}}
    end
  end

  defmodule MockProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params) do
      # 1st turn: User "Run probe" -> Assistant calls the test tool
      # 2nd turn: Tool Result "Hello world" -> Assistant says "Done"

      messages = params.context.messages
      last_msg = List.last(messages)

      cond do
        last_msg.role == :user and last_msg.content == "Run probe" ->
          tc = %{
            type: :tool_call,
            id: "tc1",
            name: "integration_probe",
            arguments: %{"text" => "Hello world"}
          }

          ai_msg = %{
            role: :assistant,
            content: [tc],
            api: "mock",
            provider: "mock",
            model: "mock",
            usage: %{
              input: 0,
              output: 0,
              cache_read: 0,
              cache_write: 0,
              total_tokens: 0,
              cost: %{total: 0.0, input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0}
            },
            stop_reason: :tool_use,
            timestamp: System.system_time(:millisecond)
          }

          [{:start, ai_msg}, {:done, :tool_use, ai_msg}]

        last_msg.role == :tool_result ->
          ai_msg = %{
            role: :assistant,
            content: [%{type: :text, text: "The probe returned: Hello world"}],
            api: "mock",
            provider: "mock",
            model: "mock",
            usage: %{
              input: 0,
              output: 0,
              cache_read: 0,
              cache_write: 0,
              total_tokens: 0,
              cost: %{total: 0.0, input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0}
            },
            stop_reason: :stop,
            timestamp: System.system_time(:millisecond)
          }

          [{:start, ai_msg}, {:done, :stop, ai_msg}]

        true ->
          []
      end
    end
  end

  setup %{tmp_dir: tmp_dir} do
    File.mkdir_p!(tmp_dir)

    # Start Dispatcher - it's already started by the application

    {:ok, tmp_dir: tmp_dir}
  end

  test "agent executes a tool and continues", %{tmp_dir: tmp_dir} do
    model = %{id: "mock-model", api: "mock", provider: "mock"}

    {:ok, agent} =
      start_supervised(
        {Sigma.Agent,
         [
           model: model,
           provider: MockProvider,
           tools: [IntegrationProbe],
           system_prompt: "You are a helpful assistant.",
           backplane_runtime_path: Path.join(tmp_dir, "runtime"),
           cwd: tmp_dir
         ]}
      )

    Sigma.Agent.subscribe(agent)

    Sigma.Agent.prompt(agent, "Run probe")

    # Turn 1
    assert_receive {:agent_start, _}
    assert_receive {:turn_start}
    assert_receive {:tool_execution_start, "tc1", "integration_probe", _}

    # Turn 2 (continuation)
    assert_receive {:turn_start}
    # Final message
    assert_receive {:message_end, %Message{role: :assistant}}

    assert_receive {:agent_end, messages}

    assert length(messages) == 4
    # User, Assistant (tool_call), Tool Result, Assistant (final)
    [m1, m2, m3, m4] = messages
    assert m1.role == :user
    assert m2.role == :assistant
    assert Enum.any?(m2.content, &(&1.type == :tool_call))
    assert m3.role == :tool_result
    assert [%{type: :text, text: text}] = m3.content
    assert text =~ "Hello world"
    assert m4.role == :assistant
    assert Enum.any?(m4.content, &(&1.text =~ "Hello world"))
  end
end
