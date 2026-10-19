defmodule Sigma.Protocol.Subagents do
  @moduledoc "Transport-neutral, display-safe subagent lifecycle facts."

  @facts [:registered, :run_started, :run_finished, :closed, :recovered]
  @statuses [
    :pending_init,
    :running,
    :cancelling,
    :completed,
    :errored,
    :interrupted,
    :shutdown,
    :unknown_outcome
  ]
  @closures [:open, :closed, :unknown]
  @strings [
    :agent_id,
    :agent_path,
    :root_session_id,
    :parent_agent_id,
    :child_session_id,
    :origin_turn_id,
    :origin_tool_call_id,
    :task,
    :agent_type,
    :model,
    :run_id,
    :reason
  ]
  @timestamps [:created_at, :started_at, :finished_at]
  @fields @strings ++ @timestamps ++ [:depth, :incarnation, :status, :activity, :closure]
  @activities [
    :unknown,
    :waiting_model,
    :waiting_tool,
    :waiting_approval,
    :waiting_agent,
    :model,
    :tool,
    :approval,
    :agent
  ]

  @type event :: %{
          fact: atom(),
          data: map(),
          event_id: String.t(),
          revision: pos_integer(),
          observer_incarnation: String.t()
        }

  @doc "Validates a fact without creating atoms or retaining arbitrary host payloads."
  @spec event(term()) :: {:ok, event()} | {:error, {:invalid_event, term()}}
  def event(attrs) when is_map(attrs) do
    with {:ok, fact} <- enum(get(attrs, :fact), @facts, :fact),
         :ok <- required_string(get(attrs, :event_id), :event_id),
         :ok <- required_string(get(attrs, :observer_incarnation), :observer_incarnation),
         :ok <- positive_integer(get(attrs, :revision), :revision),
         {:ok, data} <- data(get(attrs, :data)) do
      {:ok,
       %{
         fact: fact,
         data: data,
         event_id: get(attrs, :event_id),
         revision: get(attrs, :revision),
         observer_incarnation: get(attrs, :observer_incarnation)
       }}
    end
  end

  def event(_), do: {:error, {:invalid_event, :not_a_map}}

  @doc "Validates and whitelists a committed roster before serialization."
  def snapshot(attrs) when is_map(attrs) and not is_struct(attrs) do
    with revision when is_integer(revision) and revision >= 0 <- get(attrs, :revision),
         agents when is_list(agents) <- get(attrs, :agents),
         {:ok, agents} <- snapshot_agents(agents, revision),
         counts when is_map(counts) <- get(attrs, :counts),
         {:ok, counts} <- snapshot_counts(counts, agents) do
      {:ok, %{revision: revision, agents: agents, counts: counts}}
    else
      _ -> {:error, {:invalid_snapshot, :subagents}}
    end
  end

  def snapshot(_), do: {:error, {:invalid_snapshot, :subagents}}

  defp snapshot_agents(agents, revision) do
    Enum.reduce_while(agents, {:ok, []}, fn row, {:ok, rows} ->
      with {:ok, safe} <- data(row),
           :ok <- positive_integer(get(row, :revision), :revision),
           true <- get(row, :revision) <= revision,
           :ok <- required_string(get(row, :event_id), :event_id),
           :ok <- required_string(get(row, :observer_incarnation), :observer_incarnation) do
        safe =
          Map.merge(
            safe,
            Map.new([:revision, :event_id, :observer_incarnation], &{&1, get(row, &1)})
          )

        {:cont, {:ok, [safe | rows]}}
      else
        _ -> {:halt, {:error, :invalid_agent}}
      end
    end)
    |> case do
      {:ok, rows} ->
        rows = Enum.reverse(rows)

        if length(Enum.uniq_by(rows, & &1.agent_id)) == length(rows),
          do: {:ok, rows},
          else: {:error, :duplicate_agent}

      error ->
        error
    end
  end

  defp snapshot_counts(counts, agents) do
    expected =
      Enum.reduce(agents, %{created: 0, executing: 0, pending: 0, stopped: 0, unknown: 0}, fn row,
                                                                                              counts ->
        bucket =
          case row.status do
            status when status in [:running, :cancelling] -> :executing
            :pending_init -> :pending
            :unknown_outcome -> :unknown
            _ -> :stopped
          end

        counts |> Map.update!(:created, &(&1 + 1)) |> Map.update!(bucket, &(&1 + 1))
      end)

    if Enum.all?(expected, fn {key, value} -> get(counts, key) == value end),
      do: {:ok, expected},
      else: {:error, :invalid_counts}
  end

  @doc "All allowed display fields; absent observations remain nil."
  def agent_fields, do: @fields ++ [:revision, :event_id, :observer_incarnation]

  @doc "Converts safe DTOs to JSON-compatible string keys and enum values."
  def to_map(value) when is_map(value),
    do: Map.new(value, fn {key, value} -> {to_string(key), to_map(value)} end)

  def to_map(value) when is_list(value), do: Enum.map(value, &to_map/1)
  def to_map(value) when is_nil(value) or is_boolean(value), do: value
  def to_map(value) when is_atom(value), do: Atom.to_string(value)
  def to_map(value), do: value

  defp data(attrs) when is_map(attrs) and not is_struct(attrs) do
    attrs =
      Map.new(@fields, &{&1, get(attrs, &1)})
      |> Map.reject(fn {key, _} -> not present?(attrs, key) end)

    with :ok <- required_string(attrs[:agent_id], :agent_id),
         :ok <- required_string(attrs[:run_id], :run_id),
         :ok <- positive_integer(attrs[:incarnation], :incarnation),
         {:ok, status} <- enum(attrs[:status], @statuses, :status),
         {:ok, closure} <- optional_enum(attrs[:closure], @closures, :closure),
         {:ok, activity} <- activity(attrs[:activity]),
         :ok <- optional_strings(attrs),
         :ok <- timestamps(attrs),
         :ok <- depth(attrs[:depth]) do
      {:ok,
       attrs
       |> Map.put(:status, status)
       |> maybe_put(:closure, closure)
       |> maybe_put(:activity, activity)}
    end
  end

  defp data(_), do: {:error, {:invalid_event, :data}}

  defp optional_strings(attrs) do
    case Enum.find(@strings, fn key -> not (is_nil(attrs[key]) or is_binary(attrs[key])) end) do
      nil -> :ok
      field -> {:error, {:invalid_event, field}}
    end
  end

  defp timestamps(attrs) do
    case Enum.find(@timestamps, fn key ->
           not (is_nil(attrs[key]) or (is_integer(attrs[key]) and attrs[key] >= 0))
         end) do
      nil -> :ok
      field -> {:error, {:invalid_event, field}}
    end
  end

  defp depth(nil), do: :ok
  defp depth(depth) when is_integer(depth) and depth > 0, do: :ok
  defp depth(_), do: {:error, {:invalid_event, :depth}}
  defp activity(nil), do: {:ok, nil}
  defp activity(value), do: enum(value, @activities, :activity)
  defp optional_enum(nil, _, _), do: {:ok, nil}
  defp optional_enum(value, values, field), do: enum(value, values, field)

  defp enum(value, values, field) do
    case Enum.find(values, fn allowed -> value == allowed or value == Atom.to_string(allowed) end) do
      nil -> {:error, {:invalid_event, field}}
      value -> {:ok, value}
    end
  end

  defp positive_integer(value, _) when is_integer(value) and value > 0, do: :ok
  defp positive_integer(_, field), do: {:error, {:invalid_event, field}}
  defp required_string(value, _) when is_binary(value) and byte_size(value) > 0, do: :ok
  defp required_string(_, field), do: {:error, {:invalid_event, field}}
  defp get(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp present?(attrs, key),
    do: Map.has_key?(attrs, key) or Map.has_key?(attrs, Atom.to_string(key))

  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)
end
