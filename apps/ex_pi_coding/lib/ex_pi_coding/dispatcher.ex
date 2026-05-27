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
              {tool_call, {:error, "Tool execution timed out"}}
          end
        end)
    end
  end

  defp do_dispatch(tool_call, tools, opts) do
    session_id = Keyword.get(opts, :session_id)
    hook_specs = Keyword.get(opts, :hook_specs, [])
    hook_ctx = build_hook_ctx(opts)

    case PiCoding.PermissionInterceptor.check(tool_call, opts) do
      :allow ->
        execute_with_hooks(tool_call, tools, opts, hook_specs, hook_ctx, session_id)

      {:allow, patched_args} when is_map(patched_args) ->
        patched_call = %{tool_call | arguments: Map.merge(tool_call.arguments, patched_args)}
        execute_with_hooks(patched_call, tools, opts, hook_specs, hook_ctx, session_id)

      {:deny, reason} ->
        {:error, reason}
    end
  end

  defp execute_with_hooks(tool_call, tools, opts, hook_specs, hook_ctx, session_id) do
    tool = Enum.find(tools, fn t -> PiCoding.Tool.name(t) == tool_call.name end)

    if tool do
      :telemetry.execute(
        [:ex_pi, :tool, :call, :start],
        %{system_time: System.system_time()},
        %{session_id: session_id, tool_name: tool_call.name, arguments: tool_call.arguments}
      )

      start = System.monotonic_time()

      result =
        try do
          PiCoding.Tool.execute(tool, tool_call.id, tool_call.arguments, opts)
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

      apply_post_tool_use_hooks(result, tool_call, hook_specs, hook_ctx)
    else
      {:error, "Tool #{tool_call.name} not found"}
    end
  end

  defp apply_post_tool_use_hooks(result, _tool_call, [], _hook_ctx), do: result

  defp apply_post_tool_use_hooks(result, tool_call, hook_specs, hook_ctx) do
    if PiCoding.Hooks.any_for_event?(hook_specs, :post_tool_use) do
      tool_response = result_to_response_string(result)

      event_data = %{
        tool_name: tool_call.name,
        tool_use_id: tool_call.id,
        tool_input: tool_call.arguments,
        tool_response: tool_response
      }

      {outcome, warnings} =
        PiCoding.Hooks.dispatch(:post_tool_use, hook_specs, hook_ctx, event_data)

      Enum.each(warnings, &surface_warning/1)

      apply_post_outcome(outcome, result)
    else
      result
    end
  end

  defp apply_post_outcome(:proceed, result), do: result

  defp apply_post_outcome({:modify, %{"tool_output" => text}}, _result) do
    {:ok, %{content: [%{type: :text, text: text}], is_error: false}}
  end

  defp apply_post_outcome({:block, reason}, _result) do
    # Codex block: substitute result with feedback
    {:ok, %{content: [%{type: :text, text: reason}], is_error: false}}
  end

  defp apply_post_outcome({:context, feedback}, result) do
    # Claude block: append feedback alongside original
    case result do
      {:ok, %{content: content} = r} when is_list(content) ->
        extra = %{type: :text, text: "\n\n[Hook feedback]: #{feedback}"}
        {:ok, %{r | content: content ++ [extra]}}

      other ->
        other
    end
  end

  defp apply_post_outcome({:halt, _reason}, result), do: result
  defp apply_post_outcome(_, result), do: result

  defp result_to_response_string({:ok, %{content: content}}) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{type: :text, text: t} -> t
      other -> inspect(other)
    end)
  end

  defp result_to_response_string({:ok, %{content: text}}) when is_binary(text), do: text
  defp result_to_response_string({:error, reason}), do: "Error: #{inspect(reason)}"
  defp result_to_response_string(other), do: inspect(other)

  defp build_hook_ctx(opts) do
    %{
      session_id: Keyword.get(opts, :session_id),
      cwd: Keyword.get(opts, :cwd),
      transcript_path: Keyword.get(opts, :transcript_path, ""),
      permission_mode: Keyword.get(opts, :permission_mode, "default"),
      turn_id: Keyword.get(opts, :turn_id)
    }
  end

  defp surface_warning(msg) do
    # Non-blocking: log warnings; callers can subscribe via telemetry
    require Logger
    Logger.warning("[hooks] #{msg}")
  end
end
