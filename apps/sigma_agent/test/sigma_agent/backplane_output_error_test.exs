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
