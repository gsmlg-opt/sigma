defmodule Sigma.Agent.Backplane.ExecutionPolicy do
  @moduledoc false

  @idle_timeout 300_000
  @settlement_allowance 5_000

  def provider_options(options) do
    [
      provider_idle_timeout: Keyword.get(options, :receive_timeout) || @idle_timeout,
      provider_retry:
        if(Keyword.get(options, :retry) == false,
          do: false,
          else: %{stream_max_retries: 5, unbounded_connection_retries: true}
        )
    ]
  end

  def tool_effect_timeout(%{tool_name: name, arguments: arguments}, %{host: host})
      when is_map(arguments) do
    if name in Map.get(host, :native_tool_names, []) do
      case wait_duration(name, arguments) do
        duration when is_integer(duration) and duration >= 0 ->
          {:ok, min(duration + @settlement_allowance, 2_147_483_647)}

        _ ->
          :default
      end
    else
      :default
    end
  end

  def tool_effect_timeout(_invocation, _context), do: :default

  defp wait_duration("wait_agent", arguments),
    do: min(Map.get(arguments, "timeout_ms", 30_000), 3_600_000)

  defp wait_duration("clock::sleep", arguments),
    do: Map.get(arguments, "duration_ms")

  defp wait_duration("write_stdin", arguments),
    do: min(Map.get(arguments, "yield_time_ms", 5_000), 300_000)

  defp wait_duration("wait", arguments),
    do: Map.get(arguments, "yield_time_ms", 10_000)

  defp wait_duration(_name, _arguments), do: nil
end
