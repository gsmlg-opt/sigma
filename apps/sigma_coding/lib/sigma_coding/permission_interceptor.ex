defmodule Sigma.Coding.PermissionInterceptor do
  @moduledoc """
  Interprets permission rules before tool execution.
  """

  alias Sigma.Coding.PermissionPolicy
  alias Sigma.Coding.Hooks.Outcome

  @doc """
  Checks if a tool call is allowed based on the provided options.

  Returns `:allow`, `{:allow, patched_args}`, `{:allow, patched_args, context}`,
  or `{:deny, reason}`.

  When hook specs are present in `opts` (`:hook_specs`), PreToolUse hooks run
  before permission evaluation, and PermissionRequest hooks intercept the
  `:ask` branch before showing the approval UI.
  """
  def check(tool_call, opts) do
    session_id = Keyword.get(opts, :session_id)
    log_session_id = Keyword.get(opts, :log_session_id, session_id)

    :telemetry.execute(
      [:sigma, :permission, :check, :start],
      %{system_time: System.system_time()},
      %{session_id: session_id, log_session_id: log_session_id, tool_name: tool_call.name}
    )

    result = do_check(tool_call, opts)

    :telemetry.execute(
      [:sigma, :permission, :check, :stop],
      %{},
      %{
        session_id: session_id,
        log_session_id: log_session_id,
        tool_name: tool_call.name,
        result: result_class(result)
      }
    )

    result
  end

  defp do_check(tool_call, opts) do
    case run_pre_tool_use_hooks(tool_call, opts) do
      {:deny, _} = denied ->
        denied

      :allow ->
        check_policy(tool_call, opts)

      {:allow, {:replace_input, input}} ->
        check_replaced_policy(tool_call, input, nil, opts)

      {:allow, {:replace_input, input}, context} ->
        check_replaced_policy(tool_call, input, context, opts)

      {:allow, patch} ->
        check_patched_policy(tool_call, patch, nil, opts)

      {:allow, patch, context} ->
        check_patched_policy(tool_call, patch, context, opts)
    end
  end

  defp check_replaced_policy(tool_call, input, context, opts) do
    case check_policy(%{tool_call | arguments: input}, opts) do
      :allow ->
        with_context({:allow, {:replace_input, input}}, context)

      {:allow, approval_patch} ->
        with_context({:allow, {:replace_input, Map.merge(input, approval_patch)}}, context)

      denied ->
        denied
    end
  end

  defp check_patched_policy(tool_call, patch, context, opts) do
    tool_call = %{tool_call | arguments: Map.merge(tool_call.arguments, patch)}

    case check_policy(tool_call, opts) do
      :allow ->
        with_context({:allow, patch}, context)

      {:allow, approval_patch} ->
        with_context({:allow, Map.merge(patch, approval_patch)}, context)

      denied ->
        denied
    end
  end

  defp check_policy(tool_call, opts) do
    policy = Keyword.get(opts, :permission_policy)

    cond do
      policy && (is_pid(policy) || (is_atom(policy) && Process.whereis(policy))) ->
        case PermissionPolicy.check(policy, tool_call.name) do
          :allow ->
            :allow

          :deny ->
            {:deny, "Permission denied by policy for tool: #{tool_call.name}"}

          :ask ->
            resolve_ask(tool_call, opts)
        end

      Keyword.has_key?(opts, :allow_tool) ->
        allowed = Keyword.get(opts, :allow_tool)

        if tool_call.name == allowed or (is_list(allowed) and tool_call.name in allowed) do
          :allow
        else
          {:deny, "Permission denied for tool: #{tool_call.name}"}
        end

      true ->
        :allow
    end
  end

  # ---------------------------------------------------------------------------
  # PreToolUse hooks (before permission evaluation)
  # ---------------------------------------------------------------------------

  defp run_pre_tool_use_hooks(tool_call, opts) do
    hook_specs = Keyword.get(opts, :hook_specs, [])

    if Sigma.Coding.Hooks.any_for_event?(hook_specs, :pre_tool_use) do
      hook_ctx = build_hook_ctx(opts)

      event_data = %{
        tool_name: tool_call.name,
        tool_use_id: tool_call.id,
        tool_input: tool_call.arguments
      }

      {outcome, warnings} =
        Sigma.Coding.Hooks.dispatch(:pre_tool_use, hook_specs, hook_ctx, event_data)

      Enum.each(warnings, &surface_warning/1)

      outcome
      |> Outcome.control()
      |> collapse_pre_tool_use(tool_call, opts)
      |> with_context(Outcome.context(outcome))
    else
      :allow
    end
  end

  defp collapse_pre_tool_use(:proceed, _tool_call, _opts), do: :allow

  defp collapse_pre_tool_use({:modify, patch}, _tool_call, _opts) when is_map(patch) do
    {:allow, patch}
  end

  defp collapse_pre_tool_use({:replace_input, input}, _tool_call, _opts) when is_map(input),
    do: {:allow, {:replace_input, input}}

  defp collapse_pre_tool_use({:block, reason}, _tool_call, _opts) do
    {:deny, reason}
  end

  defp collapse_pre_tool_use({:halt, reason}, _tool_call, _opts) do
    {:deny, reason || "Hook halted execution"}
  end

  defp collapse_pre_tool_use({:ask, reason}, tool_call, opts) do
    invoke_request_fn(tool_call, opts, reason)
  end

  defp collapse_pre_tool_use({:defer, reason}, tool_call, opts) do
    # defer is headless-only; degrade to :ask in interactive mode
    invoke_request_fn(tool_call, opts, reason)
  end

  defp collapse_pre_tool_use(_, _tool_call, _opts), do: :allow

  # ---------------------------------------------------------------------------
  # PermissionRequest hooks (at the :ask branch, before approval UI)
  # ---------------------------------------------------------------------------

  defp run_permission_request_hooks(tool_call, opts) do
    hook_specs = Keyword.get(opts, :hook_specs, [])

    if Sigma.Coding.Hooks.any_for_event?(hook_specs, :permission_request) do
      hook_ctx = build_hook_ctx(opts)

      event_data = %{
        tool_name: tool_call.name,
        tool_use_id: tool_call.id,
        tool_input: tool_call.arguments
      }

      {outcome, warnings} =
        Sigma.Coding.Hooks.dispatch(:permission_request, hook_specs, hook_ctx, event_data)

      Enum.each(warnings, &surface_warning/1)

      case outcome do
        :allow -> :allow
        :proceed -> :proceed
        {:modify, patch} -> {:allow, patch}
        {:block, reason} -> {:deny, reason}
        {:halt, reason} -> {:deny, reason || "Hook halted execution"}
        _ -> :proceed
      end
    else
      :proceed
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp invoke_request_fn(tool_call, opts, _hint \\ nil) do
    request_fn = Keyword.get(opts, :permission_request_fn)

    if request_fn do
      request_fn.(tool_call)
    else
      {:deny, {:approval_required, tool_call.name}}
    end
  end

  defp resolve_ask(tool_call, opts) do
    resolution =
      case run_permission_request_hooks(tool_call, opts) do
        :proceed -> invoke_request_fn(tool_call, opts)
        other -> other
      end

    case resolution do
      :allow -> :allow
      {:allow, patch} when is_map(patch) -> resolution
      {:deny, _} -> resolution
      _ -> {:deny, {:invalid_approval_response, tool_call.name}}
    end
  end

  defp with_context(:allow, text) when is_binary(text) and text != "",
    do: {:allow, %{}, text}

  defp with_context({:allow, patch}, text) when is_binary(text) and text != "",
    do: {:allow, patch, text}

  defp with_context(result, _context), do: result

  defp result_class(:allow), do: :allow
  defp result_class({:allow, _patch}), do: :allow
  defp result_class({:allow, _patch, _context}), do: :allow
  defp result_class({:deny, {:approval_required, _tool_name}}), do: :approval_required
  defp result_class({:deny, _reason}), do: :deny

  defp build_hook_ctx(opts) do
    %{
      session_id: Keyword.get(opts, :session_id),
      cwd: Keyword.get(opts, :cwd),
      transcript_path: Keyword.get(opts, :transcript_path, ""),
      permission_mode: Keyword.get(opts, :permission_mode, "default"),
      turn_id: Keyword.get(opts, :turn_id),
      model: Keyword.get(opts, :model, ""),
      agent_id: Keyword.get(opts, :agent_id),
      agent_type: Keyword.get(opts, :agent_type),
      hook_task_supervisor:
        Keyword.get(opts, :hook_task_supervisor, Sigma.Coding.Dispatcher.TaskSupervisor),
      mcp_hook_executor: Keyword.get(opts, :mcp_hook_executor),
      hook_async_callback: Keyword.get(opts, :hook_async_callback),
      hook_async_runtime: Keyword.get(opts, :hook_async_runtime)
    }
  end

  defp surface_warning(msg) do
    require Logger
    Logger.warning("[hooks] #{msg}")
  end
end
