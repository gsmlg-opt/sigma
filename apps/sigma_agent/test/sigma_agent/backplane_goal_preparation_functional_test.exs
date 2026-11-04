defmodule Sigma.Agent.BackplaneGoalPreparationFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Codex.Session
  alias Sigma.Agent.Backplane.{GoalRuns, GoalStore}
  alias Sigma.Agent.{Runtime, Subagents}
  alias Sigma.Session.{Log, Writer}

  @moduletag :tmp_dir
  @moduletag :goal_preparation_functional

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    def stream(params) do
      send(params.options[:test_pid], {:goal_preparation_provider, self(), params})

      receive do
        :finish_goal_preparation ->
          message = %{
            role: :assistant,
            content: [%{type: :text, text: "Preparation recovered"}],
            timestamp: System.system_time(:millisecond),
            usage: %{input: 5, output: 2, total_tokens: 7},
            stop_reason: :stop,
            api: "openai-responses",
            model: "goal-preparation",
            provider: "goal-preparation"
          }

          [{:start, %{message | content: []}}, {:done, :stop, message}]
      end
    end
  end

  test "a Goal run-index I/O failure closes the reserved Session before a subsequent real prompt",
       %{tmp_dir: dir} do
    path = Path.join(dir, "source.jsonl")
    goal_root = Path.join(path <> ".subagents", "goal")

    assert {:ok, handle} =
             Runtime.get_session(dir, "source",
               cwd: dir,
               transcript_path: path,
               native_tools: true,
               native_memory_root: Path.join(dir, "memories"),
               provider: Provider,
               model: %{
                 id: "goal-preparation",
                 provider: "goal-preparation",
                 api: "openai-responses"
               },
               tools: [],
               hook_specs: [],
               permission_config: %{default: :allow, rules: %{}},
               options: [test_pid: self()]
             )

    on_exit(fn ->
      case Runtime.lookup(dir, :supervisor) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, pid)
      end

      assert :ok = GoalStore.retire(goal_root)
    end)

    assert :ok = Sigma.Agent.subscribe(handle.agent)
    writer = Runtime.lookup(dir, "source", :writer)
    host = Runtime.lookup(dir, "source", :subagents)
    assert {:ok, selected} = Writer.selected_journal(writer)
    header = Enum.find(selected.entries, &(&1["type"] == "session"))
    assert header
    thread_id = header["id"]
    index_name = :crypto.hash(:sha256, thread_id) |> Base.url_encode64(padding: false)
    index_path = Path.join(goal_root, index_name <> ".goal-runs")

    # An actual filesystem shape conflict fails GoalRuns.record without
    # changing access permissions or replacing the public Goal/Session hosts.
    File.mkdir!(index_path)

    assert {:accepted, %{turn_id: failed_turn}} =
             Sigma.Agent.prompt(handle.agent, "Fail preparation once")

    assert_receive {:turn_error, error}, 8_000
    assert error.message =~ "goal run index read failed"
    assert error.message =~ "eisdir"
    assert_receive {:agent_end, _}, 8_000
    refute_receive {:goal_preparation_provider, _, _}, 0

    assert {:ok, failed_tree} =
             Subagents.message_board_context(host, "/root", %{
               run_id: failed_turn,
               incarnation: 1
             })

    reserved_session = failed_tree.root_binding.session
    assert is_pid(reserved_session)
    refute Process.alive?(reserved_session)
    assert {:ok, %{status: :confirmed}} = Subagents.close(host)
    assert File.dir?(index_path)

    File.rmdir!(index_path)

    assert {:accepted, %{turn_id: next_turn}} =
             Sigma.Agent.prompt(handle.agent, "Continue after restoring the index")

    refute next_turn == failed_turn
    assert_receive {:goal_preparation_provider, provider, %{turn_id: ^next_turn}}, 8_000

    assert {:ok, ready_tree} =
             Subagents.message_board_context(host, "/root", %{
               run_id: next_turn,
               incarnation: 1
             })

    refute ready_tree.root_binding.session == reserved_session
    assert %{phase: :active} = Session.status(ready_tree.root_binding.session)
    assert {:ok, [%{run_id: ^next_turn}]} = GoalRuns.list(goal_root, thread_id)
    send(provider, :finish_goal_preparation)
    assert_receive {:agent_end, _}, 8_000
    assert Sigma.Agent.status(handle.agent).phase == :completed
    assert {:ok, _} = Writer.flush(writer)
    assert {:ok, snapshot} = Log.snapshot(path)

    assert Enum.any?(snapshot.messages, fn message ->
             message.role == :assistant and
               Enum.any?(message.content, &(&1[:text] == "Preparation recovered"))
           end)

    refute_receive {:turn_error, _}, 0
    refute_receive {:goal_preparation_provider, _, _}, 0
  end
end
