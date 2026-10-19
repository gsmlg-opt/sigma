defmodule Sigma.Session.EntryEncoder do
  @moduledoc """
  Pure conversion from durable agent/session events to v3 journal entries.

  Parent selection belongs to the caller so one serialized writer can advance
  the active leaf only after storage acknowledges an append.
  """

  @type encode_result :: {:ok, map()} | :ignored | {:error, term()}

  @spec encode(term(), String.t() | nil, boolean()) :: encode_result()
  def encode({:agent_start, cwd}, _parent_id, false) when is_binary(cwd) and cwd != "" do
    {:ok,
     %{
       "type" => "session",
       "version" => 3,
       "id" => session_id(),
       "timestamp" => timestamp(),
       "cwd" => cwd
     }}
  end

  def encode({:agent_start, _cwd}, _parent_id, true), do: :ignored

  def encode({:agent_start, _cwd}, _parent_id, false),
    do: {:error, {:invalid_session_header, :cwd}}

  def encode({:message_end, message}, parent_id, _header?) when is_struct(message) do
    {:ok, entry("message", parent_id, %{"message" => message_to_map(message)})}
  end

  def encode({:compact, %{content: summary}, first_kept_id}, parent_id, _header?)
      when is_binary(summary) and is_binary(first_kept_id) and first_kept_id != "" do
    {:ok,
     entry("compaction", parent_id, %{
       "summary" => summary,
       "firstKeptEntryId" => first_kept_id
     })}
  end

  def encode({:model_change, provider_id, model_id}, parent_id, _header?)
      when is_binary(provider_id) and provider_id != "" and is_binary(model_id) and
             model_id != "" do
    {:ok, entry("model_change", parent_id, %{"model" => "#{provider_id}/#{model_id}"})}
  end

  def encode({:thinking_level_change, level, configured}, parent_id, _header?)
      when (is_binary(level) or is_nil(level)) and
             (is_binary(configured) or is_nil(configured)) do
    {:ok,
     entry("thinking_level_change", parent_id, %{
       "thinkingLevel" => level,
       "configured" => configured
     })}
  end

  def encode({:service_tier_change, service_tier}, parent_id, _header?) do
    {:ok, entry("service_tier_change", parent_id, %{"serviceTier" => service_tier})}
  end

  def encode({:mcp_server_selection_change, server_ids}, parent_id, _header?)
      when is_list(server_ids) do
    if Enum.all?(server_ids, &is_binary/1) do
      {:ok, entry("mcp_server_selection_change", parent_id, %{"serverIds" => server_ids})}
    else
      {:error, {:invalid_mcp_server_selection, :server_ids}}
    end
  end

  def encode({:mode_change, mode, data}, parent_id, _header?)
      when is_binary(mode) and mode != "" and (is_map(data) or is_nil(data)) do
    {:ok, entry("mode_change", parent_id, %{"mode" => mode, "data" => data})}
  end

  def encode({:branch_summary, from_id, summary}, parent_id, _header?)
      when is_binary(from_id) and from_id != "" and is_binary(summary) do
    {:ok, entry("branch_summary", parent_id, %{"fromId" => from_id, "summary" => summary})}
  end

  def encode({:skill_invocation, invocation}, parent_id, _header?) when is_map(invocation) do
    {:ok, entry("skill_invocation", parent_id, %{"invocation" => invocation})}
  end

  alias Sigma.Protocol.Metrics

  def encode({:subagent_admission, attrs}, parent_id, _header?) do
    with {:ok, event} <- Sigma.Session.SubagentAdmissions.normalize(attrs) do
      {:ok, entry("subagent_admission", parent_id, Sigma.Protocol.Subagents.to_map(event))}
    end
  end

  def encode({:subagent, attrs}, parent_id, _header?) do
    with {:ok, event} <- Sigma.Protocol.Subagents.event(attrs) do
      {:ok, entry("subagent", parent_id, Sigma.Protocol.Subagents.to_map(event))}
    end
  end

  @metrics_facts ~w(request_started request_finished request_usage turn_started turn_finished tool_finished compaction operation_started operation_finished)
  @request_metrics_facts ~w(request_started request_finished request_usage)

  def encode({:metrics, fact, attrs}, parent_id, _header?)
      when (is_atom(fact) or is_binary(fact)) and is_map(attrs) do
    fact = to_string(fact)

    if fact in @metrics_facts do
      attrs =
        if fact in @request_metrics_facts, do: Metrics.sanitize_request_fact(attrs), else: attrs

      {:ok,
       entry("metrics", parent_id, %{
         "fact" => fact,
         "data" => encode_data(attrs)
       })}
    else
      {:error, {:invalid_metrics_fact, fact}}
    end
  end

  def encode({fact, attrs}, parent_id, header?)
      when fact in [
             :request_started,
             :request_finished,
             :request_usage,
             :turn_started,
             :turn_finished,
             :tool_finished,
             :compaction,
             :operation_started,
             :operation_finished
           ] and
             is_map(attrs),
      do: encode({:metrics, fact, attrs}, parent_id, header?)

  def encode(_event, _parent_id, _header?), do: :ignored

  defp entry(type, parent_id, payload) do
    Map.merge(
      %{
        "type" => type,
        "id" => entry_id(),
        "parentId" => parent_id,
        "timestamp" => timestamp()
      },
      payload
    )
  end

  defp message_to_map(message) do
    message
    |> Map.from_struct()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp encode_data(data) when is_struct(data) do
    module = data.__struct__

    data
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {to_string(key), encode_value(value)} end)
    |> Map.put("__struct__", Atom.to_string(module))
  end

  defp encode_data(data) when is_map(data) do
    Map.new(data, fn {key, value} -> {to_string(key), encode_value(value)} end)
  end

  defp encode_value(value) when is_atom(value), do: Atom.to_string(value)

  defp encode_value(value) when is_struct(value) do
    encode_data(value)
  end

  defp encode_value(value) when is_map(value), do: encode_data(value)
  defp encode_value(value) when is_list(value), do: Enum.map(value, &encode_value/1)
  defp encode_value(value) when is_tuple(value), do: value |> Tuple.to_list() |> encode_value()

  defp encode_value(value)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
       do: value

  defp encode_value(value), do: inspect(value, limit: 50, printable_limit: 1_000)

  defp entry_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  defp session_id, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
