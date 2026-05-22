defmodule PiCoding.PermissionInterceptor do
  @moduledoc """
  Interprets permission rules before tool execution.
  """

  alias PiCoding.PermissionPolicy

  @doc """
  Checks if a tool call is allowed based on the provided options.

  Returns `:allow`, `{:deny, reason}`, or handles `:ask` via a callback.
  """
  def check(tool_call, opts) do
    session_id = Keyword.get(opts, :session_id)

    :telemetry.execute(
      [:ex_pi, :permission, :check, :start],
      %{system_time: System.system_time()},
      %{session_id: session_id, tool_name: tool_call.name}
    )

    result = do_check(tool_call, opts)

    :telemetry.execute(
      [:ex_pi, :permission, :check, :stop],
      %{},
      %{session_id: session_id, tool_name: tool_call.name, result: inspect(result)}
    )

    result
  end

  defp do_check(tool_call, opts) do
    policy = Keyword.get(opts, :permission_policy)

    cond do
      # If a policy GenServer is provided, use it.
      policy && (is_pid(policy) || (is_atom(policy) && Process.whereis(policy))) ->
        case PermissionPolicy.check(policy, tool_call.name) do
          :allow ->
            :allow

          :deny ->
            {:deny, "Permission denied by policy for tool: #{tool_call.name}"}

          :ask ->
            request_fn = Keyword.get(opts, :permission_request_fn)

            if request_fn do
              request_fn.(tool_call)
            else
              {:deny,
               "Permission required for tool '#{tool_call.name}' but no request function provided"}
            end
        end

      # Simple configuration in opts
      Keyword.has_key?(opts, :allow_tool) ->
        allowed = Keyword.get(opts, :allow_tool)

        if tool_call.name == allowed or (is_list(allowed) and tool_call.name in allowed) do
          :allow
        else
          {:deny, "Permission denied for tool: #{tool_call.name}"}
        end

      # Default to allow
      true ->
        :allow
    end
  end
end
