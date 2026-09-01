defmodule Sigma.Coding.ToolScheduler do
  @moduledoc """
  Bounded, deadline-aware scheduler for an already-authorized tool batch.
  """

  alias Sigma.Coding.{ToolError, ToolResult}

  def run(executions, opts) do
    max_parallel = max(Keyword.get(opts, :max_parallel, 4), 1)

    state = %{
      queue: executions,
      running: %{},
      results: %{},
      max_parallel: max_parallel,
      task_supervisor:
        Keyword.get(opts, :task_supervisor, Sigma.Coding.Dispatcher.TaskSupervisor),
      signal: Keyword.get(opts, :signal),
      shutdown_budget_ms: Keyword.get(opts, :shutdown_budget_ms, 250)
    }

    state
    |> schedule_ready()
    |> await()
    |> Map.fetch!(:results)
  end

  defp await(%{queue: [], running: running} = state) when map_size(running) == 0, do: state

  defp await(state) do
    timeout = next_timeout(state.running)

    receive do
      {ref, raw_result} when is_reference(ref) and is_map_key(state.running, ref) ->
        state
        |> complete_result(ref, ToolResult.normalize(raw_result))
        |> schedule_ready()
        |> await()

      {:DOWN, ref, :process, _pid, reason}
      when is_reference(ref) and is_map_key(state.running, ref) ->
        state
        |> complete_result(ref, {:error, ToolError.new(:crash, crash_reason(reason))})
        |> schedule_ready()
        |> await()

      {:abort, signal} when signal == state.signal and not is_nil(signal) ->
        cancel_all(state)

      {:DOWN, _ref, :process, signal_pid, _reason}
      when is_pid(state.signal) and signal_pid == state.signal ->
        cancel_all(state)
    after
      timeout ->
        state
        |> expire_due()
        |> schedule_ready()
        |> await()
    end
  end

  defp schedule_ready(state) when map_size(state.running) >= state.max_parallel, do: state
  defp schedule_ready(%{queue: []} = state), do: state

  defp schedule_ready(state) do
    case next_runnable_index(state.queue, state.running) do
      nil ->
        state

      index ->
        {execution, queue} = List.pop_at(state.queue, index)
        task = Task.Supervisor.async_nolink(state.task_supervisor, execution.run)

        running_item = %{
          task: task,
          execution: execution,
          deadline_at: deadline_at(execution.deadline_ms)
        }

        state = %{state | queue: queue, running: Map.put(state.running, task.ref, running_item)}
        schedule_ready(state)
    end
  end

  defp next_runnable_index(queue, running) do
    Enum.find_index(queue, &runnable?(&1, running))
  end

  defp runnable?(execution, running) when map_size(running) == 0,
    do: not is_nil(execution) and Sigma.Coding.PendingToolRegistry.compatible?(execution.metadata)

  defp runnable?(execution, running) do
    running_executions = Enum.map(running, fn {_ref, item} -> item.execution end)

    Sigma.Coding.PendingToolRegistry.compatible?(execution.metadata) and
      execution.metadata.concurrency != :exclusive and
      Enum.all?(running_executions, &compatible?(execution, &1))
  end

  defp compatible?(_candidate, %{metadata: %{concurrency: :exclusive}}), do: false
  defp compatible?(%{metadata: %{concurrency: :sequential}}, _running), do: false
  defp compatible?(_candidate, %{metadata: %{concurrency: :sequential}}), do: false

  defp compatible?(candidate, running) do
    overlap? =
      not MapSet.disjoint?(
        MapSet.new(candidate.metadata.resource_keys),
        MapSet.new(running.metadata.resource_keys)
      )

    cond do
      not overlap? and candidate.metadata.resource_keys != [] -> true
      not overlap? and running.metadata.resource_keys != [] -> true
      not overlap? ->
        candidate.metadata.concurrency == :shared or running.metadata.concurrency == :shared

      true ->
        candidate.metadata.concurrency == :shared and running.metadata.concurrency == :shared
    end
  end

  defp complete_result(state, ref, result) do
    %{task: task, execution: execution} = Map.fetch!(state.running, ref)
    Process.demonitor(task.ref, [:flush])

    %{
      state
      | running: Map.delete(state.running, ref),
        results: Map.put(state.results, execution.index, result)
    }
  end

  defp expire_due(state) do
    now = System.monotonic_time(:millisecond)

    Enum.reduce(state.running, state, fn {ref, item}, acc ->
      if item.deadline_at != :infinity and item.deadline_at <= now do
        result =
          case shutdown(item, acc.shutdown_budget_ms) do
            {:completed, completed_result} -> completed_result
            :pending -> {:error, ToolError.new(:indeterminate, :non_interruptible_cleanup_pending)}
            :terminated -> {:error, ToolError.new(:timeout, :deadline_exceeded, retryable: true)}
          end

        complete_result(acc, ref, result)
      else
        acc
      end
    end)
  end

  defp cancel_all(state) do
    state =
      Enum.reduce(state.running, state, fn {ref, item}, acc ->
        result =
          case shutdown(item, acc.shutdown_budget_ms) do
            {:completed, completed_result} -> completed_result
            :pending -> {:error, ToolError.new(:indeterminate, :non_interruptible_cleanup_pending)}
            :terminated -> {:error, ToolError.new(:cancelled, :cancelled)}
          end

        complete_result(acc, ref, result)
      end)

    results =
      Enum.reduce(state.queue, state.results, fn execution, acc ->
        Map.put(acc, execution.index, {:error, ToolError.new(:cancelled, :cancelled)})
      end)

    %{state | queue: [], results: results}
  end

  defp shutdown(%{task: task, execution: execution}, shutdown_budget_ms) do
    if execution.metadata.interruptible do
      send(task.pid, {:abort, execution.cancellation_ref})

      case Task.yield(task, shutdown_budget_ms) do
        nil -> Task.shutdown(task, 0)
        _result -> :ok
      end

      :terminated
    else
      case Task.yield(task, shutdown_budget_ms) do
        nil ->
          :ok = Sigma.Coding.PendingToolRegistry.track(task.pid, execution.metadata)

          :telemetry.execute(
            [:sigma, :tool, :cleanup, :pending],
            %{count: 1},
            %{tool_name: execution.tool_call.name}
          )

          :pending

        {:ok, raw_result} ->
          {:completed, ToolResult.normalize(raw_result)}

        {:exit, reason} ->
          {:completed, {:error, ToolError.new(:crash, crash_reason(reason))}}
      end
    end
  end

  defp deadline_at(:infinity), do: :infinity
  defp deadline_at(milliseconds), do: System.monotonic_time(:millisecond) + milliseconds

  defp next_timeout(running) when map_size(running) == 0, do: 10

  defp next_timeout(running) do
    now = System.monotonic_time(:millisecond)

    running
    |> Enum.map(fn {_ref, item} -> item.deadline_at end)
    |> Enum.reject(&(&1 == :infinity))
    |> case do
      [] -> 60_000
      deadlines -> max(Enum.min(deadlines) - now, 0)
    end
  end

  defp crash_reason({%{__exception__: true} = exception, _stacktrace}),
    do: Exception.message(exception)

  defp crash_reason(reason), do: reason
end
