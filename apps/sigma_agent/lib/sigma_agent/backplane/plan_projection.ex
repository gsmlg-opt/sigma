defmodule Sigma.Agent.Backplane.PlanProjection do
  @moduledoc """
  Bounded display snapshots of confirmed native plans, without replaying effects.

  Capture receives trusted final invocations or public `Plan.read/1` state. A
  state capture identifies the root tool publishing the observation, not a
  nested tool invocation. Hosts persist the returned value as `:native_plan`
  tool-result metadata; `latest/1` consumes only the selected display branch.
  Failed publications and old journals without this metadata retain the prior
  confirmed snapshot. This module never restores or executes a Plan process.
  """

  @max_steps 128
  @max_step_bytes 4_096
  @max_explanation_bytes 8_192
  @max_identity_bytes 512
  @max_snapshot_bytes 65_536
  @statuses ~w(pending in_progress completed)

  def capture(invocation, result) when is_map(invocation) and is_map(result) do
    if value(invocation, :tool_name) == "update_plan" and successful_receipt?(result) do
      snapshot(invocation, value(invocation, :arguments), value(result, :revision), "tool_result")
    else
      :ignore
    end
  end

  def capture(_invocation, _result), do: :ignore

  def capture_state(origin, {:ok, state}) when is_map(origin) and is_map(state) do
    snapshot(origin, value(state, :content), value(state, :revision), "plan_state")
  end

  def capture_state(_origin, _state), do: :ignore

  def latest(messages) when is_list(messages) do
    Enum.reduce(messages, nil, fn message, previous ->
      case published_snapshot(message) do
        {:ok, snapshot} -> snapshot
        :ignore -> previous
      end
    end)
  end

  @doc "Projects original message entries on an explicitly selected accepted branch."
  def latest_entries(entries, opts) when is_list(entries) do
    index = apply(Sigma.Session.Journal.Index, :build, [entries])

    with {:ok, {_leaf, nodes}} <-
           apply(Sigma.Session.Journal.Index, :path, [index, Keyword.fetch!(opts, :leaf_id)]),
         {:ok, messages} <- decode_messages(nodes) do
      {:ok, latest(messages)}
    end
  end

  defp decode_messages(nodes) do
    Enum.reduce_while(nodes, {:ok, []}, fn
      %{entry: %{"type" => "message"} = entry}, {:ok, messages} ->
        case apply(Sigma.Session.EntryDecoder, :message, [entry]) do
          {:ok, message} -> {:cont, {:ok, [message | messages]}}
          {:error, reason} -> {:halt, {:error, {:invalid_plan_journal, reason}}}
        end

      _node, acc ->
        {:cont, acc}
    end)
    |> case do
      {:ok, messages} -> {:ok, Enum.reverse(messages)}
      error -> error
    end
  end

  defp snapshot(origin, content, revision, source) when is_map(content) do
    steps = value(content, :plan)
    explanation = value(content, :explanation)

    with true <- is_integer(revision) and revision > 0,
         true <- identity?(value(origin, :run_id)),
         true <- identity?(value(origin, :tool_call_id)),
         true <- identity?(value(origin, :tool_name)),
         incarnation when is_integer(incarnation) and incarnation > 0 <-
           value(origin, :incarnation),
         true <- is_nil(explanation) or text?(explanation, @max_explanation_bytes),
         {:ok, steps} <- steps(steps),
         snapshot = %{
           "version" => 1,
           "source" => source,
           "source_tool" => value(origin, :tool_name),
           "run_id" => value(origin, :run_id),
           "incarnation" => incarnation,
           "tool_call_id" => value(origin, :tool_call_id),
           "revision" => revision,
           "explanation" => explanation,
           "plan" => steps
         },
         {:ok, json} <- Jason.encode(snapshot),
         true <- byte_size(json) <= @max_snapshot_bytes do
      {:ok, snapshot}
    else
      _ -> :ignore
    end
  end

  defp snapshot(_origin, _content, _revision, _source), do: :ignore

  defp steps(steps) when is_list(steps) and length(steps) <= @max_steps do
    if Enum.all?(steps, fn
         step when is_map(step) ->
           text?(value(step, :step), @max_step_bytes) and value(step, :status) in @statuses

         _ ->
           false
       end) do
      {:ok, Enum.map(steps, &%{"step" => value(&1, :step), "status" => value(&1, :status)})}
    else
      :ignore
    end
  end

  defp steps(_steps), do: :ignore

  defp published_snapshot(message) when is_map(message) do
    metadata = value(message, :metadata)

    with true <- value(message, :role) == :tool_result,
         true <- is_map(metadata),
         true <-
           value(message, :is_error) in [nil, false] or
             value(metadata, :native_effect_success) == true,
         saved when is_map(saved) <- value(metadata, :native_plan),
         true <- saved["version"] == 1,
         source when source in ["tool_result", "plan_state"] <- saved["source"],
         true <- saved["source_tool"] == value(message, :tool_name),
         true <- saved["tool_call_id"] == value(message, :tool_call_id),
         origin = %{
           run_id: saved["run_id"],
           incarnation: saved["incarnation"],
           tool_call_id: saved["tool_call_id"],
           tool_name: saved["source_tool"]
         },
         {:ok, normalized} <- snapshot(origin, saved, saved["revision"], source),
         true <- normalized == saved,
         true <- receipt_matches?(source, metadata, saved) do
      {:ok, normalized}
    else
      _ -> :ignore
    end
  end

  defp published_snapshot(_message), do: :ignore

  defp receipt_matches?("plan_state", _metadata, _saved), do: true

  defp receipt_matches?("tool_result", metadata, saved) do
    receipt = value(metadata, :structured_result)

    saved["source_tool"] == "update_plan" and is_map(receipt) and
      successful_receipt?(receipt) and value(receipt, :revision) == saved["revision"]
  end

  defp successful_receipt?(result) do
    value(result, :status) in [:updated, "updated"] and
      value(result, :is_error) in [nil, false] and is_nil(value(result, :error)) and
      is_integer(value(result, :revision)) and value(result, :revision) > 0
  end

  defp identity?(text), do: text?(text, @max_identity_bytes) and text != ""

  defp text?(text, limit),
    do: is_binary(text) and byte_size(text) <= limit and String.valid?(text)

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
