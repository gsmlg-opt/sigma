defmodule PiCoding.Dispatcher do
  @moduledoc """
  Handles dispatching tool calls to the appropriate tool modules.
  Uses a Task.Supervisor for concurrent execution.
  """

  use Supervisor

  @doc """
  Starts the dispatcher with its Task.Supervisor.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    task_supervisor = Keyword.get(opts, :task_supervisor, PiCoding.Dispatcher.TaskSupervisor)

    children = [
      {Task.Supervisor, name: task_supervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Dispatches a single tool call and waits for the result.
  """
  def dispatch(tool_call, tools, opts \\ []) do
    case do_dispatch(tool_call, tools, opts) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Dispatches a batch of tool calls.
  By default, executes them in parallel using Task.yield_many.
  """
  def dispatch_batch(tool_calls, tools, opts \\ []) do
    mode = Keyword.get(opts, :mode, :parallel)
    task_supervisor = Keyword.get(opts, :task_supervisor, PiCoding.Dispatcher.TaskSupervisor)

    case mode do
      :sequential ->
        Enum.map(tool_calls, fn tool_call ->
          {tool_call, do_dispatch(tool_call, tools, opts)}
        end)

      :parallel ->
        tasks =
          Enum.map(tool_calls, fn tool_call ->
            Task.Supervisor.async(task_supervisor, fn ->
              do_dispatch(tool_call, tools, opts)
            end)
          end)

        tasks
        |> Task.yield_many(:infinity)
        |> Enum.zip(tool_calls)
        |> Enum.map(fn {{_task, res}, tool_call} ->
          case res do
            {:ok, result} ->
              {tool_call, result}

            {:exit, reason} ->
              {tool_call, {:error, "Tool execution crashed: #{inspect(reason)}"}}

            nil ->
              # This shouldn't happen with :infinity, but for completeness:
              {tool_call, {:error, "Tool execution timed out"}}
          end
        end)
    end
  end

  defp do_dispatch(tool_call, tools, opts) do
    session_id = Keyword.get(opts, :session_id)

    case PiCoding.PermissionInterceptor.check(tool_call, opts) do
      :allow ->
        tool = Enum.find(tools, fn t -> t.name() == tool_call.name end)

        if tool do
          :telemetry.execute(
            [:ex_pi, :tool, :call, :start],
            %{system_time: System.system_time()},
            %{session_id: session_id, tool_name: tool_call.name, arguments: tool_call.arguments}
          )

          start = System.monotonic_time()

          result =
            try do
              tool.execute(tool_call.id, tool_call.arguments, opts)
            rescue
              e -> {:error, Exception.message(e)}
            catch
              kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
            end

          :telemetry.execute(
            [:ex_pi, :tool, :call, :stop],
            %{duration: System.monotonic_time() - start},
            %{session_id: session_id, tool_name: tool_call.name, result: inspect(result)}
          )

          result
        else
          {:error, "Tool #{tool_call.name} not found"}
        end

      {:deny, reason} ->
        {:error, reason}
    end
  end
end
