defmodule Sigma.Agent.CrashRedaction do
  @moduledoc """
  Removes provider credentials from GenServer crash reports and `:sys.get_status/1`.

  Processes that hold resolved provider options call `format_status/1` from their
  `c:GenServer.format_status/1` callback. Only presentation is affected; process
  state and `:sys.get_state/1` are unchanged.
  """

  @redacted "[REDACTED]"
  @keys [
    :api_key,
    "api_key",
    :resolved_key,
    "resolved_key",
    :authorization,
    "authorization",
    :auth_token,
    "auth_token"
  ]

  @filter_id :sigma_credential_redaction
  @crash_labels [{:gen_server, :terminate}, {:proc_lib, :crash}]

  @doc """
  Installs a primary `:logger` filter for crash reports.

  OTP reports a GenServer's stacktrace outside `format_status/1`; on a
  `FunctionClauseError` its top frame carries the callback arguments, including
  the full state. The filter redacts those reports before any handler formats them.
  """
  @spec install_log_filter() :: :ok
  def install_log_filter do
    case :logger.add_primary_filter(@filter_id, {&__MODULE__.log_filter/2, []}) do
      :ok -> :ok
      {:error, {:already_exist, @filter_id}} -> :ok
    end
  end

  @doc false
  def log_filter(%{msg: {:report, %{label: label} = report}} = event, _extra)
      when label in @crash_labels do
    %{event | msg: {:report, redact(report)}}
  rescue
    _ -> event
  end

  def log_filter(event, _extra), do: event

  @spec format_status(map()) :: map()
  def format_status(status) when is_map(status) do
    status
    |> redact_field(:state)
    |> redact_field(:message)
    |> redact_field(:reason)
    |> redact_field(:queue)
  end

  @spec redact(term()) :: term()
  def redact(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> redact_map()
    |> then(&struct(struct.__struct__, &1))
  rescue
    _ -> struct
  end

  def redact(map) when is_map(map), do: redact_map(map)
  def redact(list) when is_list(list), do: redact_list(list)

  def redact(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&redact/1) |> List.to_tuple()

  def redact(term), do: term

  defp redact_field(status, key) do
    case status do
      %{^key => value} -> Map.put(status, key, redact(value))
      _ -> status
    end
  end

  defp redact_map(map) do
    Map.new(map, fn
      {key, value} when key in @keys and value not in [nil, ""] -> {key, @redacted}
      {key, value} -> {key, redact(value)}
    end)
  end

  # Keyword lists and improper lists are both walked without changing shape.
  defp redact_list([{key, value} | rest]) when key in @keys and value not in [nil, ""],
    do: [{key, @redacted} | redact_list(rest)]

  defp redact_list([head | rest]), do: [redact(head) | redact_list(rest)]
  defp redact_list([]), do: []
  defp redact_list(tail), do: redact(tail)
end
