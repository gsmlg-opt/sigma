defmodule Sigma.Coding.PermissionInterceptor do
  @moduledoc """
  Interprets permission rules before tool execution.
  """

  alias Sigma.Coding.PermissionPolicy

  @doc """
  Checks if a tool call is allowed based on the provided options.

  Returns `:allow`, `{:allow, patched_args}`, or `{:deny, reason}`.

  When hook specs are present in `opts` (`:hook_specs`), PreToolUse hooks run
  after the policy grants `:allow`, and PermissionRequest hooks intercept the
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
    policy = Keyword.get(opts, :permission_policy)

    cond do
      policy && (is_pid(policy) || (is_atom(policy) && Process.whereis(policy))) ->
        case PermissionPolicy.check(policy, tool_call.name) do
          :allow ->
            run_pre_tool_use_hooks(tool_call, opts)

          :deny ->
            {:deny, "Permission denied by policy for tool: #{tool_call.name}"}

          :ask ->
            resolve_ask(tool_call, opts)
        end

      Keyword.has_key?(opts, :allow_tool) ->
        allowed = Keyword.get(opts, :allow_tool)

        if tool_call.name == allowed or (is_list(allowed) and tool_call.name in allowed) do
          run_pre_tool_use_hooks(tool_call, opts)
        else
          {:deny, "Permission denied for tool: #{tool_call.name}"}
        end

      true ->
        run_pre_tool_use_hooks(tool_call, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # PreToolUse hooks (after policy :allow)
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

      collapse_pre_tool_use(outcome, tool_call, opts)
    else
      :allow
    end
  end

  defp collapse_pre_tool_use(:proceed, _tool_call, _opts), do: :allow

  defp collapse_pre_tool_use({:modify, patch}, _tool_call, _opts) when is_map(patch) do
    {:allow, patch}
  end

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

    run_pre_tool_use_after_approval(resolution, tool_call, opts)
  end

  defp run_pre_tool_use_after_approval(:allow, tool_call, opts) do
    run_pre_tool_use_hooks(tool_call, opts)
  end

  defp run_pre_tool_use_after_approval({:allow, approval_patch}, tool_call, opts)
       when is_map(approval_patch) do
    patched_call = %{tool_call | arguments: Map.merge(tool_call.arguments, approval_patch)}

    case run_pre_tool_use_hooks(patched_call, opts) do
      :allow -> {:allow, approval_patch}
      {:allow, hook_patch} -> {:allow, Map.merge(approval_patch, hook_patch)}
      {:deny, _reason} = denied -> denied
    end
  end

  defp run_pre_tool_use_after_approval({:deny, _reason} = denied, _tool_call, _opts),
    do: denied

  defp run_pre_tool_use_after_approval(_other, tool_call, _opts),
    do: {:deny, {:invalid_approval_response, tool_call.name}}

  defp result_class(:allow), do: :allow
  defp result_class({:allow, _patch}), do: :allow
  defp result_class({:deny, {:approval_required, _tool_name}}), do: :approval_required
  defp result_class({:deny, _reason}), do: :deny

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
    require Logger
    Logger.warning("[hooks] #{msg}")
  end
end
