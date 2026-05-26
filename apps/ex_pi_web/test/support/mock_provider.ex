defmodule PiWeb.MockProvider do
  @behaviour PiAi.Provider

  @impl true
  def stream(params) do
    options = Map.get(params, :options, [])
    input = Keyword.get(options, :mock_input, 10)
    response = Keyword.get(options, :mock_response, "I am a mock response.")

    initial_msg = %{
      role: :assistant,
      content: [],
      model: "mock-model",
      provider: "mock-provider",
      api: "mock-api",
      usage: %{
        input: input,
        output: 0,
        cache_read: 0,
        cache_write: 0,
        total_tokens: input,
        cost: %{total: 0.0, input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0}
      },
      stop_reason: nil,
      timestamp: System.system_time(:millisecond)
    }

    delta_msg = %{initial_msg | content: [%{type: :text, text: response}]}

    done_msg = %{
      delta_msg
      | stop_reason: :stop,
        usage: %{delta_msg.usage | output: 1, total_tokens: input + 1}
    }

    [
      {:start, initial_msg},
      {:text_delta, 0, response, delta_msg},
      {:done, :stop, done_msg}
    ]
  end
end
