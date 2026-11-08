defmodule Sigma.Agent.TurnFailureReasonTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  defmodule FailingProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(_params) do
      raise Sigma.Ai.ProviderError,
        kind: :invalid_request,
        message: "turn failure reason regression",
        retryable: false
    end
  end

  test "a failed turn persists the reported error in turn_finished", %{tmp_dir: tmp_dir} do
    test_pid = self()

    {:ok, agent} =
      Sigma.Agent.start_link(
        model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
        provider: FailingProvider,
        backplane_runtime_path: Path.join(tmp_dir, "runtime"),
        on_event: fn event ->
          send(test_pid, {:persisted, event})
          :ok
        end
      )

    :ok = Sigma.Agent.subscribe(agent)
    {:accepted, %{turn_id: turn_id}} = Sigma.Agent.prompt(agent, "fail please")

    assert_receive {:turn_error, _reported}, 5_000
    assert_receive {:turn_failed, ^turn_id}, 5_000

    assert_receive {:persisted,
                    {:metrics, :turn_finished, %{turn_id: ^turn_id, status: :failed} = attrs}},
                   5_000

    assert is_binary(attrs.reason)
    assert attrs.reason =~ "turn failure reason regression"
  end
end
