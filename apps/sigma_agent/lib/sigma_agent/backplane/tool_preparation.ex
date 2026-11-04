defmodule Sigma.Agent.Backplane.ToolPreparation do
  @moduledoc """
  Permission preparation for explicitly selected native Codex profiles.

  Install this module as the public Runtime Conversation `:hooks` adapter and
  supply `:permission_options` in its trusted provider context. Preparation
  never dispatches a tool: Runtime retains schema, authority, approval and
  invocation-commit ownership after this callback returns.

  Function patches merge with the original input; full replacements do not.
  Custom input remains an exact binary. The existing permission interceptor
  supports map edits only, so custom input edits are rejected rather than
  converted to an object or string. Codex hook JSON keeps its map-only contract.

  Additional context uses Runtime's trusted `append_feedback/1` callback. The
  checkpoint receipt is durable only with a durable Store. Runtime correlates
  feedback to the immutable attempt, fences stale callbacks and projects it once
  at the next provider boundary; acceptance does not attest to final input or
  dispatch. Context is never inserted into tool input.

  An explicit `on_hook_context.(final_invocation, text)` remains a compatibility
  observer after Runtime acceptance, or a sink when no Runtime callback exists.
  It must return `:ok` or `{:error, RuntimeError}`. Observer refusal prevents tool
  dispatch but cannot roll back already accepted feedback. This module does not
  register production tools or implement post-tool execution hooks.

  `permission_interaction: true` explicitly routes approval through Runtime's
  trusted `interact/1` callback. Its serializable `:sigma_tool_permission` request
  is handled by `PermissionResponder` using the host's existing resolver. Runtime
  suspends execution deadlines while waiting. Its separate built-in `:permission`
  approval and authority checks remain Runtime-owned.
  """

  alias Backplane.AgentRuntime.Error
  alias Sigma.Agent.Backplane.HookContext
  alias Sigma.Coding.PermissionInterceptor

  @spec prepare_tool(map(), map()) ::
          :allow | {:allow, map() | binary()} | {:deny, term()} | {:error, Error.t()}
  def prepare_tool(
        %{tool_call_id: id, tool_name: name, arguments: input} = invocation,
        %{permission_options: opts, input_kind: kind} = context
      )
      when is_list(opts) and kind in [:function, :custom] do
    with :ok <- validate_input(kind, input),
         {:ok, opts} <- permission_options(context, opts),
         result <- PermissionInterceptor.check(%{id: id, name: name, arguments: input}, opts),
         {:ok, final, feedback} <- normalize(result, kind, input),
         :ok <- deliver_context(context, %{invocation | arguments: final}, feedback) do
      if final === input, do: :allow, else: {:allow, final}
    end
  rescue
    _exception ->
      {:error, Error.new(:execution_failure, "tool permission preparation failed")}
  end

  def prepare_tool(_invocation, _context),
    do:
      {:error,
       Error.new(:validation, "tool preparation requires invocation and permission context")}

  defp validate_input(:function, input) when is_map(input), do: :ok
  defp validate_input(:custom, input) when is_binary(input), do: :ok

  defp validate_input(_kind, _input),
    do: {:error, Error.new(:validation, "tool input does not match its pinned input kind")}

  defp permission_options(%{permission_interaction: true, interact: interact}, opts)
       when is_function(interact, 1) do
    request = fn call ->
      payload = %{
        kind: :sigma_tool_permission,
        tool_call: Map.take(call, [:id, :name, :arguments])
      }

      with {:ok, _encoded} <- Jason.encode(payload),
           {:ok, answer} <- interact.(payload) do
        answer
      else
        _ -> {:deny, :permission_interaction_failed}
      end
    end

    {:ok, Keyword.put(opts, :permission_request_fn, request)}
  end

  defp permission_options(%{permission_interaction: true}, _opts),
    do:
      {:error,
       Error.new(:validation, "permission interaction requires Runtime interact callback")}

  defp permission_options(_context, opts), do: {:ok, opts}

  defp normalize(:allow, _kind, input), do: {:ok, input, nil}
  defp normalize({:deny, _reason} = denied, _kind, _input), do: denied

  defp normalize({:allow, change}, kind, input),
    do: normalize({:allow, change, nil}, kind, input)

  defp normalize({:allow, {:replace_input, replacement}, feedback}, :function, _input)
       when is_map(replacement),
       do: {:ok, replacement, feedback}

  defp normalize({:allow, patch, feedback}, :function, input) when is_map(patch),
    do: {:ok, Map.merge(input, patch), feedback}

  # The interceptor represents context-only permission as an empty patch.
  defp normalize({:allow, patch, feedback}, :custom, input)
       when is_map(patch) and map_size(patch) == 0,
       do: {:ok, input, feedback}

  defp normalize({:allow, _change, _feedback}, :custom, _input),
    do: {:error, Error.new(:unsupported_capability, "custom tool input cannot accept map edits")}

  defp normalize(_result, _kind, _input),
    do: {:error, Error.new(:malformed_result, "invalid tool permission preparation result")}

  defp deliver_context(_context, _invocation, feedback) when feedback in [nil, ""], do: :ok

  defp deliver_context(context, invocation, feedback) when is_binary(feedback),
    do: HookContext.deliver(context, invocation, feedback, "PreToolUse")

  defp deliver_context(_context, _invocation, _feedback),
    do: {:error, Error.new(:malformed_result, "invalid tool hook context")}
end
