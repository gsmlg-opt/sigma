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
      {messages, message_diagnostics} = render_messages(nodes)

      journal_diagnostics =
        index.diagnostics
        |> merge_diagnostics(payload_diagnostics)
        |> merge_diagnostics(message_diagnostics)

      diagnostics = Enum.uniq(caller_diagnostics ++ journal_diagnostics)

      {:ok,
       %{
         snapshot
         | messages: messages,
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
    case latest_compaction(nodes) do
      nil ->
        decode_message_nodes(nodes)

      compaction_node ->
        render_compacted_messages(nodes, compaction_node)
    end
  end

  defp latest_compaction(nodes) do
    nodes
    |> Enum.filter(&(&1.entry["type"] == "compaction"))
    |> List.last()
  end

  defp render_compacted_messages(nodes, compaction_node) do
    compaction_position = Enum.find_index(nodes, &(&1.entry["id"] == compaction_node.entry["id"]))
    target_id = compaction_node.entry["firstKeptEntryId"] || compaction_node.entry["firstKeptId"]

    target_position =
      Enum.find_index(nodes, fn node ->
        node.entry["id"] == target_id or get_in(node.entry, ["message", "id"]) == target_id
      end)

    if is_integer(target_position) and target_position < compaction_position do
      {kept_messages, diagnostics} = nodes |> Enum.drop(target_position) |> decode_message_nodes()

      case EntryDecoder.compaction(compaction_node.entry) do
        {:ok, summary} ->
          {[summary | kept_messages], diagnostics}

        {:error, reason} ->
          {all_messages, all_diagnostics} = decode_message_nodes(nodes)

          {all_messages,
           merge_diagnostics(all_diagnostics, [payload_diagnostic(compaction_node, reason)])}
      end
    else
      {all_messages, diagnostics} = decode_message_nodes(nodes)

      {all_messages,
       merge_diagnostics(diagnostics, [
         payload_diagnostic(compaction_node, :invalid_compaction_target)
       ])}
    end
  end

  defp decode_message_nodes(nodes) do
    {messages_rev, diagnostics_rev} =
      Enum.reduce(nodes, {[], []}, fn node, {messages, diagnostics} ->
        if node.entry["type"] == "message" do
          case EntryDecoder.message(node.entry) do
            {:ok, message} ->
              {[message | messages], diagnostics}

            {:error, reason} ->
              {messages, [payload_diagnostic(node, reason) | diagnostics]}
          end
        else
          {messages, diagnostics}
        end
      end)

    {Enum.reverse(messages_rev), Enum.reverse(diagnostics_rev)}
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
