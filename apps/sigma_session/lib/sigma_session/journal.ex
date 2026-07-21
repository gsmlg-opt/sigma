defmodule Sigma.Session.Journal do
  @moduledoc """
  Pure validation and replay of one active session-journal branch.
  """

  alias Sigma.Session.{EntryDecoder, Snapshot}
  alias Sigma.Session.Journal.Index

  @service_tier_values ~w(auto default flex scale priority)
  @legacy_service_tiers @service_tier_values ++ ~w(openai-only claude-only)
  @service_tier_families ~w(openai anthropic google)

  @spec replay([term()], keyword()) :: {:ok, Snapshot.t()} | {:error, term()}
  def replay(entries, opts \\ []) when is_list(entries) do
    index = Index.build(entries)
    selector = Keyword.get(opts, :leaf_id, :latest)

    with {:ok, {leaf_id, nodes}} <- Index.path(index, selector) do
      header = index.header
      caller_diagnostics = Keyword.get(opts, :diagnostics, [])

      snapshot = %Snapshot{
        header: header,
        session_id: header && header["id"],
        cwd: header && header["cwd"],
        parent_session_id: header && header["parentSession"],
        active_leaf_id: leaf_id,
        branch_entry_ids: Enum.map(nodes, & &1.entry["id"])
      }

      {snapshot, payload_diagnostics_rev} =
        Enum.reduce(nodes, {snapshot, []}, &reduce_entry/2)

      payload_diagnostics = Enum.reverse(payload_diagnostics_rev)
      {messages, message_diagnostics, rendered_compaction} = render_messages(nodes)

      journal_diagnostics =
        index.diagnostics
        |> merge_diagnostics(payload_diagnostics)
        |> merge_diagnostics(message_diagnostics)

      diagnostics = Enum.uniq(caller_diagnostics ++ journal_diagnostics)

      {:ok,
       %{
         snapshot
         | compaction: rendered_compaction,
           messages: messages,
           diagnostics: diagnostics
       }}
    end
  end

  defp reduce_entry(%{entry: %{"type" => "model_change"} = entry} = node, acc) do
    update_snapshot(acc, node, fn snapshot ->
      case {Map.get(entry, "role", "default"), split_model(entry["model"])} do
        {role, {:ok, provider_id, model_id}} when role in [nil, "default"] ->
          {:ok, %{snapshot | provider_id: provider_id, model_id: model_id}}

        {role, {:ok, _provider_id, _model_id}} when is_binary(role) ->
          {:ok, snapshot}

        {_role, {:error, reason}} ->
          {:error, reason}

        {_role, {:ok, _provider_id, _model_id}} ->
          {:error, :invalid_model_role}
      end
    end)
  end

  defp reduce_entry(%{entry: %{"type" => "thinking_level_change"} = entry} = node, acc) do
    update_snapshot(acc, node, fn snapshot ->
      case entry["thinkingLevel"] do
        level when is_binary(level) or is_nil(level) ->
          configured = Map.get(entry, "configured", level)

          if is_binary(configured) or is_nil(configured) do
            {:ok,
             %{
               snapshot
               | reasoning_level: level,
                 configured_reasoning_level: configured
             }}
          else
            {:error, :invalid_configured_reasoning_level}
          end

        _value ->
          {:error, :invalid_reasoning_level}
      end
    end)
  end

  defp reduce_entry(%{entry: %{"type" => "service_tier_change"} = entry} = node, acc) do
    update_snapshot(acc, node, fn snapshot ->
      case Map.fetch(entry, "serviceTier") do
        {:ok, service_tier} ->
          if valid_service_tier?(service_tier) do
            {:ok, %{snapshot | service_tier: service_tier}}
          else
            {:error, :invalid_service_tier}
          end

        :error ->
          {:error, :missing_service_tier}
      end
    end)
  end

  defp reduce_entry(
         %{entry: %{"type" => "mcp_server_selection_change"} = entry} = node,
         acc
       ) do
    update_snapshot(acc, node, fn snapshot ->
      case entry["serverIds"] do
        ids when is_list(ids) ->
          if Enum.all?(ids, &is_binary/1) do
            {:ok, %{snapshot | mcp_server_ids: ids}}
          else
            {:error, :invalid_mcp_server_ids}
          end

        _value ->
          {:error, :invalid_mcp_server_ids}
      end
    end)
  end

  defp reduce_entry(%{entry: %{"type" => "mode_change"} = entry} = node, acc) do
    update_snapshot(acc, node, fn snapshot ->
      case {entry["mode"], Map.get(entry, "data")} do
        {mode, data} when is_binary(mode) and (is_map(data) or is_nil(data)) ->
          {:ok, %{snapshot | mode: mode, mode_data: data}}

        _value ->
          {:error, :invalid_mode_change}
      end
    end)
  end

  defp reduce_entry(%{entry: %{"type" => "compaction"} = entry}, {snapshot, diagnostics}) do
    {%{snapshot | compaction: entry}, diagnostics}
  end

  defp reduce_entry(%{entry: %{"type" => "branch_summary"} = entry} = node, acc) do
    update_snapshot(acc, node, fn snapshot ->
      if is_binary(entry["fromId"]) and is_binary(entry["summary"]) do
        {:ok, %{snapshot | branch_summary: entry}}
      else
        {:error, :invalid_branch_summary}
      end
    end)
  end

  defp reduce_entry(_node, acc), do: acc

  defp update_snapshot({snapshot, diagnostics}, node, updater) do
    case updater.(snapshot) do
      {:ok, updated} ->
        {updated, diagnostics}

      {:error, reason} ->
        {snapshot, [payload_diagnostic(node, reason) | diagnostics]}
    end
  end

  defp render_messages(nodes) do
    analysis = analyze_message_branch(nodes)
    {selected_compaction, compaction_diagnostics} = select_compaction(analysis)

    messages = render_analyzed_messages(analysis.decoded_messages, selected_compaction)

    diagnostics =
      merge_diagnostics(analysis.message_diagnostics, compaction_diagnostics)

    rendered_compaction =
      case selected_compaction do
        nil -> nil
        %{node: node} -> node.entry
      end

    {messages, diagnostics, rendered_compaction}
  end

  defp analyze_message_branch(nodes) do
    initial = %{
      entry_positions: %{},
      message_positions: %{},
      decoded_messages: [],
      message_diagnostics: [],
      compactions: []
    }

    {analysis, _next_position} =
      Enum.reduce(nodes, {initial, 0}, fn node, {analysis, position} ->
        entry = node.entry

        entry_positions =
          case entry["id"] do
            id when is_binary(id) -> Map.put(analysis.entry_positions, id, position)
            _id -> analysis.entry_positions
          end

        message_positions =
          case entry do
            %{"message" => %{"id" => id}} when is_binary(id) ->
              Map.put_new(analysis.message_positions, id, position)

            _entry ->
              analysis.message_positions
          end

        {decoded_messages, message_diagnostics} =
          if entry["type"] == "message" do
            case EntryDecoder.message(entry) do
              {:ok, message} ->
                {[{position, message} | analysis.decoded_messages], analysis.message_diagnostics}

              {:error, reason} ->
                {analysis.decoded_messages,
                 [payload_diagnostic(node, reason) | analysis.message_diagnostics]}
            end
          else
            {analysis.decoded_messages, analysis.message_diagnostics}
          end

        compactions =
          if entry["type"] == "compaction" do
            [{position, node} | analysis.compactions]
          else
            analysis.compactions
          end

        {%{
           analysis
           | entry_positions: entry_positions,
             message_positions: message_positions,
             decoded_messages: decoded_messages,
             message_diagnostics: message_diagnostics,
             compactions: compactions
         }, position + 1}
      end)

    %{
      analysis
      | decoded_messages: Enum.reverse(analysis.decoded_messages),
        message_diagnostics: Enum.reverse(analysis.message_diagnostics)
    }
  end

  defp select_compaction(analysis) do
    Enum.reduce_while(analysis.compactions, {nil, []}, fn {position, node},
                                                          {_selected, diagnostics} ->
      case applicable_compaction(node, position, analysis) do
        {:ok, summary, target_position} ->
          selected = %{node: node, summary: summary, target_position: target_position}
          {:halt, {selected, diagnostics}}

        {:error, reason} ->
          {:cont, {nil, [payload_diagnostic(node, reason) | diagnostics]}}
      end
    end)
  end

  defp applicable_compaction(node, position, analysis) do
    with {:ok, summary} <- EntryDecoder.compaction(node.entry),
         target_position when is_integer(target_position) <-
           compaction_target_position(node.entry, analysis),
         true <- target_position < position do
      {:ok, summary, target_position}
    else
      {:error, reason} -> {:error, reason}
      _invalid_target -> {:error, :invalid_compaction_target}
    end
  end

  defp compaction_target_position(entry, analysis) do
    case entry["firstKeptEntryId"] do
      nil ->
        legacy_target_position(entry["firstKeptId"], analysis)

      target_id ->
        entry_target_position(target_id, analysis)
    end
  end

  defp entry_target_position(target_id, analysis) when is_binary(target_id),
    do: Map.get(analysis.entry_positions, target_id)

  defp entry_target_position(_target_id, _analysis), do: nil

  defp legacy_target_position(target_id, analysis) when is_binary(target_id) do
    entry_position = Map.get(analysis.entry_positions, target_id)
    message_position = Map.get(analysis.message_positions, target_id)

    case {entry_position, message_position} do
      {nil, nil} -> nil
      {nil, position} -> position
      {position, nil} -> position
      {entry_position, message_position} -> min(entry_position, message_position)
    end
  end

  defp legacy_target_position(_target_id, _analysis), do: nil

  defp render_analyzed_messages(decoded_messages, nil) do
    Enum.map(decoded_messages, fn {_position, message} -> message end)
  end

  defp render_analyzed_messages(decoded_messages, selected_compaction) do
    kept_messages =
      for {position, message} <- decoded_messages,
          position >= selected_compaction.target_position,
          do: message

    [selected_compaction.summary | kept_messages]
  end

  defp payload_diagnostic(node, reason) do
    %{
      kind: :invalid_payload,
      entry_index: node.entry_index,
      entry_id: node.entry["id"],
      reason: reason
    }
  end

  defp split_model(model) when is_binary(model) do
    case String.split(model, "/", parts: 2) do
      [provider_id, model_id] when provider_id != "" and model_id != "" ->
        {:ok, provider_id, model_id}

      _parts ->
        {:error, :invalid_model}
    end
  end

  defp split_model(_model), do: {:error, :invalid_model}

  defp valid_service_tier?(nil), do: true

  defp valid_service_tier?(service_tier) when is_binary(service_tier),
    do: service_tier in @legacy_service_tiers

  defp valid_service_tier?(service_tiers)
       when is_map(service_tiers) and map_size(service_tiers) > 0 do
    Enum.all?(service_tiers, fn {family, service_tier} ->
      family in @service_tier_families and service_tier in @service_tier_values
    end)
  end

  defp valid_service_tier?(_service_tier), do: false

  defp merge_diagnostics(left, right), do: merge_diagnostics(left, right, [])

  defp merge_diagnostics([], right, acc), do: Enum.reverse(acc, right)
  defp merge_diagnostics(left, [], acc), do: Enum.reverse(acc, left)

  defp merge_diagnostics(
         [%{entry_index: left_index} = left | left_rest] = left_diagnostics,
         [%{entry_index: right_index} = right | right_rest] = right_diagnostics,
         acc
       ) do
    if left_index <= right_index do
      merge_diagnostics(left_rest, right_diagnostics, [left | acc])
    else
      merge_diagnostics(left_diagnostics, right_rest, [right | acc])
    end
  end
end
