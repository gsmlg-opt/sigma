defmodule ExPiWeb.MockProvider do
  @behaviour ExPiAi.Provider

  @impl true
  def stream(_params) do
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
        cost: %{total: 0.0, input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0}
      },
      stop_reason: nil,
      timestamp: System.system_time(:millisecond)
    }

    delta_msg = %{initial_msg | content: [%{type: :text, text: "I am a mock response."}]}

    done_msg = %{
      delta_msg
      | stop_reason: :stop,
        usage: %{delta_msg.usage | output: 1, total_tokens: 11}
    }

    [
      {:start, initial_msg},
      {:text_delta, 0, "I am a mock response.", delta_msg},
      {:done, :stop, done_msg}
    ]
  end
end
