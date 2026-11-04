defmodule Sigma.Session.Journal do
  @moduledoc """
  Pure validation and replay of one active session-journal branch.
  """

  alias Sigma.Session.{
    EntryDecoder,
    HookFeedback,
    Metrics,
    Snapshot,
    SubagentAdmissions,
    Subagents
  }

  alias Sigma.Session.Journal.Index
  alias Sigma.Protocol.AsyncInteractions

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
        active_leaf_id: conversation_leaf_id(nodes, leaf_id),
        branch_entry_ids: Enum.map(nodes, & &1.entry["id"]),
        message_entry_ids: message_entry_ids(nodes)
      }

      snapshot = %{snapshot | metrics: metrics_snapshot(index, snapshot.session_id, opts)}
      {roster, receipts, admissions, admission_ids, subagent_diagnostics} = subagent_roster(index)
      {async_interactions, async_ids, async_diagnostics} = async_interactions(index)

      {_hooks, _hook_ids, hook_diagnostics} =
        hook_feedback(index, Keyword.get(opts, :hook_session_id))

      snapshot = %{
        snapshot
        | subagent_roster: roster,
          subagents: Subagents.snapshot(roster),
          subagent_entry_ids: receipts,
          subagent_admissions: admissions,
          subagent_admission_entry_ids: admission_ids,
          async_interactions: project_async_interactions(async_interactions, index, nodes),
          async_interaction_history: async_interactions,
          async_interaction_entry_ids: async_ids
      }

      {snapshot, payload_diagnostics_rev} =
        Enum.reduce(nodes, {snapshot, []}, &reduce_entry/2)

      payload_diagnostics = Enum.reverse(payload_diagnostics_rev)
      {messages, message_diagnostics, rendered_compaction} = render_messages(nodes)
      context_nodes = context_nodes(nodes, snapshot)
      {context_messages, context_diagnostics, _compaction} = render_messages(context_nodes)

      messages =
        if snapshot.context_window do
          boundaries = snapshot.context_window_entry_ids |> Map.values() |> MapSet.new()
          render_window_display(nodes, boundaries)
        else
          messages
        end

      journal_diagnostics =
        index.diagnostics
        |> merge_diagnostics(payload_diagnostics)
        |> merge_diagnostics(message_diagnostics)
        |> merge_diagnostics(context_diagnostics)

      diagnostics =
        Enum.uniq(
          caller_diagnostics ++
            journal_diagnostics ++
            subagent_diagnostics ++
            async_diagnostics ++
            hook_diagnostics
        )

      {:ok,
       %{
         snapshot
         | compaction: rendered_compaction,
           messages: messages,
           context_messages: context_messages,
           diagnostics: diagnostics
       }}
    end
  end

  defp reduce_entry(%{entry: %{"type" => "model_change"} = entry} = node, acc) do
    acc = mark_model_source(acc, entry)

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

  defp reduce_entry(%{entry: %{"type" => "context_window"} = entry} = node, acc) do
    update_snapshot(acc, node, fn snapshot ->
      with {:ok, window} <- EntryDecoder.context_window(entry) do
        key = {window.run_id, window.incarnation, window.window}

        stale? =
          Enum.any?(snapshot.context_window_entry_ids, fn
            {{run, incarnation, version}, _id} ->
              run == window.run_id and incarnation == window.incarnation and
                version > window.window
          end)

        cond do
          Map.has_key?(snapshot.context_window_entry_ids, key) ->
            {:ok, snapshot}

          stale? ->
            {:error, :stale_context_window}

          true ->
            {:ok,
             %{
               snapshot
               | context_window: window,
                 context_window_entry_ids:
                   Map.put(snapshot.context_window_entry_ids, key, entry["id"])
             }}
        end
      end
    end)
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

  defp reduce_entry(%{entry: %{"type" => "metrics"} = entry}, {snapshot, diagnostics}) do
    case EntryDecoder.metrics(entry) do
      {:ok, _fact} ->
        {snapshot, diagnostics}

      {:error, reason} ->
        {snapshot, [payload_diagnostic_from_entry(entry, reason) | diagnostics]}
    end
  end

  defp reduce_entry(_node, acc), do: acc

  defp context_nodes(nodes, %{context_window: nil}), do: nodes

  defp context_nodes(nodes, snapshot) do
    window = snapshot.context_window
    id = snapshot.context_window_entry_ids[{window.run_id, window.incarnation, window.window}]
    nodes |> Enum.drop_while(&(&1.entry["id"] != id)) |> Enum.drop(1)
  end

  defp render_window_display(nodes, boundaries) do
    {before, boundary_and_after} =
      Enum.split_while(nodes, fn node ->
        not MapSet.member?(boundaries, node.entry["id"])
      end)

    {messages, _diagnostics, _compaction} = render_messages(before)

    case boundary_and_after do
      [] -> messages
      [_boundary | after_nodes] -> messages ++ render_window_display(after_nodes, boundaries)
    end
  end

  defp metrics_snapshot(index, session_id, opts) do
    metrics =
      index.ordered
      |> Enum.filter(&match?(%{entry: %{"type" => "metrics"}}, &1))
      |> Enum.reduce(Metrics.new(session_id), fn %{entry: entry}, metrics ->
        case EntryDecoder.metrics(entry) do
          {:ok, fact} -> Metrics.reduce(metrics, fact)
          {:error, _reason} -> metrics
        end
      end)

    # Runtime reads the durable facts before sampling the current Agent identity.
    # Ordinary journal recovery has no live host evidence and finalizes everything.
    if Keyword.get(opts, :finalize_metrics, true),
      do: Metrics.finalize_in_flight(metrics),
      else: metrics
  end

  defp subagent_roster(index) do
    {roster, receipts, admissions, admission_ids, diagnostics} =
      Enum.reduce(index.ordered, {Subagents.new(), %{}, %{}, %{}, []}, fn
        %{entry: %{"type" => "subagent_admission"} = entry} = node,
        {roster, receipts, admissions, admission_ids, diagnostics} ->
          with {:ok, event} <- EntryDecoder.subagent_admission(entry),
               {:ok, admissions, updated} <-
                 SubagentAdmissions.apply_event(admissions, roster, event) do
            receipts =
              Enum.reduce(event.facts, receipts, fn fact, acc ->
                Map.put_new(acc, fact.event_id, entry["id"])
              end)

            {updated, receipts, admissions,
             Map.put_new(admission_ids, SubagentAdmissions.key(event), entry["id"]), diagnostics}
          else
            {:error, reason} ->
              {roster, receipts, admissions, admission_ids,
               [payload_diagnostic(node, reason) | diagnostics]}
          end

        %{entry: %{"type" => "subagent"} = entry} = node,
        {roster, receipts, admissions, admission_ids, diagnostics} ->
          with {:ok, event} <- EntryDecoder.subagent(entry),
               {:ok, updated} <- Subagents.apply_event(roster, event) do
            {updated, Map.put_new(receipts, event.event_id, entry["id"]), admissions,
             admission_ids, diagnostics}
          else
            {:error, reason} ->
              {roster, receipts, admissions, admission_ids,
               [payload_diagnostic(node, reason) | diagnostics]}
          end

        _node, acc ->
          acc
      end)

    {Subagents.recover(roster), receipts, admissions, admission_ids, Enum.reverse(diagnostics)}
  end

  defp conversation_leaf_id(nodes, _fallback) do
    nodes
    |> Enum.reverse()
    |> Enum.find_value(nil, fn %{entry: %{"type" => type, "id" => id}} ->
      if type not in [
           "metrics",
           "subagent",
           "subagent_admission",
           "async_interaction",
           "hook_feedback"
         ],
         do: id
    end)
  end

  @doc false
  def async_interaction_projection(projection, entries, leaf_id) do
    index = Index.build(entries)

    with {:ok, {_leaf, nodes}} <- Index.path(index, leaf_id) do
      {:ok, project_async_interactions(projection, index, nodes)}
    end
  end

  defp project_async_interactions(projection, index, nodes) do
    project_auxiliary_items(projection, index, nodes, "async_interaction")
  end

  @doc false
  def hook_feedback_projection(entries, leaf_id, session_id \\ nil) do
    index = Index.build(entries)

    with {:ok, {_leaf, nodes}} <- Index.path(index, leaf_id) do
      case hook_feedback(index, session_id) do
        {history, receipts, []} ->
          selected = project_auxiliary_items(history, index, nodes, "hook_feedback")

          events =
            Map.filter(history.events, fn {_id, event} ->
              Map.has_key?(selected.items, event["item_id"])
            end)

          {:ok,
           %{
             history: history,
             projection: %{selected | events: events},
             entry_ids: receipts
           }}

        {_history, _receipts, diagnostics} ->
          {:error, {:invalid_journal, diagnostics}}
      end
    end
  end

  defp project_auxiliary_items(projection, index, nodes, type) do
    selected = MapSet.new(nodes, & &1.entry["id"])

    # Keep the global receipts for reconciliation and exactly-once admission.
    # A card with facts on another branch must not expose that branch's answer,
    # or become an open question that can dispatch the same logical reply again.
    hidden =
      Enum.reduce(index.ordered, MapSet.new(), fn
        %{
          entry: %{"type" => ^type, "event" => %{"item_id" => id}},
          parent_id: parent
        },
        acc ->
          if MapSet.member?(selected, parent), do: acc, else: MapSet.put(acc, id)

        _, acc ->
          acc
      end)

    items =
      Map.reject(projection.items, fn {id, item} ->
        MapSet.member?(hidden, id) or
          not MapSet.member?(selected, item["origin"]["branch_entry_id"])
      end)

    %{projection | items: items}
  end

  defp hook_feedback(index, session_id) do
    {projection, receipts, diagnostics, _parents} =
      Enum.reduce(index.ordered, {HookFeedback.new(), %{}, [], %{}}, fn
        %{entry: %{"type" => "hook_feedback"} = entry} = node,
        {projection, receipts, diagnostics, item_parents} ->
          with {:ok, event} <- EntryDecoder.hook_feedback(entry),
               :ok <- validate_hook_session(event, session_id),
               :ok <- validate_hook_anchor(event, projection, index, node, item_parents),
               {:ok, updated} <- HookFeedback.apply_event(projection, event) do
            parents =
              Map.update(item_parents, event["item_id"], [node.parent_id], &[node.parent_id | &1])

            {updated, Map.put_new(receipts, event["event_id"], entry["id"]), diagnostics, parents}
          else
            {:error, reason} ->
              diagnostic = %{payload_diagnostic(node, reason) | kind: :invalid_hook_feedback}
              {projection, receipts, diagnostics ++ [diagnostic], item_parents}
          end

        _, acc ->
          acc
      end)

    {projection, receipts, diagnostics}
  end

  # The log header ID is independently generated and is not host session authority.
  defp validate_hook_session(_event, nil), do: :ok
  defp validate_hook_session(%{"session_id" => session_id}, session_id), do: :ok
  defp validate_hook_session(_event, _session_id), do: {:error, :invalid_hook_feedback_session}

  defp validate_hook_anchor(event, projection, index, node, item_parents) do
    origin =
      if event["fact"] == "received",
        do: event["origin"],
        else: get_in(projection, [:items, event["item_id"], "origin"])

    with %{} <- origin,
         %{entry_index: anchor_index, entry: %{"type" => "message"}} <-
           index.by_id[origin["branch_entry_id"]],
         true <- anchor_index < node.entry_index,
         {:ok, {_leaf, parents}} <- Index.path(index, node.parent_id),
         selected = MapSet.new(parents, & &1.entry["id"]),
         true <- MapSet.member?(selected, origin["branch_entry_id"]),
         true <-
           Enum.all?(Map.get(item_parents, event["item_id"], []), &MapSet.member?(selected, &1)) do
      :ok
    else
      _ -> {:error, :invalid_hook_feedback_scope}
    end
  end

  defp async_interactions(index) do
    Enum.reduce(index.ordered, {AsyncInteractions.new(), %{}, []}, fn
      %{entry: %{"type" => "async_interaction"} = entry} = node,
      {projection, receipts, diagnostics} ->
        with {:ok, event} <- EntryDecoder.async_interaction(entry),
             :ok <- validate_async_anchor(event, projection, index, node),
             {:ok, updated} <- AsyncInteractions.apply_event(projection, event) do
          {updated, Map.put_new(receipts, event["event_id"], entry["id"]), diagnostics}
        else
          {:error, reason} ->
            diagnostic = %{payload_diagnostic(node, reason) | kind: :invalid_async_interaction}
            {projection, receipts, diagnostics ++ [diagnostic]}
        end

      _, acc ->
        acc
    end)
  end

  defp validate_async_anchor(event, projection, index, node) do
    origin =
      if event["fact"] == "received",
        do: event["origin"],
        else: get_in(projection, [:items, event["item_id"], "origin"])

    case origin && index.by_id[origin["branch_entry_id"]] do
      %{
        entry_index: anchor_index,
        entry: %{
          "type" => "message",
          "message" => %{"role" => "user", "metadata" => %{"turn_id" => run_id}}
        }
      }
      when anchor_index < node.entry_index ->
        with true <- run_id == origin["run_id"],
             {:ok, {_leaf, parents}} <- Index.path(index, node.parent_id),
             true <- Enum.any?(parents, &(&1.entry["id"] == origin["branch_entry_id"])) do
          :ok
        else
          _ -> {:error, :invalid_async_anchor}
        end

      _ ->
        {:error, :invalid_async_anchor}
    end
  end

  defp payload_diagnostic_from_entry(entry, reason),
    do: %{kind: :invalid_payload, entry_id: entry["id"], reason: reason}

  defp message_entry_ids(nodes) do
    Enum.reduce(nodes, %{}, fn
      %{entry: %{"id" => entry_id, "message" => %{"id" => message_id}}}, acc
      when is_binary(entry_id) and is_binary(message_id) ->
        Map.put_new(acc, message_id, entry_id)

      _node, acc ->
        acc
    end)
  end

  defp mark_model_source({snapshot, diagnostics} = acc, entry) do
    case Map.get(entry, "role", "default") do
      role when role in [nil, "default"] ->
        {%{snapshot | model_source: :journal}, diagnostics}

      role when not is_binary(role) ->
        {%{snapshot | model_source: :journal}, diagnostics}

      _scoped_role ->
        acc
    end
  end

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
    {messages, repair_diagnostics} = repair_tool_message_sequence(messages, nodes)

    diagnostics =
      analysis.message_diagnostics
      |> merge_diagnostics(compaction_diagnostics)
      |> merge_diagnostics(repair_diagnostics)

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
    Enum.reduce(analysis.compactions, {nil, []}, fn {position, node}, {selected, diagnostics} ->
      case applicable_compaction(node, position, analysis) do
        {:ok, summary, target_position} when is_nil(selected) ->
          selected = %{node: node, summary: summary, target_position: target_position}
          {selected, diagnostics}

        {:ok, _summary, _target_position} ->
          {selected, diagnostics}

        {:error, reason} ->
          {selected, [payload_diagnostic(node, reason) | diagnostics]}
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

  # Provider APIs require every assistant tool call to have a matching result.
  # Interrupted sessions can persist an assistant message without that result.
  defp repair_tool_message_sequence(messages, nodes) do
    call_ids =
      for %{role: :assistant, content: content} <- messages,
          %{type: :tool_call, id: id} <- List.wrap(content),
          into: MapSet.new(),
          do: id

    result_ids =
      for %{role: :tool_result, tool_call_id: id} <- messages,
          into: MapSet.new(),
          do: id

    {repaired, diagnostics} =
      Enum.map_reduce(messages, [], fn message, diagnostics ->
        case message do
          %{role: :assistant, content: content} when is_list(content) ->
            {kept, removed} =
              Enum.split_with(content, fn
                %{type: :tool_call, id: id} -> MapSet.member?(result_ids, id)
                _ -> true
              end)

            diagnostics =
              Enum.reduce(removed, diagnostics, fn %{id: id}, acc ->
                [tool_repair_diagnostic(message, nodes, {:orphaned_tool_call, id}) | acc]
              end)

            {%{message | content: kept}, diagnostics}

          %{role: :tool_result, tool_call_id: id} = result ->
            if MapSet.member?(call_ids, id) do
              {result, diagnostics}
            else
              {nil,
               [tool_repair_diagnostic(message, nodes, {:orphaned_tool_result, id}) | diagnostics]}
            end

          _ ->
            {message, diagnostics}
        end
      end)

    {Enum.reject(repaired, &is_nil/1), Enum.reverse(diagnostics)}
  end

  defp tool_repair_diagnostic(message, nodes, reason) do
    node = Enum.find(nodes, fn node -> get_in(node, [:entry, "message", "id"]) == message.id end)

    %{
      kind: :message_repair,
      entry_index: node && node.entry_index,
      entry_id: node && node.entry["id"],
      reason: reason
    }
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
