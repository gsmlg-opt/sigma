defmodule Sigma.Session.Metrics do
  @moduledoc """
  Pure reducer for durable request, tool, and compaction facts.

  The reducer keeps one latest revision per request. It deliberately does not
  infer missing usage as zero and never includes tool time in LLM throughput.
  """

  defstruct session_id: nil,
            requests: %{},
            turns: %{},
            tools: %{},
            compactions: %{},
            facts: 0,
            projection: nil

  @type t :: %__MODULE__{}

  @spec new(String.t() | nil) :: t()
  def new(session_id \\ nil),
    do: %__MODULE__{session_id: session_id, projection: new_projection(session_id)}

  @spec reduce(t(), map() | tuple()) :: t()
  def reduce(%__MODULE__{} = state, fact) do
    state = ensure_projection_session(state)

    case normalize_fact(fact) do
      {:request, request} ->
        put_request(state, request)

      {:turn, turn} ->
        put_turn(state, turn)

      {:tool, tool} ->
        put_tool(state, tool)

      {:compaction, compaction} ->
        put_compaction(state, compaction)

      :ignore ->
        state
    end
  end

  @spec reduce_all(Enumerable.t(), String.t() | nil) :: t()
  def reduce_all(facts, session_id \\ nil),
    do: Enum.reduce(facts, new(session_id), &reduce(&2, &1))

  @doc """
  Marks unfinished requests and turns as interrupted, except exact live identities
  supplied by the host. Live records must belong to this session; a live request
  must also match the supplied turn, including nil for an auxiliary request.
  """
  @spec finalize_in_flight(t(), keyword()) :: t()
  def finalize_in_flight(%__MODULE__{} = state, opts \\ []) do
    active_turn_id = Keyword.get(opts, :active_turn_id)
    active_request_id = Keyword.get(opts, :active_request_id)

    requests =
      Map.new(state.requests, fn {request_id, request} ->
        live? =
          active_metric?(request, state.session_id, :request_id, active_request_id) and
            request.turn_id == active_turn_id

        {request_id, if(live?, do: request, else: finalize_request(request))}
      end)

    turns =
      Map.new(state.turns, fn {turn_id, turn} ->
        live? = active_metric?(turn, state.session_id, :turn_id, active_turn_id)
        {turn_id, if(live?, do: turn, else: finalize_turn(turn))}
      end)

    %{state | requests: requests, turns: turns}
    |> rebuild_projection()
  end

  defp active_metric?(record, session_id, identity_key, identity)
       when is_binary(session_id) and session_id != "" and is_binary(identity) and identity != "",
       do: record.session_id == session_id and Map.get(record, identity_key) == identity

  defp active_metric?(_record, _session_id, _identity_key, _identity), do: false

  @doc "Returns deterministic work counters used by performance regression tests."
  @spec projection_stats(t()) :: map()
  def projection_stats(%__MODULE__{} = state) do
    state = ensure_projection_session(state)

    %{
      accepted_facts: state.facts,
      historical_items_visited: state.projection.historical_items_visited,
      snapshot_full_history_scans: 0,
      snapshot_bucket_items_visited: map_size(state.projection.model_outputs),
      retained_records:
        map_size(state.requests) + map_size(state.turns) + map_size(state.tools) +
          map_size(state.compactions)
    }
  end

  @spec snapshot(t(), keyword()) :: map()
  def snapshot(%__MODULE__{} = state, opts \\ []) do
    state = ensure_projection_session(state)
    projection = state.projection
    active_ids = Keyword.get(opts, :active_request_ids)

    active_usage =
      if is_list(active_ids) do
        active_ids
        |> Enum.map(&Map.get(state.requests, &1))
        |> Enum.reject(&is_nil/1)
        |> aggregate()
      end

    usage = usage_from_acc(projection.own_usage)
    compaction_summary = projection.compaction_summary

    %{
      session_id: state.session_id,
      started_at:
        earliest_timestamp(projection.request_started_at.min, projection.turn_started_at.min),
      active_time_ms: projection.active_time_ms,
      own_usage: usage,
      active_lineage_usage: active_usage,
      inherited_usage: usage_from_acc(projection.inherited_usage),
      request_count: projection.own_usage.request_count,
      known_usage_requests: usage.known_requests,
      coverage: coverage_from_acc(projection.own_usage),
      average_llm_tok_s: usage.throughput,
      requests: state.requests,
      turns: projection.turn_summaries,
      usage_by_purpose: projection.purpose_outputs,
      usage_by_model:
        projection.model_outputs
        |> Map.values()
        |> Enum.sort_by(&{&1.provider || "", &1.model || ""}),
      tools: projection.tool_outputs,
      compactions: projection.compaction_outputs,
      compaction_summary: compaction_summary,
      last_compaction: compaction_summary.last_successful,
      successful_compactions: compaction_summary.successful_count
    }
  end

  defp put_request(state, %{request_id: id, revision: revision} = request)
       when is_binary(id) and id != "" and is_integer(revision) and revision >= 0,
       do: put_request_with_id(state, request)

  defp put_request(state, _request), do: state

  defp put_request_with_id(state, request) do
    case Map.get(state.requests, request.request_id) do
      nil ->
        request = if is_nil(request.purpose), do: %{request | purpose: :turn}, else: request

        state = %{
          state
          | requests: Map.put(state.requests, request.request_id, request),
            facts: state.facts + 1
        }

        project_request(state, nil, request)

      previous when request.revision > previous.revision ->
        merged = merge_request(previous, request)

        state = %{
          state
          | requests: Map.put(state.requests, request.request_id, merged),
            facts: state.facts + 1
        }

        project_request(state, previous, merged)

      previous when request.revision == previous.revision ->
        merged = merge_request(previous, request)

        if merged == previous do
          state
        else
          state = %{
            state
            | requests: Map.put(state.requests, request.request_id, merged),
              facts: state.facts + 1
          }

          project_request(state, previous, merged)
        end

      _duplicate ->
        state
    end
  end

  defp finalize_request(%{status: status} = request)
       when status in [nil, :started, :running] do
    %{request | status: :interrupted, usage_status: :unknown, elapsed_ms: nil, finished_at: nil}
  end

  defp finalize_request(request), do: request

  defp finalize_turn(%{status: status} = turn) when status in [nil, :started, :running] do
    %{turn | status: :interrupted, finished_at: nil, wall_time_ms: nil}
  end

  defp finalize_turn(turn), do: turn

  defp put_turn(state, %{turn_id: id, revision: revision} = turn)
       when is_binary(id) and id != "" and is_integer(revision) and revision >= 0 do
    case Map.get(state.turns, id) do
      nil ->
        state = %{state | turns: Map.put(state.turns, id, turn), facts: state.facts + 1}
        project_turn(state, nil, turn)

      %{revision: previous_revision} = previous when revision > previous_revision ->
        merged = merge_request(previous, turn)
        state = %{state | turns: Map.put(state.turns, id, merged), facts: state.facts + 1}
        project_turn(state, previous, merged)

      %{revision: previous_revision} = previous when revision == previous_revision ->
        merged = merge_request(previous, turn)

        if merged == previous do
          state
        else
          state = %{state | turns: Map.put(state.turns, id, merged), facts: state.facts + 1}
          project_turn(state, previous, merged)
        end

      _duplicate ->
        state
    end
  end

  defp put_turn(state, _turn), do: state

  defp put_tool(state, %{tool_id: id, revision: revision} = tool)
       when is_binary(id) and id != "" and is_integer(revision) and revision >= 0 do
    case Map.get(state.tools, id) do
      nil ->
        state = %{state | tools: Map.put(state.tools, id, tool), facts: state.facts + 1}
        project_tool(state, nil, tool)

      %{revision: previous_revision} = previous when revision > previous_revision ->
        merged = merge_request(previous, tool)
        state = %{state | tools: Map.put(state.tools, id, merged), facts: state.facts + 1}
        project_tool(state, previous, merged)

      %{revision: previous_revision} = previous when revision == previous_revision ->
        merged = merge_request(previous, tool)

        if merged == previous do
          state
        else
          state = %{state | tools: Map.put(state.tools, id, merged), facts: state.facts + 1}
          project_tool(state, previous, merged)
        end

      _duplicate ->
        state
    end
  end

  defp put_tool(state, _tool), do: state

  defp put_compaction(state, %{compaction_id: id} = compaction)
       when is_binary(id) and id != "" do
    revision = Map.get(compaction, :revision, 0)

    case Map.get(state.compactions, id) do
      nil ->
        compaction =
          if is_nil(compaction.request_ids), do: %{compaction | request_ids: []}, else: compaction

        state = %{
          state
          | compactions: Map.put(state.compactions, id, compaction),
            facts: state.facts + 1
        }

        project_compaction(state, nil, compaction)

      %{revision: previous_revision} = previous when revision > previous_revision ->
        merged = merge_request(previous, compaction)

        state = %{
          state
          | compactions: Map.put(state.compactions, id, merged),
            facts: state.facts + 1
        }

        project_compaction(state, previous, merged)

      %{revision: previous_revision} = previous when revision == previous_revision ->
        merged = merge_request(previous, compaction)

        if merged == previous do
          state
        else
          state = %{
            state
            | compactions: Map.put(state.compactions, id, merged),
              facts: state.facts + 1
          }

          project_compaction(state, previous, merged)
        end

      _duplicate ->
        state
    end
  end

  defp put_compaction(state, _compaction), do: state

  defp merge_request(previous, current) do
    Map.merge(previous, current, fn _key, old, new -> if is_nil(new), do: old, else: new end)
  end

  defp aggregate([]) do
    %{
      input_tokens_total: 0,
      output_tokens_total: 0,
      total_tokens: 0,
      cache_read_tokens: 0,
      cache_write_tokens: 0,
      reasoning_tokens: 0,
      visible_output_tokens: 0,
      known_requests: 0,
      request_count: 0,
      throughput: nil,
      throughput_requests: 0,
      partial?: false
    }
  end

  defp aggregate(requests) do
    known = Enum.filter(requests, &known_usage?/1)

    if known == [] do
      %{unknown_usage() | request_count: length(requests)}
    else
      aggregate_known(requests, known)
    end
  end

  defp aggregate_known(requests, known) do
    throughput_requests = Enum.filter(known, &positive?(&1.elapsed_ms))
    input = sum(known, :input_tokens_total)
    output = sum(known, :output_tokens_total)
    throughput_output = sum(throughput_requests, :output_tokens_total)
    elapsed = sum(throughput_requests, :elapsed_ms)

    %{
      input_tokens_total: input,
      output_tokens_total: output,
      total_tokens: input + output,
      cache_read_tokens: complete_sum(known, :cache_read_tokens),
      cache_write_tokens: complete_sum(known, :cache_write_tokens),
      reasoning_tokens: complete_sum(known, :reasoning_tokens),
      visible_output_tokens: complete_sum(known, :visible_output_tokens),
      known_requests: length(known),
      request_count: length(requests),
      throughput: throughput(throughput_output, elapsed),
      throughput_requests: length(throughput_requests),
      partial?: length(known) != length(requests)
    }
  end

  defp throughput(output, elapsed) when output >= 0 and elapsed > 0,
    do: output / (elapsed / 1_000)

  defp throughput(_output, _elapsed), do: nil

  defp earliest_timestamp(nil, right), do: right
  defp earliest_timestamp(left, nil), do: left
  defp earliest_timestamp(left, right), do: min(left, right)

  defp wall_time_ms(started_at, finished_at)
       when is_binary(started_at) and is_binary(finished_at) do
    with {:ok, started, _offset} <- DateTime.from_iso8601(started_at),
         {:ok, finished, _offset} <- DateTime.from_iso8601(finished_at) do
      max(DateTime.diff(finished, started, :millisecond), 0)
    else
      _ -> nil
    end
  end

  defp wall_time_ms(_started_at, _finished_at), do: nil

  defp unknown_usage do
    %{
      input_tokens_total: nil,
      output_tokens_total: nil,
      total_tokens: nil,
      cache_read_tokens: nil,
      cache_write_tokens: nil,
      reasoning_tokens: nil,
      visible_output_tokens: nil,
      known_requests: 0,
      request_count: 0,
      throughput: nil,
      throughput_requests: 0,
      partial?: true
    }
  end

  defp turn_interval(%{started_at: started_at, finished_at: finished_at})
       when is_binary(started_at) and is_binary(finished_at) do
    with {:ok, started, _} <- DateTime.from_iso8601(started_at),
         {:ok, finished, _} <- DateTime.from_iso8601(finished_at) do
      {DateTime.to_unix(started, :millisecond), DateTime.to_unix(finished, :millisecond)}
    else
      _ -> nil
    end
  end

  defp turn_interval(_turn), do: nil

  defp compaction_summary(compactions) do
    successful = Enum.filter(compactions, &(&1.status == :committed))

    %{
      attempt_count: length(compactions),
      successful_count: length(successful),
      failed_count: Enum.count(compactions, &(&1.status == :failed)),
      last_attempt: latest_compaction(compactions),
      last_successful: latest_compaction(successful)
    }
  end

  defp latest_compaction(compactions),
    do:
      Enum.max_by(compactions, &{&1.finished_at || &1.started_at || "", &1.compaction_id}, fn ->
        nil
      end)

  defp known_usage?(request),
    do:
      is_integer(request.input_tokens_total) and request.input_tokens_total >= 0 and
        is_integer(request.output_tokens_total) and request.output_tokens_total >= 0

  defp positive?(value), do: is_integer(value) and value > 0
  defp sum(items, key), do: Enum.reduce(items, 0, &((Map.get(&1, key) || 0) + &2))

  defp complete_sum(items, key) do
    if Enum.all?(items, &(is_integer(Map.get(&1, key)) and Map.get(&1, key) >= 0)) do
      sum(items, key)
    end
  end

  defp new_projection(session_id) do
    %{
      session_id: session_id,
      own_usage: new_usage_acc(),
      inherited_usage: new_usage_acc(),
      purpose_accs: %{},
      purpose_outputs: %{},
      model_accs: %{},
      model_outputs: %{},
      request_started_at: new_time_bag(),
      turn_started_at: new_time_bag(),
      turn_data: %{},
      turn_summaries: %{},
      tool_outputs: [],
      compaction_outputs: [],
      compaction_summary: compaction_summary([]),
      active_intervals: :gb_trees.empty(),
      active_time_ms: nil,
      historical_items_visited: 0
    }
  end

  defp rebuild_projection(state) do
    previous_visits =
      if state.projection, do: state.projection.historical_items_visited, else: 0

    record_count =
      map_size(state.requests) + map_size(state.turns) + map_size(state.tools) +
        map_size(state.compactions)

    state = %{state | projection: new_projection(state.session_id)}

    state =
      Enum.reduce(state.requests, state, fn {_id, request}, acc ->
        project_request(acc, nil, request)
      end)

    state =
      Enum.reduce(state.tools, state, fn {_id, tool}, acc -> project_tool(acc, nil, tool) end)

    state =
      Enum.reduce(state.turns, state, fn {_id, turn}, acc -> project_turn(acc, nil, turn) end)

    state =
      Enum.reduce(state.compactions, state, fn {_id, compaction}, acc ->
        project_compaction(acc, nil, compaction)
      end)

    put_in(
      state.projection.historical_items_visited,
      previous_visits + record_count
    )
  end

  defp ensure_projection_session(
         %{session_id: session_id, projection: %{session_id: session_id}} = state
       ),
       do: state

  defp ensure_projection_session(state), do: rebuild_projection(state)

  defp project_request(state, previous, current) do
    projection = state.projection

    projection =
      projection
      |> adjust_global_request(state.session_id, previous, -1)
      |> adjust_global_request(state.session_id, current, 1)
      |> adjust_request_started_pair(state.session_id, previous, current)
      |> adjust_request_turn_change(state.session_id, previous, current)
      |> refresh_turns([previous && previous.turn_id, current.turn_id])

    %{state | projection: projection}
  end

  defp adjust_global_request(projection, _session_id, nil, _direction), do: projection

  defp adjust_global_request(projection, session_id, request, direction) do
    cond do
      request.session_id == session_id ->
        purpose = request.purpose
        model = {request.provider, request.model}

        purpose_acc =
          adjust_usage(
            Map.get(projection.purpose_accs, purpose, new_usage_acc()),
            request,
            direction
          )

        model_acc =
          adjust_usage(Map.get(projection.model_accs, model, new_usage_acc()), request, direction)

        %{
          projection
          | own_usage: adjust_usage(projection.own_usage, request, direction),
            purpose_accs: put_or_delete_empty(projection.purpose_accs, purpose, purpose_acc),
            purpose_outputs:
              put_or_delete_usage(projection.purpose_outputs, purpose, purpose_acc),
            model_accs: put_or_delete_empty(projection.model_accs, model, model_acc),
            model_outputs: put_or_delete_model(projection.model_outputs, model, model_acc)
        }

      not is_nil(request.session_id) ->
        %{
          projection
          | inherited_usage: adjust_usage(projection.inherited_usage, request, direction)
        }

      true ->
        projection
    end
  end

  defp adjust_request_started_pair(projection, session_id, previous, current) do
    previous_time = if previous && previous.session_id == session_id, do: previous.started_at
    current_time = if current.session_id == session_id, do: current.started_at

    if previous_time == current_time do
      projection
    else
      %{
        projection
        | request_started_at:
            projection.request_started_at
            |> adjust_time(previous_time, -1)
            |> adjust_time(current_time, 1)
      }
    end
  end

  defp adjust_request_turn_change(projection, session_id, previous, current) do
    same_turn? =
      previous && previous.session_id == session_id && current.session_id == session_id &&
        not is_nil(current.turn_id) && previous.turn_id == current.turn_id

    if same_turn? do
      update_turn_data(projection, current.turn_id, fn data ->
        data
        |> Map.update!(:request_usage, fn usage ->
          usage |> adjust_usage(previous, -1) |> adjust_usage(current, 1)
        end)
        |> Map.update!(:request_started_at, fn times ->
          adjust_time_pair(times, previous.started_at, current.started_at)
        end)
        |> Map.update!(:request_finished_at, fn times ->
          adjust_time_pair(times, previous.finished_at, current.finished_at)
        end)
        |> Map.update!(:request_statuses, fn statuses ->
          statuses |> adjust_count(previous.status, -1) |> adjust_count(current.status, 1)
        end)
      end)
    else
      projection
      |> adjust_request_turn(session_id, previous, -1)
      |> adjust_request_turn(session_id, current, 1)
    end
  end

  defp adjust_request_turn(projection, _session_id, nil, _direction), do: projection

  defp adjust_request_turn(projection, session_id, request, direction) do
    if request.session_id == session_id and not is_nil(request.turn_id) do
      update_turn_data(projection, request.turn_id, fn data ->
        data
        |> Map.update!(:request_usage, &adjust_usage(&1, request, direction))
        |> Map.update!(:request_started_at, &adjust_time(&1, request.started_at, direction))
        |> Map.update!(:request_finished_at, &adjust_time(&1, request.finished_at, direction))
        |> Map.update!(:request_statuses, &adjust_count(&1, request.status, direction))
        |> adjust_request_id(request.request_id, direction)
      end)
    else
      projection
    end
  end

  defp project_tool(state, previous, current) do
    projection =
      state.projection
      |> adjust_tool_turn(previous, -1)
      |> adjust_tool_turn(current, 1)
      |> refresh_turns([previous && previous.turn_id, current.turn_id])

    {tool_outputs, visits} = replace_output(projection.tool_outputs, previous, current, :tool_id)

    %{state | projection: add_visits(%{projection | tool_outputs: tool_outputs}, visits)}
  end

  defp adjust_tool_turn(projection, nil, _direction), do: projection

  defp adjust_tool_turn(projection, tool, direction) do
    if is_nil(tool.turn_id) do
      projection
    else
      update_turn_data(projection, tool.turn_id, fn data ->
        data
        |> Map.update!(:tool_count, &(&1 + direction))
        |> Map.update!(:tool_elapsed, &adjust_tool_elapsed(&1, tool.elapsed_ms, direction))
        |> Map.update!(:tool_statuses, &adjust_count(&1, tool.status, direction))
      end)
    end
  end

  defp project_turn(state, previous, current) do
    old_own = own_turn?(previous, state.session_id)
    new_own = own_turn?(current, state.session_id)

    projection =
      state.projection
      |> maybe_adjust_turn_started(previous, old_own, -1)
      |> maybe_adjust_turn_started(current, new_own, 1)
      |> maybe_put_lifecycle(previous, old_own, nil)
      |> maybe_put_lifecycle(current, new_own, current)
      |> refresh_turns([previous && previous.turn_id, current.turn_id])
      |> update_active_interval(state, previous, current, old_own, new_own)

    %{state | projection: projection}
  end

  defp own_turn?(nil, _session_id), do: false
  defp own_turn?(turn, session_id), do: turn.session_id in [nil, session_id]

  defp maybe_adjust_turn_started(projection, _turn, false, _direction), do: projection

  defp maybe_adjust_turn_started(projection, turn, true, direction),
    do: %{
      projection
      | turn_started_at: adjust_time(projection.turn_started_at, turn.started_at, direction)
    }

  defp maybe_put_lifecycle(projection, _turn, false, _value), do: projection

  defp maybe_put_lifecycle(projection, turn, true, value) do
    update_turn_data(projection, turn.turn_id, &Map.put(&1, :lifecycle, value))
  end

  defp update_active_interval(projection, state, previous, current, old_own, new_own) do
    old_interval = if old_own, do: turn_interval(previous)
    new_interval = if new_own, do: turn_interval(current)

    cond do
      old_interval == new_interval ->
        projection

      is_nil(old_interval) and not is_nil(new_interval) ->
        add_active_interval(projection, new_interval)

      true ->
        rebuild_active_intervals(projection, state.turns, state.session_id)
    end
  end

  defp rebuild_active_intervals(projection, turns, session_id) do
    reset = %{projection | active_intervals: :gb_trees.empty(), active_time_ms: nil}

    rebuilt =
      Enum.reduce(turns, reset, fn {_id, turn}, acc ->
        if own_turn?(turn, session_id) do
          case turn_interval(turn) do
            nil -> acc
            interval -> add_active_interval(acc, interval)
          end
        else
          acc
        end
      end)

    add_visits(rebuilt, map_size(turns))
  end

  defp add_active_interval(projection, {start_ms, finish_ms}) do
    {tree, removed_ms, merged_start, merged_finish} =
      merge_predecessor(projection.active_intervals, start_ms, finish_ms)

    {tree, removed_ms, merged_finish} =
      merge_successors(tree, merged_start, merged_finish, removed_ms)

    tree = :gb_trees.enter(merged_start, merged_finish, tree)
    previous_total = projection.active_time_ms || 0

    %{
      projection
      | active_intervals: tree,
        active_time_ms: previous_total - removed_ms + merged_finish - merged_start
    }
  end

  defp merge_predecessor(tree, start_ms, finish_ms) do
    case :gb_trees.smaller(start_ms, tree) do
      {_key, predecessor_finish} when predecessor_finish >= start_ms ->
        {predecessor_start, predecessor_finish} = :gb_trees.smaller(start_ms, tree)

        {
          :gb_trees.delete(predecessor_start, tree),
          predecessor_finish - predecessor_start,
          predecessor_start,
          max(predecessor_finish, finish_ms)
        }

      _ ->
        case :gb_trees.lookup(start_ms, tree) do
          {:value, existing_finish} ->
            {:gb_trees.delete(start_ms, tree), existing_finish - start_ms, start_ms,
             max(existing_finish, finish_ms)}

          :none ->
            {tree, 0, start_ms, finish_ms}
        end
    end
  end

  defp merge_successors(tree, start_ms, finish_ms, removed_ms) do
    case :gb_trees.larger(start_ms, tree) do
      {next_start, next_finish} when next_start <= finish_ms ->
        merge_successors(
          :gb_trees.delete(next_start, tree),
          start_ms,
          max(finish_ms, next_finish),
          removed_ms + next_finish - next_start
        )

      _ ->
        {tree, removed_ms, finish_ms}
    end
  end

  defp project_compaction(state, nil, current) do
    projection = state.projection
    outputs = [current | projection.compaction_outputs]

    %{
      state
      | projection: %{
          projection
          | compaction_outputs: outputs,
            compaction_summary: add_compaction_summary(projection.compaction_summary, current)
        }
    }
  end

  defp project_compaction(state, _previous, _current) do
    compactions = Map.values(state.compactions)

    projection = %{
      state.projection
      | compaction_outputs: compactions,
        compaction_summary: compaction_summary(compactions)
    }

    %{state | projection: add_visits(projection, length(compactions))}
  end

  defp add_compaction_summary(summary, compaction) do
    committed? = compaction.status == :committed
    failed? = compaction.status == :failed

    %{
      attempt_count: summary.attempt_count + 1,
      successful_count: summary.successful_count + if(committed?, do: 1, else: 0),
      failed_count: summary.failed_count + if(failed?, do: 1, else: 0),
      last_attempt: later_compaction(summary.last_attempt, compaction),
      last_successful:
        if(committed?,
          do: later_compaction(summary.last_successful, compaction),
          else: summary.last_successful
        )
    }
  end

  defp later_compaction(nil, current), do: current

  defp later_compaction(previous, current) do
    if {current.finished_at || current.started_at || "", current.compaction_id} >
         {previous.finished_at || previous.started_at || "", previous.compaction_id},
       do: current,
       else: previous
  end

  defp replace_output(outputs, nil, current, _id_key), do: {[current | outputs], 0}

  defp replace_output(outputs, previous, current, id_key) do
    id = Map.fetch!(previous, id_key)

    {Enum.map(outputs, fn item -> if Map.fetch!(item, id_key) == id, do: current, else: item end),
     length(outputs)}
  end

  defp update_turn_data(projection, turn_id, update) do
    data = update.(Map.get(projection.turn_data, turn_id, new_turn_data()))
    %{projection | turn_data: Map.put(projection.turn_data, turn_id, data)}
  end

  defp refresh_turns(projection, turn_ids) do
    turn_ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.reduce(projection, &refresh_turn(&2, &1))
  end

  defp refresh_turn(projection, turn_id) do
    case Map.get(projection.turn_data, turn_id) do
      nil ->
        projection

      data ->
        if empty_turn_data?(data) do
          %{
            projection
            | turn_data: Map.delete(projection.turn_data, turn_id),
              turn_summaries: Map.delete(projection.turn_summaries, turn_id)
          }
        else
          %{
            projection
            | turn_summaries: Map.put(projection.turn_summaries, turn_id, turn_summary(data))
          }
        end
    end
  end

  defp new_turn_data do
    %{
      request_usage: new_usage_acc(),
      request_ids: [],
      request_started_at: new_time_bag(),
      request_finished_at: new_time_bag(),
      request_statuses: %{},
      tool_count: 0,
      tool_elapsed: %{count: 0, known: 0, sum: 0},
      tool_statuses: %{},
      lifecycle: nil
    }
  end

  defp empty_turn_data?(data),
    do: data.request_usage.request_count == 0 and data.tool_count == 0 and is_nil(data.lifecycle)

  defp turn_summary(data) do
    usage =
      if data.request_usage.request_count == 0,
        do: unknown_usage(),
        else: usage_from_acc(data.request_usage)

    lifecycle = data.lifecycle || %{}
    started_at = lifecycle[:started_at] || data.request_started_at.min
    finished_at = lifecycle[:finished_at] || data.request_finished_at.max

    usage
    |> Map.put(:request_ids, data.request_ids)
    |> Map.put(:tool_count, data.tool_count)
    |> Map.put(:tool_elapsed_ms, optional_integer_value(data.tool_elapsed))
    |> Map.put(:status, lifecycle[:status] || turn_status_from_counts(data))
    |> Map.put(:started_at, started_at)
    |> Map.put(:finished_at, finished_at)
    |> Map.put(:wall_time_ms, lifecycle[:wall_time_ms] || wall_time_ms(started_at, finished_at))
    |> Map.merge(
      Map.take(lifecycle, [
        :session_id,
        :revision,
        :terminal_reason,
        :source_message_id,
        :source_checkpoint_id,
        :retry_of_turn_id,
        :provenance
      ])
    )
  end

  defp turn_status_from_counts(data) do
    statuses =
      Map.merge(data.request_statuses, data.tool_statuses, fn _status, left, right ->
        left + right
      end)

    cond do
      map_size(statuses) == 0 -> :unknown
      Enum.any?([nil, :started, :running], &Map.has_key?(statuses, &1)) -> :running
      Map.has_key?(statuses, :interrupted) -> :interrupted
      Map.has_key?(statuses, :failed) -> :failed
      Map.has_key?(statuses, :cancelled) -> :cancelled
      map_size(statuses) == 1 and Map.has_key?(statuses, :completed) -> :completed
      true -> :unknown
    end
  end

  defp adjust_request_id(data, request_id, 1),
    do: %{data | request_ids: Enum.sort([request_id | data.request_ids])}

  defp adjust_request_id(data, request_id, -1),
    do: %{data | request_ids: List.delete(data.request_ids, request_id)}

  defp new_usage_acc do
    %{
      request_count: 0,
      known_requests: 0,
      input: 0,
      output: 0,
      throughput_output: 0,
      throughput_elapsed: 0,
      throughput_requests: 0,
      optional: %{
        cache_read_tokens: %{sum: 0, known: 0},
        cache_write_tokens: %{sum: 0, known: 0},
        reasoning_tokens: %{sum: 0, known: 0},
        visible_output_tokens: %{sum: 0, known: 0}
      }
    }
  end

  defp adjust_usage(acc, request, direction) do
    acc = %{acc | request_count: acc.request_count + direction}

    if known_usage?(request) do
      timed? = positive?(request.elapsed_ms)

      %{
        acc
        | known_requests: acc.known_requests + direction,
          input: acc.input + direction * request.input_tokens_total,
          output: acc.output + direction * request.output_tokens_total,
          throughput_output:
            acc.throughput_output +
              if(timed?, do: direction * request.output_tokens_total, else: 0),
          throughput_elapsed:
            acc.throughput_elapsed + if(timed?, do: direction * request.elapsed_ms, else: 0),
          throughput_requests: acc.throughput_requests + if(timed?, do: direction, else: 0),
          optional:
            Enum.reduce(Map.keys(acc.optional), acc.optional, fn key, optional ->
              Map.update!(
                optional,
                key,
                &adjust_optional_integer(&1, Map.get(request, key), direction)
              )
            end)
      }
    else
      acc
    end
  end

  defp usage_from_acc(%{request_count: 0}), do: aggregate([])

  defp usage_from_acc(%{known_requests: 0, request_count: count}),
    do: %{unknown_usage() | request_count: count}

  defp usage_from_acc(acc) do
    %{
      input_tokens_total: acc.input,
      output_tokens_total: acc.output,
      total_tokens: acc.input + acc.output,
      cache_read_tokens: optional_usage_value(acc, :cache_read_tokens),
      cache_write_tokens: optional_usage_value(acc, :cache_write_tokens),
      reasoning_tokens: optional_usage_value(acc, :reasoning_tokens),
      visible_output_tokens: optional_usage_value(acc, :visible_output_tokens),
      known_requests: acc.known_requests,
      request_count: acc.request_count,
      throughput: throughput(acc.throughput_output, acc.throughput_elapsed),
      throughput_requests: acc.throughput_requests,
      partial?: acc.known_requests != acc.request_count
    }
  end

  defp optional_usage_value(acc, key) do
    value = Map.fetch!(acc.optional, key)
    if value.known == acc.known_requests, do: value.sum
  end

  defp coverage_from_acc(%{request_count: 0}), do: %{known: 0, total: 0, ratio: nil}

  defp coverage_from_acc(acc),
    do: %{
      known: acc.known_requests,
      total: acc.request_count,
      ratio: acc.known_requests / acc.request_count
    }

  defp adjust_optional_integer(acc, value, direction) when is_integer(value) and value >= 0,
    do: %{acc | sum: acc.sum + direction * value, known: acc.known + direction}

  defp adjust_optional_integer(acc, _value, _direction), do: acc

  defp adjust_tool_elapsed(acc, value, direction) do
    acc = %{acc | count: acc.count + direction}
    adjust_optional_integer(acc, value, direction)
  end

  defp optional_integer_value(%{count: 0}), do: 0
  defp optional_integer_value(%{count: count, known: count, sum: sum}), do: sum
  defp optional_integer_value(_acc), do: nil

  defp adjust_count(counts, value, direction) do
    count = Map.get(counts, value, 0) + direction
    if count == 0, do: Map.delete(counts, value), else: Map.put(counts, value, count)
  end

  defp new_time_bag, do: %{counts: %{}, min: nil, max: nil}
  defp adjust_time(bag, value, _direction) when not is_binary(value), do: bag

  defp adjust_time(bag, value, 1) do
    %{
      counts: Map.update(bag.counts, value, 1, &(&1 + 1)),
      min: if(is_nil(bag.min), do: value, else: min(bag.min, value)),
      max: if(is_nil(bag.max), do: value, else: max(bag.max, value))
    }
  end

  defp adjust_time(bag, value, -1) do
    counts = adjust_count(bag.counts, value, -1)
    keys = Map.keys(counts)

    %{
      counts: counts,
      min: if(value == bag.min, do: Enum.min(keys, fn -> nil end), else: bag.min),
      max: if(value == bag.max, do: Enum.max(keys, fn -> nil end), else: bag.max)
    }
  end

  defp adjust_time_pair(bag, value, value), do: bag

  defp adjust_time_pair(bag, previous, current) do
    bag |> adjust_time(previous, -1) |> adjust_time(current, 1)
  end

  defp put_or_delete_empty(map, key, %{request_count: 0}), do: Map.delete(map, key)
  defp put_or_delete_empty(map, key, value), do: Map.put(map, key, value)

  defp put_or_delete_usage(map, key, %{request_count: 0}), do: Map.delete(map, key)
  defp put_or_delete_usage(map, key, acc), do: Map.put(map, key, usage_from_acc(acc))

  defp put_or_delete_model(map, key, %{request_count: 0}), do: Map.delete(map, key)

  defp put_or_delete_model(map, {provider, model} = key, acc),
    do: Map.put(map, key, %{provider: provider, model: model, usage: usage_from_acc(acc)})

  defp add_visits(projection, count),
    do: %{projection | historical_items_visited: projection.historical_items_visited + count}

  defp normalize_fact({:request_started, attrs}), do: {:request, request(attrs)}
  defp normalize_fact({:request_finished, attrs}), do: {:request, request(attrs)}
  defp normalize_fact({:request_usage, attrs}), do: {:request, request(attrs)}
  defp normalize_fact({:turn_started, attrs}), do: {:turn, turn(attrs, :running)}
  defp normalize_fact({:turn_finished, attrs}), do: {:turn, turn(attrs, :completed)}
  defp normalize_fact({:tool_finished, attrs}), do: {:tool, tool(attrs)}
  defp normalize_fact({:compaction, attrs}), do: {:compaction, compaction(attrs)}
  defp normalize_fact(%{kind: kind} = attrs), do: normalize_fact({kind, attrs})
  defp normalize_fact(%{"kind" => kind} = attrs), do: normalize_fact({kind, attrs})
  defp normalize_fact({"request_started", attrs}), do: normalize_fact({:request_started, attrs})
  defp normalize_fact({"request_finished", attrs}), do: normalize_fact({:request_finished, attrs})
  defp normalize_fact({"request_usage", attrs}), do: normalize_fact({:request_usage, attrs})
  defp normalize_fact({"turn_started", attrs}), do: normalize_fact({:turn_started, attrs})
  defp normalize_fact({"turn_finished", attrs}), do: normalize_fact({:turn_finished, attrs})
  defp normalize_fact({"tool_finished", attrs}), do: normalize_fact({:tool_finished, attrs})
  defp normalize_fact({"compaction", attrs}), do: normalize_fact({:compaction, attrs})
  defp normalize_fact(_), do: :ignore

  defp request(attrs) do
    %{
      request_id: attrs[:request_id] || attrs["request_id"],
      message_id: attrs[:message_id] || attrs["message_id"],
      session_id: attrs[:session_id] || attrs["session_id"],
      turn_id: attrs[:turn_id] || attrs["turn_id"],
      purpose: normalize_purpose(attrs[:purpose] || attrs["purpose"]),
      origin_session_id: attrs[:origin_session_id] || attrs["origin_session_id"],
      provider: attrs[:provider] || attrs["provider"],
      model: attrs[:model] || attrs["model"],
      revision: attrs[:revision] || attrs["revision"] || 0,
      status: normalize_status(attrs[:status] || attrs["status"]),
      started_at: attrs[:started_at] || attrs["started_at"],
      finished_at: attrs[:finished_at] || attrs["finished_at"],
      elapsed_ms: attrs[:elapsed_ms] || attrs["elapsed_ms"],
      input_tokens_total: attrs[:input_tokens_total] || attrs["input_tokens_total"],
      output_tokens_total: attrs[:output_tokens_total] || attrs["output_tokens_total"],
      cache_read_tokens: attrs[:cache_read_tokens] || attrs["cache_read_tokens"],
      cache_write_tokens: attrs[:cache_write_tokens] || attrs["cache_write_tokens"],
      reasoning_tokens: attrs[:reasoning_tokens] || attrs["reasoning_tokens"],
      visible_output_tokens: attrs[:visible_output_tokens] || attrs["visible_output_tokens"],
      first_output_ms: attrs[:first_output_ms] || attrs["first_output_ms"],
      ttft_ms: attrs[:ttft_ms] || attrs["ttft_ms"],
      usage_status: normalize_usage_status(attrs[:usage_status] || attrs["usage_status"]),
      provenance: attrs[:provenance] || attrs["provenance"],
      retry_of: attrs[:retry_of] || attrs["retry_of"]
    }
  end

  defp turn(attrs, default_status) do
    %{
      turn_id: attrs[:turn_id] || attrs["turn_id"],
      session_id: attrs[:session_id] || attrs["session_id"],
      revision: attrs[:revision] || attrs["revision"] || 0,
      status: normalize_status(attrs[:status] || attrs["status"] || default_status),
      started_at: attrs[:started_at] || attrs["started_at"],
      finished_at: attrs[:finished_at] || attrs["finished_at"],
      wall_time_ms: attrs[:wall_time_ms] || attrs["wall_time_ms"],
      terminal_reason: attrs[:terminal_reason] || attrs["terminal_reason"],
      source_message_id: attrs[:source_message_id] || attrs["source_message_id"],
      source_checkpoint_id: attrs[:source_checkpoint_id] || attrs["source_checkpoint_id"],
      retry_of_turn_id: attrs[:retry_of_turn_id] || attrs["retry_of_turn_id"],
      provenance: attrs[:provenance] || attrs["provenance"]
    }
  end

  defp tool(attrs),
    do: %{
      tool_id: attrs[:tool_id] || attrs["tool_id"],
      request_id: attrs[:request_id] || attrs["request_id"],
      revision: attrs[:revision] || attrs["revision"] || 0,
      status: normalize_status(attrs[:status] || attrs["status"]),
      elapsed_ms: attrs[:elapsed_ms] || attrs["elapsed_ms"],
      turn_id: attrs[:turn_id] || attrs["turn_id"],
      started_at: attrs[:started_at] || attrs["started_at"],
      finished_at: attrs[:finished_at] || attrs["finished_at"]
    }

  defp compaction(attrs),
    do: %{
      compaction_id: attrs[:compaction_id] || attrs["compaction_id"],
      status: attrs[:status] || attrs["status"],
      revision: attrs[:revision] || attrs["revision"] || 0,
      trigger: attrs[:trigger] || attrs["trigger"],
      source_leaf_id: attrs[:source_leaf_id] || attrs["source_leaf_id"],
      first_kept_id: attrs[:first_kept_id] || attrs["first_kept_id"],
      summary_id: attrs[:summary_id] || attrs["summary_id"],
      request_ids: attrs[:request_ids] || attrs["request_ids"],
      before_tokens: attrs[:before_tokens] || attrs["before_tokens"],
      after_tokens: attrs[:after_tokens] || attrs["after_tokens"],
      before_source: attrs[:before_source] || attrs["before_source"],
      after_source: attrs[:after_source] || attrs["after_source"],
      started_at: attrs[:started_at] || attrs["started_at"],
      finished_at: attrs[:finished_at] || attrs["finished_at"],
      failure_reason: attrs[:failure_reason] || attrs["failure_reason"]
    }

  defp normalize_status("started"), do: :started
  defp normalize_status("running"), do: :running
  defp normalize_status("completed"), do: :completed
  defp normalize_status("failed"), do: :failed
  defp normalize_status("cancelled"), do: :cancelled
  defp normalize_status("committed"), do: :committed
  defp normalize_status("interrupted"), do: :interrupted
  defp normalize_status("unknown"), do: :unknown
  defp normalize_status(status), do: status

  defp normalize_purpose("turn"), do: :turn
  defp normalize_purpose("compaction"), do: :compaction
  defp normalize_purpose("auxiliary"), do: :auxiliary
  defp normalize_purpose("sampling"), do: :sampling
  defp normalize_purpose(purpose), do: purpose

  defp normalize_usage_status("reported"), do: :reported
  defp normalize_usage_status("derived"), do: :derived
  defp normalize_usage_status("estimated"), do: :estimated
  defp normalize_usage_status("unknown"), do: :unknown
  defp normalize_usage_status(status), do: status
end
