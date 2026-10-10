defmodule Sigma.Agent.BackplaneContextContinuationTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.Message

  defmodule FailingTool do
    @behaviour Sigma.Coding.Tool

    @impl true
    def name, do: "uncertain_command"
    @impl true
    def description, do: "Simulates an interrupted command without shell effects"
    @impl true
    def schema do
      %{"type" => "object", "properties" => %{"test_pid" => %{"type" => "string"}}}
    end

    @impl true
    def metadata, do: %{effect: :process, concurrency: :exclusive, default_deadline_ms: 5_000}

    @impl true
    def execute(_id, %{"test_pid" => pid}, _opts) do
      send(pid |> String.to_charlist() |> :erlang.list_to_pid(), :command_executed)
      {:error, Sigma.Coding.ToolError.new(:execution, "command timed out")}
    end
  end

  defmodule ContextProvider do
    @behaviour Sigma.Ai.Provider

    @impl true
    def stream(params) do
      send(params.options[:test_pid], {:provider_context, params.context.messages})

      {content, stop_reason} =
        case List.last(params.context.messages) do
          %{role: :user, content: "continue"} ->
            {[%{type: :text, text: "Outcome remains unknown."}], :stop}

          _ ->
            {[
               %{
                 type: :tool_call,
                 id: "interrupted-call",
                 name: "uncertain_command",
                 arguments: %{
                   "test_pid" =>
                     params.options[:test_pid] |> :erlang.pid_to_list() |> List.to_string()
                 }
               }
             ], :tool_use}
        end

      message = %{
        role: :assistant,
        content: content,
        model: "mock-model",
        provider: "mock-provider",
        api: "mock-api",
        usage: %{input: 1, output: 1, cache_read: 0, cache_write: 0, total_tokens: 2},
        stop_reason: stop_reason,
        timestamp: System.system_time(:millisecond)
      }

      [{:start, %{message | content: []}}, {:done, stop_reason, message}]
    end
  end

  @tag :tmp_dir
  test "live continuation completes provider tool pairs without settling or rerunning the failed command",
       %{tmp_dir: dir} do
    {:ok, agent} =
      start_supervised(
        {Sigma.Agent,
         execution_engine: :backplane,
         backplane_runtime_path: Path.join(dir, "runtime"),
         model: %{id: "mock-model", api: "mock-api", provider: "mock-provider"},
         provider: ContextProvider,
         tools: [FailingTool],
         options: [test_pid: self()]}
      )

    :ok = Sigma.Agent.subscribe(agent)
    assert {:accepted, %{turn_id: failed_turn}} = Sigma.Agent.prompt(agent, "run command")
    assert_receive {:provider_context, [%{role: :user}]}, 5_000
    assert_receive :command_executed, 5_000
    assert_receive {:agent_end, first_history}, 5_000
    assert Sigma.Agent.status(agent).phase == :failed
    assert [%Message{role: :user}, %Message{role: :assistant}] = first_history

    store = :sys.get_state(agent).backplane_store
    assert {:ok, failed_record} = Sigma.Agent.Backplane.Store.load(store, failed_turn)
    assert failed_record.run.state == :unknown_outcome

    assert {:accepted, _} = Sigma.Agent.prompt(agent, "continue")

    assert_receive {:provider_context,
                    [
                      %{role: :user},
                      %{role: :assistant, content: [%{id: "interrupted-call"}]},
                      %{
                        role: :tool_result,
                        tool_call_id: "interrupted-call",
                        is_error: true,
                        content: [%{type: :text, text: result_text}]
                      },
                      %{role: :user, content: "continue"}
                    ]},
                   5_000

    assert result_text =~ "execution outcome is unknown"
    assert_receive {:agent_end, final_history}, 5_000
    assert Sigma.Agent.status(agent).phase == :completed
    refute Enum.any?(final_history, &(&1.role == :tool_result))
    refute_receive :command_executed, 0
    assert {:ok, ^failed_record} = Sigma.Agent.Backplane.Store.load(store, failed_turn)
  end
end
