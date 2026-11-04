defmodule Sigma.Agent.BackplaneGoalHookAdmissionFunctionalTest do
  use ExUnit.Case, async: false

  alias Backplane.AgentRuntime.Error
  alias Sigma.Agent.Backplane.{GoalRuns, GoalStore, Store}
  alias Sigma.Agent.Runtime
  alias Sigma.Coding.Hooks.Spec
  alias Sigma.Coding.Hooks.Spec.Command

  @moduletag :tmp_dir
  @moduletag :goal_hook_admission_functional

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    def stream(params) do
      send(params.options[:test_pid], {:goal_hook_provider, self(), params})

      receive do
        :finish_goal_hook ->
          message = %{
            role: :assistant,
            content: [%{type: :text, text: "New Goal work completed"}],
            stop_reason: :stop,
            usage: %{input: 2, output: 1, total_tokens: 3},
            model: "goal-hook",
            provider: "goal-hook",
            api: "openai-responses",
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, :stop, message}]
      end
    end
  end

  test "a stopped automatic prompt preserves its hook effect and permits fresh Goal continuation",
       %{tmp_dir: dir} do
    path = Path.join(dir, "root.jsonl")
    goal_root = path <> ".subagents/goal"
    flag = Path.join(dir, "block-first")
    capture = Path.join(dir, "hook.jsonl")
    script = Path.join(dir, "hook.sh")
    File.write!(flag, "block")

    File.write!(script, """
    cat >> '#{capture}'
    printf '\\n' >> '#{capture}'
    if [ -e '#{flag}' ]; then
      printf '%s' '{"continue":false,"stopReason":"blocked automatic once"}'
    else
      printf '%s' '{}'
    fi
    """)

    spec = %Spec{
      event: :user_prompt_submit,
      matcher: :any,
      dialect: :codex,
      origin: {:project, script},
      trusted?: true,
      handler: %Command{cmd: "sh '#{script}'", timeout_ms: 2_000}
    }

    assert {:ok, handle} =
             Runtime.get_session(dir, "goal-hook",
               cwd: dir,
               transcript_path: path,
               native_tools: true,
               native_memory_root: Path.join(dir, "memories"),
               provider: Provider,
               model: %{id: "goal-hook", provider: "goal-hook", api: "openai-responses"},
               tools: [],
               hook_specs: [spec],
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

    assert {:ok, %{goal: %{thread_id: thread, status: :active}}} =
             Sigma.Agent.set_goal(
               handle.agent,
               %{objective: "Finish the actual requested work"},
               %{text: "Continue this actual Goal"}
             )

    assert_receive {:turn_blocked, "blocked automatic once"}, 8_000
    assert_receive {:agent_end, _}, 8_000
    refute_receive {:goal_hook_provider, _, _}, 0
    [first_hook] = hooks(capture)
    failed_run = first_hook["turn_id"]
    assert is_binary(failed_run)
    assert {:ok, []} = GoalRuns.list(goal_root, thread)
    assert {:ok, store} = Store.open(path: path <> ".runtime")
    assert {:error, %Error{class: :not_found}} = Store.load(store, failed_run)
    assert {:ok, goal_store} = GoalStore.open(path: goal_root)
    assert {:ok, original} = GoalStore.load(goal_store, thread)
    goal_id = original.goal.goal_id

    File.rm!(flag)

    assert {:accepted, %{turn_id: real_run}} =
             Sigma.Agent.prompt(handle.agent, "Continue after the hook condition is resolved")

    assert_receive {:goal_hook_provider, real_provider, %{turn_id: ^real_run}}, 8_000
    send(real_provider, :finish_goal_hook)
    assert_receive {:agent_end, _}, 8_000
    assert {:ok, %{run: %{state: :completed}}} = Store.load(store, real_run)
    assert [^first_hook, %{"turn_id" => ^real_run} | _] = hooks(capture)
    assert {:ok, %{goal: %{thread_id: ^thread, status: :active}}} = Sigma.Agent.goal(handle.agent)

    # A real prompt neither mutates Goal nor substitutes a receipt for the
    # stopped automatic run. Its original hook effect must never be replayed.
    # TODO(upstream): gsmlg-opt/backplane#145 — settle the original effectful
    # pre-Runtime admission before reserving fresh automatic work.
    assert_receive {:goal_hook_provider, automatic_provider, %{turn_id: automatic_run}}, 8_000
    refute automatic_run in [failed_run, real_run]

    assert [^first_hook, %{"turn_id" => ^real_run}, %{"turn_id" => ^automatic_run}] =
             hooks(capture)

    # Complete only after observing fresh automatic work; an explicit mutation
    # before that assertion would conceal the unsettled original reservation.
    assert {:ok, %{goal: %{status: :complete, thread_id: ^thread}}} =
             Sigma.Agent.set_goal(handle.agent, %{status: :complete}, %{
               text: "Finish this fixture Goal after observing fresh continuation"
             })

    send(automatic_provider, :finish_goal_hook)
    assert_receive {:agent_end, _}, 8_000
    assert {:ok, final} = GoalStore.load(goal_store, thread)
    assert final.goal.goal_id == goal_id
    assert {:ok, %{status: :confirmed}} = Sigma.Agent.retire_host(handle.agent)
    refute_receive {:goal_hook_provider, _, _}, 0
  end

  defp hooks(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end
end
