defmodule PiAi.Providers.AnthropicTest do
  use ExUnit.Case, async: true

  alias PiAi.Providers.Anthropic
  alias PiAi.Stream

  @fixture_path Path.expand("../../fixtures/sse/anthropic_usage.txt", __DIR__)

  defp initial_message do
    %{
      role: :assistant,
      content: [],
      api: "anthropic",
      provider: "anthropic",
      model: "claude-3-5-sonnet-20241022",
      usage: %{
        input: 0,
        output: 0,
        cache_read: 0,
        cache_write: 0,
        total_tokens: 0,
        cost: %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0, total: 0.0}
      },
      stop_reason: nil,
      response_id: nil,
      timestamp: System.system_time(:millisecond)
    }
  end

  test "captures input tokens from message_start and merges with output from message_delta" do
    content = File.read!(@fixture_path)
    {events, ""} = Stream.decode("", content)

    {processed_events, _final_msg} = Anthropic.process_events(events, initial_message())

    assert {:done, :stop, ai_msg} = Enum.find(processed_events, &match?({:done, _, _}, &1))

    assert ai_msg.usage.input == 100_000
    assert ai_msg.usage.cache_read == 200
    assert ai_msg.usage.cache_write == 500
    assert ai_msg.usage.output == 50
    assert ai_msg.usage.total_tokens == 100_050
  end

  test "delta-only output_tokens without input fields preserves baseline input" do
    # message_delta with ONLY output_tokens (real Anthropic API omits input fields)
    events = [
      %{
        "type" => "message_start",
        "message" => %{
          "id" => "msg_1",
          "usage" => %{
            "input_tokens" => 5000,
            "cache_creation_input_tokens" => 100,
            "cache_read_input_tokens" => 50,
            "output_tokens" => 0
          }
        }
      },
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn"},
        "usage" => %{"output_tokens" => 200}
      },
      %{"type" => "message_stop"}
    ]

    {processed_events, _} = Anthropic.process_events(events, initial_message())

    assert {:done, :stop, ai_msg} = Enum.find(processed_events, &match?({:done, _, _}, &1))

    assert ai_msg.usage.input == 5_000
    assert ai_msg.usage.cache_read == 50
    assert ai_msg.usage.cache_write == 100
    assert ai_msg.usage.output == 200
    assert ai_msg.usage.total_tokens == 5_200
  end
end
