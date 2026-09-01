defmodule Sigma.Coding.Dispatcher do
  @moduledoc """
  Permission-first tool dispatcher with bounded, metadata-driven scheduling.
  """

  use Supervisor

  alias Sigma.Coding.{Tool, ToolError, ToolExecution, ToolResult, ToolScheduler}

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    task_supervisor = Keyword.get(opts, :task_supervisor, Sigma.Coding.Dispatcher.TaskSupervisor)
    Supervisor.init([{Task.Supervisor, name: task_supervisor}], strategy: :one_for_one)
  end

  def dispatch(tool_call, tools, opts \\ []) do
    case dispatch_batch([tool_call], tools, opts) do
      [{_tool_call, result}] -> result
      [] -> {:error, ToolError.new(:scheduler, :missing_result)}
    end
  end

  def dispatch_batch(tool_calls, tools, opts \\ []) do
    max_parallel =
      case Keyword.get(opts, :mode, :parallel) do
        :sequential -> 1
        :parallel -> Keyword.get(opts, :max_parallel, 4)
      end

    {executions, immediate_results} = prepare_batch(tool_calls, tools, opts)

    scheduled_results =
      ToolScheduler.run(executions, Keyword.put(opts, :max_parallel, max_parallel))

    results = Map.merge(immediate_results, scheduled_results)

    tool_calls
    |> Enum.with_index()
    |> Enum.map(fn {tool_call, index} ->
      {tool_call, Map.get(results, index, {:error, ToolError.new(:scheduler, :missing_result)})}
    end)
  end

  defp prepare_batch(tool_calls, tools, opts) do
    tool_calls
    |> Enum.with_index()
    |> Enum.reduce({[], %{}}, fn {tool_call, index}, {executions, results} ->
      case prepare(tool_call, tools, opts, index) do
        {:ok, execution} -> {[execution | executions], results}
        {:error, error} -> {executions, Map.put(results, index, {:error, error})}
      end
    end)
    |> then(fn {executions, results} -> {Enum.reverse(executions), results} end)
  end

  defp prepare(tool_call, tools, opts, index) do
    case Sigma.Coding.PermissionInterceptor.check(tool_call, opts) do
      :allow ->
        prepare_authorized(tool_call, tools, opts, index)

      {:allow, patched_args} when is_map(patched_args) ->
        patched_call = %{tool_call | arguments: Map.merge(tool_call.arguments, patched_args)}
        prepare_authorized(patched_call, tools, opts, index)

      {:deny, {:approval_required, tool_name}} ->
        {:error,
         ToolError.new(:approval_required, "Approval required for tool: #{tool_name}",
           details: %{tool_name: tool_name}
         )}

      {:deny, reason} ->
        {:error, ToolError.new(:permission_denied, reason)}
    end
  end

  defp prepare_authorized(tool_call, tools, opts, index) do
    case Enum.find(tools, &(Tool.name(&1) == tool_call.name)) do
      nil ->
        {:error, ToolError.new(:not_found, "Tool #{tool_call.name} not found")}

      tool ->
        metadata = Tool.metadata(tool, tool_call, opts)
        deadline_ms = deadline_ms(opts, metadata.default_deadline_ms)
        cancellation_ref = make_ref()
        execution_opts = Keyword.put(opts, :signal, cancellation_ref)

        {:ok,
         %ToolExecution{
           index: index,
           tool_call: tool_call,
           tool: tool,
           metadata: metadata,
           deadline_ms: deadline_ms,
           cancellation_ref: cancellation_ref,
           run: fn -> execute_with_hooks(tool_call, tool, execution_opts) end
         }}
    end
  end

  defp execute_with_hooks(tool_call, tool, opts) do
    session_id = Keyword.get(opts, :session_id)
    log_session_id = Keyword.get(opts, :log_session_id, session_id)
    hook_specs = Keyword.get(opts, :hook_specs, [])
    hook_ctx = build_hook_ctx(opts)
    tool_opts = put_update_callback(opts, tool_call)

    :telemetry.execute(
      [:sigma, :tool, :call, :start],
      %{system_time: System.system_time()},
      %{session_id: session_id, log_session_id: log_session_id, tool_name: tool_call.name}
    )

    started_at = System.monotonic_time()
    normalized = Tool.execute(tool, tool_call.id, tool_call.arguments, tool_opts) |> ToolResult.normalize()

    :telemetry.execute(
      [:sigma, :tool, :call, :stop],
      %{duration: System.monotonic_time() - started_at},
      %{
        session_id: session_id,
        log_session_id: log_session_id,
        tool_name: tool_call.name,
        result: result_class(normalized)
      }
    )

    apply_post_tool_use_hooks(normalized, tool_call, hook_specs, hook_ctx)
  end

  defp put_update_callback(opts, tool_call) do
    case Keyword.get(opts, :on_tool_update) || Keyword.get(opts, :on_update) do
      callback when is_function(callback, 1) ->
        counter = :counters.new(1, [])

        Keyword.put(opts, :on_update, fn raw_update ->
          :counters.add(counter, 1, 1)
          sequence = :counters.get(counter, 1)

          case ToolResult.normalize_update(tool_call.id, sequence, raw_update) do
            {:ok, update} -> safe_update(callback, update)
            {:error, _reason} -> :ok
          end
        end)

      _callback ->
        opts
    end
  end

  defp safe_update(callback, update) do
    callback.(update)
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp apply_post_tool_use_hooks(result, _tool_call, [], _hook_ctx), do: result

  defp apply_post_tool_use_hooks(result, tool_call, hook_specs, hook_ctx) do
    if Sigma.Coding.Hooks.any_for_event?(hook_specs, :post_tool_use) do
      event_data = %{
        tool_name: tool_call.name,
        tool_use_id: tool_call.id,
        tool_input: tool_call.arguments,
        tool_response: result_to_response_string(result)
      }

      {outcome, warnings} =
        Sigma.Coding.Hooks.dispatch(:post_tool_use, hook_specs, hook_ctx, event_data)

      Enum.each(warnings, &surface_warning/1)
      apply_post_outcome(outcome, result)
    else
      result
    end
  end

  defp apply_post_outcome(:proceed, result), do: result

  defp apply_post_outcome({:modify, %{"tool_output" => text}}, _result) when is_binary(text) do
    {:ok, %ToolResult{content: [%{type: :text, text: text}]}}
  end

  defp apply_post_outcome({:block, reason}, _result) do
    {:ok, %ToolResult{content: [%{type: :text, text: to_string(reason)}]}}
  end

  defp apply_post_outcome({:context, feedback}, {:ok, %ToolResult{} = result}) do
    extra = %{type: :text, text: "\n\n[Hook feedback]: #{feedback}"}
    {:ok, %{result | content: result.content ++ [extra]}}
  end

  defp apply_post_outcome({:halt, _reason}, result), do: result
  defp apply_post_outcome(_outcome, result), do: result

  defp result_to_response_string({:ok, %ToolResult{content: content}}) do
    Enum.map_join(content, "\n", fn
      %{type: :text, text: text} -> text
      %{"type" => "text", "text" => text} -> text
      _other -> "[non-text tool content]"
    end)
  end

  defp result_to_response_string({:error, %ToolError{message: message}}), do: "Error: #{message}"

  defp result_class({:ok, _result}), do: :ok
  defp result_class({:error, %ToolError{kind: kind}}), do: kind

  defp deadline_ms(opts, default) do
    case Keyword.get(opts, :deadline_ms, default) do
      :infinity -> :infinity
      value when is_integer(value) and value > 0 -> value
      _invalid -> default
    end
  end

  defp build_hook_ctx(opts) do
    %{
      session_id: Keyword.get(opts, :session_id),
      cwd: Keyword.get(opts, :cwd),
      transcript_path: Keyword.get(opts, :transcript_path, ""),
      permission_mode: Keyword.get(opts, :permission_mode, "default"),
      turn_id: Keyword.get(opts, :turn_id)
    }
  end

  defp surface_warning(message) do
    require Logger
    Logger.warning("[hooks] #{message}")
  end
end
