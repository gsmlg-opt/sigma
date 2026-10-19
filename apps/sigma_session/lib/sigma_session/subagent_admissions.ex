defmodule Sigma.Session.SubagentAdmissions do
  @moduledoc "Validated, operational birth intents and append-only admission outcomes."

  alias Sigma.Protocol.Subagents, as: DTO
  alias Sigma.Session.Subagents

  @identity [
    :attempt_id,
    :observer_incarnation,
    :agent_id,
    :run_id,
    :incarnation,
    :name,
    :child_session_id
  ]
  @strings @identity -- [:incarnation]
  @receipt [:status, :process_started, :receipt_acknowledged, :reason]
  @fields @identity ++ @receipt ++ [:phase, :metadata, :facts]

  def fields, do: @fields

  def normalize(attrs) when is_map(attrs) and not is_struct(attrs) do
    with :ok <- known_fields(attrs),
         {:ok, phase} <- enum(get(attrs, :phase), [:intent, :receipt], :phase),
         :ok <- identity(attrs),
         {:ok, metadata} <- metadata(get(attrs, :metadata, %{})),
         {:ok, receipt} <- receipt(attrs, phase),
         {:ok, facts} <- facts(get(attrs, :facts, []), attrs, phase, receipt) do
      {:ok,
       Map.new(@identity, &{&1, get(attrs, &1)})
       |> Map.merge(receipt)
       |> Map.merge(%{phase: phase, metadata: metadata, facts: facts})}
    end
  end

  def normalize(_), do: error(:not_a_map)

  def key(event), do: {event.attempt_id, event.phase, Map.get(event, :status)}

  @doc "Prepares both projections without publishing either before storage acknowledgement."
  def apply_event(admissions, roster, event) do
    existing = Map.get(admissions, event.attempt_id)
    previous = previous(existing, event)

    cond do
      previous == event ->
        {:ok, admissions, roster}

      not is_nil(previous) ->
        error(:conflict)

      event.phase == :receipt and is_nil(existing) ->
        error(:missing_intent)

      event.phase == :receipt and
          Map.take(existing.intent, @identity) != Map.take(event, @identity) ->
        error(:identity_conflict)

      event.phase == :receipt and not valid_next?(existing.receipts, event) ->
        error(:outcome_conflict)

      true ->
        with {:ok, roster} <- apply_facts(roster, event.facts) do
          record =
            if event.phase == :intent,
              do: %{intent: event, receipts: []},
              else: %{existing | receipts: existing.receipts ++ [event]}

          {:ok, Map.put(admissions, event.attempt_id, record), roster}
        end
    end
  end

  defp previous(nil, _), do: nil
  defp previous(record, %{phase: :intent}), do: record.intent
  defp previous(record, event), do: Enum.find(record.receipts, &(&1.status == event.status))

  defp valid_next?([], _), do: true
  defp valid_next?([%{status: :created}], %{status: :failed, process_started: true}), do: true
  defp valid_next?(_, _), do: false

  defp apply_facts(roster, facts) do
    Enum.reduce_while(facts, {:ok, roster}, fn fact, {:ok, acc} ->
      case Subagents.apply_event(acc, fact) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        error -> {:halt, error}
      end
    end)
  end

  defp known_fields(attrs) do
    keys = Enum.flat_map(@fields, &[&1, Atom.to_string(&1)])

    cond do
      Enum.any?(Map.keys(attrs), &(&1 not in keys)) ->
        error(:unknown_field)

      Enum.any?(@fields, &(Map.has_key?(attrs, &1) and Map.has_key?(attrs, Atom.to_string(&1)))) ->
        error(:duplicate_field)

      true ->
        :ok
    end
  end

  defp identity(attrs) do
    cond do
      Enum.any?(@strings, &(not is_binary(get(attrs, &1)) or get(attrs, &1) == "")) ->
        error(:identity)

      not (is_integer(get(attrs, :incarnation)) and get(attrs, :incarnation) > 0) ->
        error(:incarnation)

      true ->
        :ok
    end
  end

  defp metadata(map) when is_map(map) and not is_struct(map) do
    if Enum.all?(map, fn {k, v} ->
         (is_atom(k) or is_binary(k)) and (is_binary(v) or is_number(v) or is_boolean(v))
       end) do
      normalized = Map.new(map, fn {k, v} -> {to_string(k), v} end)
      if map_size(map) == map_size(normalized), do: {:ok, normalized}, else: error(:metadata)
    else
      error(:metadata)
    end
  end

  defp metadata(_), do: error(:metadata)

  defp receipt(attrs, :intent) do
    if Enum.any?(@receipt, &(Map.has_key?(attrs, &1) or Map.has_key?(attrs, Atom.to_string(&1)))),
      do: error(:intent_receipt_fields),
      else: {:ok, %{}}
  end

  defp receipt(attrs, :receipt) do
    with {:ok, status} <- enum(get(attrs, :status), [:created, :rejected, :failed], :status),
         true <- is_boolean(get(attrs, :process_started)),
         true <-
           is_nil(get(attrs, :receipt_acknowledged)) or
             is_boolean(get(attrs, :receipt_acknowledged)),
         true <- is_nil(get(attrs, :reason)) or is_binary(get(attrs, :reason)),
         true <- status != :created or get(attrs, :process_started),
         true <- status != :rejected or not get(attrs, :process_started) do
      {:ok,
       %{
         status: status,
         process_started: get(attrs, :process_started),
         receipt_acknowledged: get(attrs, :receipt_acknowledged),
         reason: get(attrs, :reason)
       }}
    else
      {:error, _} = error -> error
      _ -> error(:receipt)
    end
  end

  defp facts(facts, attrs, phase, receipt) when is_list(facts) do
    if facts != [] and (phase == :intent or not receipt.process_started) do
      error(:facts_without_process)
    else
      Enum.reduce_while(facts, {:ok, []}, fn attrs_fact, {:ok, acc} ->
        with {:ok, fact} <- DTO.event(attrs_fact),
             true <- fact.observer_incarnation == get(attrs, :observer_incarnation),
             true <-
               Enum.all?([:agent_id, :run_id, :incarnation, :child_session_id], fn key ->
                 not Map.has_key?(fact.data, key) or fact.data[key] == get(attrs, key)
               end) do
          {:cont, {:ok, [fact | acc]}}
        else
          {:error, _} = error -> {:halt, error}
          _ -> {:halt, error(:fact_identity)}
        end
      end)
      |> case do
        {:ok, result} -> {:ok, Enum.reverse(result)}
        error -> error
      end
    end
  end

  defp facts(_, _, _, _), do: error(:facts)

  defp enum(value, values, field) do
    case Enum.find(values, &(value == &1 or value == Atom.to_string(&1))) do
      nil -> error(field)
      result -> {:ok, result}
    end
  end

  defp get(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp error(reason), do: {:error, {:invalid_subagent_admission, reason}}
end
