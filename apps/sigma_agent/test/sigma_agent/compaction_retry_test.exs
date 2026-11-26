defmodule Sigma.Agent.CompactionRetryTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.Compaction
  alias Sigma.Ai.{ProviderError, ProviderEvent}

  defmodule Provider do
    def stream_normalized(request) do
      attempt = :atomics.add_get(request.options[:counter], 1, 1)

      if attempt <= request.options[:failures] do
        [
          %ProviderEvent{
            type: :response_failed,
            error: %ProviderError{
              kind: :transport_unavailable,
              message: "summary lost",
              retry_class: request.options[:retry_class]
            }
          }
        ]
      else
        [%ProviderEvent{type: :response_completed, message: %{content: "complete summary"}}]
      end
    end
  end

  for class <- [:stream, :connection] do
    @class class
    test "#{class} summary failures have five replacement attempts" do
      state = state(retry_class: @class, failures: 99)
      assert {:error, _, ids} = summarize(state)
      assert length(ids) == 6
      assert :atomics.get(state.provider_options[:counter], 1) == 6
      assert length(Enum.uniq(ids)) == 6
    end
  end

  test "a recovered summary retains each attempt's metrics and request identity" do
    state = state(retry_class: :stream, failures: 2)
    assert {:ok, "complete summary", ids} = summarize(state)
    assert length(ids) == 3
    facts = for _ <- 1..6, do: receive(do: (fact -> fact))
    assert Enum.count(facts, &match?({:request_started, _, _}, &1)) == 3
    assert Enum.count(facts, &match?({:request_finished, %{status: :failed}, _}, &1)) == 2
    assert Enum.count(facts, &match?({:request_finished, %{status: :completed}, _}, &1)) == 1
  end

  test "unclassified and explicitly disabled summary retries stay terminal" do
    for options <- [[failures: 99], [retry_class: :stream, failures: 99, retry: false]] do
      state = state(options)
      assert {:error, _, [_]} = summarize(state)
      assert :atomics.get(state.provider_options[:counter], 1) == 1
    end
  end

  test "cancellation during backoff starts no replacement request" do
    state = state(retry_class: :stream, failures: 99, retry_delay: 500)
    task = Task.async(fn -> summarize(state) end)
    assert_receive {:request_finished, %{status: :failed}, _}
    :atomics.put(state.cancelled, 1, 1)
    assert {:error, %ProviderError{kind: :cancelled}, [_]} = Task.await(task)
    assert :atomics.get(state.provider_options[:counter], 1) == 1
  end

  defp state(options) do
    owner = self()
    counter = :atomics.new(1, [])
    cancelled = :atomics.new(1, [])

    %{
      provider: Provider,
      model: %{id: "summary"},
      provider_options: Keyword.merge([counter: counter, retry_delay: 0], options),
      session_id: "summary-retry",
      log_session_id: nil,
      turn_id: "summary-retry",
      context_window: 65_536,
      cancelled: cancelled,
      cancelled?: fn -> :atomics.get(cancelled, 1) == 1 end,
      emit: fn event, request, reason -> send(owner, {event, request, reason}) end
    }
  end

  defp summarize(state),
    do: Compaction.summarize([%{role: :user, content: "earlier work"}], state)
end
