defmodule Sigma.Coding.IntegrationTest do
  use ExUnit.Case

  alias Sigma.Agent.Message

  defmodule MockProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params) do
      # 1st turn: User "Read hello.txt" -> Assistant calls "read"
      # 2nd turn: Tool Result "Hello world" -> Assistant says "Done"
      
      messages = params.context.messages
      last_msg = List.last(messages)

      cond do
        last_msg.role == :user and last_msg.content == "Read hello.txt" ->
          tc = %{type: :tool_call, id: "tc1", name: "read", arguments: %{"path" => "hello.txt"}}
          ai_msg = %{
            role: :assistant,
            content: [tc],
            api: "mock",
            provider: "mock",
            model: "mock",
            usage: %{input: 0, output: 0, cache_read: 0, cache_write: 0, total_tokens: 0, cost: %{total: 0.0, input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0}},
            stop_reason: :tool_use,
            timestamp: System.system_time(:millisecond)
          }
          [{:start, ai_msg}, {:done, :tool_use, ai_msg}]

        last_msg.role == :tool_result ->
          ai_msg = %{
            role: :assistant,
            content: [%{type: :text, text: "I read the file. It says: Hello world"}],
            api: "mock",
            provider: "mock",
            model: "mock",
            usage: %{input: 0, output: 0, cache_read: 0, cache_write: 0, total_tokens: 0, cost: %{total: 0.0, input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0}},
            stop_reason: :stop,
            timestamp: System.system_time(:millisecond)
          }
          [{:start, ai_msg}, {:done, :stop, ai_msg}]

        true ->
          []
      end
    end
  end

  setup do
    tmp_dir = Path.expand("../../tmp/integration_test", __DIR__)
    File.mkdir_p!(tmp_dir)
    File.write!(Path.join(tmp_dir, "hello.txt"), "Hello world")
    
    # Start Dispatcher - it's already started by the application
    
    {:ok, tmp_dir: tmp_dir}
  end

  test "agent executes a tool and continues", %{tmp_dir: tmp_dir} do
    model = %{id: "mock-model", api: "mock", provider: "mock"}

    {:ok, agent} = Sigma.Agent.start_link(
      model: model,
      provider: MockProvider,
      tools: [Sigma.Coding.Tools.Read],
      system_prompt: "You are a helpful assistant.",
      cwd: tmp_dir
    )

    Sigma.Agent.subscribe(agent)

    # We need to pass the tmp_dir as cwd to tools.
    # For now, let's assume Sigma.Agent or Dispatcher can be configured with cwd.
    # Actually, the Dispatcher dispatch call needs opts.
    # Let's update Sigma.Agent to allow passing opts to execute_tools.
    
    # Wait, the current implementation of execute_tools in Sigma.Agent doesn't pass cwd.
    # I'll need to fix that.
    
    Sigma.Agent.prompt(agent, "Read hello.txt")

    # Turn 1
    assert_receive {:agent_start, _}
    assert_receive {:turn_start}
    assert_receive {:tool_execution_start, "tc1", "read", _}
    
    # Turn 2 (continuation)
    assert_receive {:turn_start}
    assert_receive {:message_end, %Message{role: :assistant}} # Final message
    
    assert_receive {:agent_end, messages}

    assert length(messages) == 4
    # User, Assistant (tool_call), Tool Result, Assistant (final)
    [m1, m2, m3, m4] = messages
    assert m1.role == :user
    assert m2.role == :assistant
    assert Enum.any?(m2.content, & &1.type == :tool_call)
    assert m3.role == :tool_result
    assert [%{type: :text, text: text}] = m3.content
    assert text =~ "Hello world"
    assert m4.role == :assistant
    assert Enum.any?(m4.content, & &1.text =~ "Hello world")
  end
end
