defmodule Sigma.Agent.BackplaneOutputErrorTest do
  use ExUnit.Case, async: true

  alias Backplane.AgentRuntime.Error
  alias Sigma.Ai.{ProviderError, ProviderEvent}

  defmodule FailingProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params),
      do: [%ProviderEvent{type: :response_failed, error: params.options[:error]}]
  end

  defmodule SnapshotProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params) do
      text = params.options[:text]
      chunk_bytes = params.options[:chunk_bytes]

      message = %{
        role: :assistant,
        content: [],
        model: "mock-model",
        provider: "mock-provider",
        api: "mock-api",
        usage: %{input: 1, output: 1, cache_read: 0, cache_write: 0, total_tokens: 2},
        stop_reason: :stop,
        timestamp: System.system_time(:millisecond)
      }

      chunks =
        if chunk_bytes do
          for offset <- 0..div(byte_size(text) - 1, chunk_bytes) do
            start = offset * chunk_bytes
            size = min(chunk_bytes, byte_size(text) - start)

            snapshot = %{
              message
              | content: [%{type: :text, text: binary_part(text, 0, start + size)}]
            }

            {:text_delta, 0, binary_part(text, start, size), snapshot}
          end
        else
          []
        end

      final = %{message | content: [%{type: :text, text: text}]}
      [{:start, message}] ++ chunks ++ [{:done, :stop, final}]
    end
  end

  for {name, size, chunk_bytes} <- [
        {"repeated snapshots of a small response", 20_000, 100},
        {"streamed content above the former 1 MiB limit", 1_100_000, 50_000},
        {"final-only content above the former 1 MiB limit", 1_100_000, nil}
      ] do
    @tag :tmp_dir
    test "#{name} complete without a default provider output limit", %{tmp_dir: dir} do
      text = String.duplicate("x", unquote(size))

      {:ok, agent} =
        start_supervised(
          {Sigma.Agent,
           execution_engine: :backplane,
           backplane_runtime_path: Path.join(dir, "runtime"),
           model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
           provider: SnapshotProvider,
           options: [text: text, chunk_bytes: unquote(chunk_bytes)]}
        )

      :ok = Sigma.Agent.subscribe(agent)
      assert {:accepted, _} = Sigma.Agent.prompt(agent, "generate output")

      assert_receive {:agent_end, messages}, 5_000
      refute_receive {:turn_error, _}, 0
      assert Sigma.Agent.status(agent).phase == :completed

      assert [
               %Sigma.Agent.Message{role: :user},
               %Sigma.Agent.Message{
                 role: :assistant,
                 content: [%{type: :text, text: ^text}],
                 model: "mock-model",
                 provider: "mock-provider"
               }
             ] = messages
    end
  end

  @tag :tmp_dir
  test "provider output limits emit a non-retryable error with structured budget details", %{
    tmp_dir: dir
  } do
    original =
      Error.new(:resource_conflict, "provider output limit exceeded",
        details: %{scope: :provider_response, size: 1_052_150, limit: 1_048_576}
      )

    agent = start_failing_agent(dir, original)
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "generate output")

    assert_receive {:turn_error,
                    %ProviderError{
                      kind: :output_limit,
                      retryable: false,
                      raw: ^original,
                      message: message
                    }},
                   5_000

    assert message =~ "1052150"
    assert message =~ "1048576"
    assert message =~ "provider_response"
    assert_receive {:agent_end, _}, 5_000
    assert Sigma.Agent.status(agent).phase == :failed
  end

  for {name, original, kind} <- [
        {"other resource conflicts", Error.new(:resource_conflict, "stale stream"),
         :transport_unavailable},
        {"tool output limits",
         Error.new(:resource_conflict, "provider output limit exceeded",
           details: %{scope: :tool_result, size: 100, limit: 50}
         ), :transport_unavailable},
        {"deadlines", Error.new(:timeout, "provider request timed out"), :timeout}
      ] do
    @tag :tmp_dir
    test "#{name} retain their existing classification", %{tmp_dir: dir} do
      agent = start_failing_agent(dir, unquote(Macro.escape(original)))
      assert {:accepted, _} = Sigma.Agent.prompt(agent, "generate output")

      assert_receive {:turn_error, %ProviderError{kind: unquote(kind), retryable: true}},
                     5_000

      assert_receive {:agent_end, _}, 5_000
      assert Sigma.Agent.status(agent).phase == :failed
    end
  end

  defp start_failing_agent(dir, error) do
    {:ok, agent} =
      start_supervised(
        {Sigma.Agent,
         execution_engine: :backplane,
         backplane_runtime_path: Path.join(dir, "runtime"),
         model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
         provider: FailingProvider,
         options: [error: error]}
      )

    :ok = Sigma.Agent.subscribe(agent)
    agent
  end
end
