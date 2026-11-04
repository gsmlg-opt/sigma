# Run in an independent VM with deployed ebin paths, never in the test VM.
defmodule Sigma.LifetimeRecoveryProbe do
  alias Sigma.Agent.{Runtime, Subagents}
  alias Sigma.Agent.Backplane.{GoalCoordinator, GoalStore}

  defmodule Provider do
    @behaviour Sigma.Ai.Provider

    def output_token_limit(_model, _options), do: 2_000

    def stream(params) do
      File.write!(
        params.options[:request_log],
        Jason.encode!(Map.take(params, [:session_id, :turn_id])) <> "\n",
        [:append]
      )

      message = %{
        role: :assistant,
        content: [%{type: :text, text: "Fresh root work completed"}],
        stop_reason: :stop,
        usage: %{input: 15, cache_read: 5, output: 3, total_tokens: 18},
        model: "goal-recovery",
        provider: "goal-recovery",
        api: "openai-responses",
        timestamp: System.system_time(:millisecond)
      }

      [{:start, %{message | content: []}}, {:done, :stop, message}]
    end
  end

  def run([dir, path, expected, original_run]) do
    expected = String.to_integer(expected)
    log = Path.join(dir, "cold-provider.jsonl")
    goal_root = Path.join(path <> ".subagents", "goal")

    options = [
      cwd: dir,
      transcript_path: path,
      native_tools: true,
      native_memory_root: Path.join(dir, "memories"),
      provider: Provider,
      model: %{
        id: "goal-recovery",
        provider: "goal-recovery",
        api: "openai-responses",
        context_window: 200_000
      },
      tools: [],
      hook_specs: [],
      permission_config: %{default: :allow, rules: %{}},
      options: [request_log: log]
    ]

    {:ok, _} = Application.ensure_all_started(:sigma_agent)

    # The first reopen acknowledges the retained child receipt. A second cold
    # owner must only read it, preserving every already reconciled byte.
    for _ <- 1..2 do
      {:ok, handle} = Runtime.get_session(dir, "lifetime-recovery", options)
      {:ok, %{goal: %{tokens_used: ^expected}}} = Sigma.Agent.goal(handle.agent)
      {:ok, %{coordinator: coordinator}} = GenServer.call(handle.agent, :goal_handle)
      {:ok, %{status: :ready, recovered_runs: 0}} = GoalCoordinator.recover(coordinator)
      false = File.exists?(log)
      stop_repository(dir)
      :ok = GoalStore.retire(goal_root)

      inventory = bytes(path)

      case Process.get(:reconciled_inventory) do
        nil -> Process.put(:reconciled_inventory, inventory)
        ^inventory -> :ok
        _ -> raise "reopening rewrote previously reconciled records"
      end
    end

    {:ok, handle} = Runtime.get_session(dir, "lifetime-recovery", options)
    {:accepted, _} = Sigma.Agent.prompt(handle.agent, "New work after cold recovery")
    await(fn -> Sigma.Agent.status(handle.agent).phase == :completed end)

    [%{"turn_id" => next_run}] =
      log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    true = next_run != original_run
    # Join the ordinary Goal idle calculation before closing the owned tree.
    await(fn -> is_nil(:sys.get_state(handle.agent).goal_idle_task) end)

    {:ok, %{status: :confirmed}} =
      Subagents.close(Runtime.lookup(dir, "lifetime-recovery", :subagents))

    {:ok, %{status: :confirmed}} = Sigma.Agent.retire_host(handle.agent)
    stop_repository(dir)
    :ok = GoalStore.retire(goal_root)
    IO.puts("cold lifetime recovery confirmed")
  end

  defp bytes(path) do
    [
      path <> ".runtime/*.runtime",
      path <> ".subagents/*/runtime/*.runtime",
      path <> ".subagents/lifetime-recovery.etf"
    ]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Map.new(&{&1, File.read!(&1)})
  end

  defp stop_repository(dir) do
    :ok =
      DynamicSupervisor.terminate_child(
        Sigma.Agent.DynamicSupervisor,
        Runtime.lookup(dir, :supervisor)
      )
  end

  defp await(fun, attempts \\ 500)
  defp await(_fun, 0), do: raise("cold recovery did not reach its functional boundary")

  defp await(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          await(fun, attempts - 1)
        )
  end
end

Sigma.LifetimeRecoveryProbe.run(System.argv())
