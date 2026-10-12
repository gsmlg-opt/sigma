defmodule Sigma.Agent.SubscriberLifecycleTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  defmodule PausedProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params) do
      send(params.options[:test_pid], {:provider_paused, self()})

      receive do
        :resume -> :ok
      after
        5_000 -> raise "provider was not resumed"
      end

      message = %{
        role: :assistant,
        content: [%{type: :text, text: "completed"}],
        model: "mock-model",
        provider: "mock-provider",
        api: "mock-api",
        usage: %{input: 1, output: 1, total_tokens: 2, cost: %{total: 0.0}},
        stop_reason: :stop,
        timestamp: System.system_time(:millisecond)
      }

      [{:start, %{message | content: []}}, {:done, :stop, message}]
    end
  end

  for engine <- [:sigma, :backplane] do
    test "#{engine} notifies subscribers who join during an active turn", %{tmp_dir: tmp_dir} do
      agent = start_agent(unquote(engine), tmp_dir)
      assert {:accepted, _} = Sigma.Agent.prompt(agent, "Hi")
      assert_receive {:provider_paused, provider}, 1_000

      :ok = Sigma.Agent.subscribe(agent)
      send(provider, :resume)

      assert_receive {:message_end, %{role: :assistant, content: [%{text: "completed"}]}}, 1_000
      assert_receive {:agent_end, _}, 1_000
    end

    test "#{engine} stops notifying subscribers who leave during an active turn", %{
      tmp_dir: tmp_dir
    } do
      agent = start_agent(unquote(engine), tmp_dir)
      :ok = Sigma.Agent.subscribe(agent)
      assert {:accepted, _} = Sigma.Agent.prompt(agent, "Hi")
      assert_receive {:provider_paused, provider}, 1_000

      :ok = Sigma.Agent.unsubscribe(agent)
      send(provider, :resume)

      assert_receive {:persisted, {:agent_end, _}}, 1_000
      refute_receive {:message_end, %{role: :assistant}}
    end
  end

  defp start_agent(engine, tmp_dir) do
    test_pid = self()

    start_supervised!(
      {Sigma.Agent,
       execution_engine: engine,
       backplane_runtime_path: Path.join(tmp_dir, "runtime"),
       model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
       provider: PausedProvider,
       options: [test_pid: test_pid],
       on_event: fn event ->
         send(test_pid, {:persisted, event})
         :ok
       end}
    )
  end
end
