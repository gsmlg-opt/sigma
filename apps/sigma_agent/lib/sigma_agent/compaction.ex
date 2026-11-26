defmodule Sigma.Agent.Compaction do
  @moduledoc false

  alias Sigma.Agent.ContextPolicy
  alias Sigma.Ai.{Provider, ProviderError, ProviderEvent, ProviderRequest, ProviderUsage}

  # Compaction changes only the Provider projection. Callers own journal commits,
  # hooks, cancellation and request metrics at their existing session boundaries.
  def estimate(messages),
    do: ContextPolicy.snapshot(messages: messages).next_request_estimated_input_tokens

  def split(messages, keep_budget, project) do
    message_count = length(messages)

    {boundaries, pending} =
      messages
      |> Enum.with_index()
      |> Enum.reduce({[], MapSet.new()}, fn {message, index}, {boundaries, pending} ->
        boundaries =
          if index > 0 and MapSet.size(pending) == 0 and message.role != :tool_result,
            do: [index | boundaries],
            else: boundaries

        # Keep the cut anchored to the original journal message, including
        # when its projection is empty or prepends a continuation notice.
        pending =
          case project.(message) do
            [%{role: :assistant, content: content}] when is_list(content) ->
              Enum.reduce(content, pending, fn
                %{type: :tool_call, id: id}, calls -> MapSet.put(calls, id)
                _block, calls -> calls
              end)

            [%{role: :tool_result, tool_call_id: id}] ->
              MapSet.delete(pending, id)

            _ ->
              pending
          end

        {boundaries, pending}
      end)

    boundaries =
      if message_count > 1 and MapSet.size(pending) == 0 and
           List.last(messages).role != :user,
         do: [message_count | boundaries],
         else: boundaries

    boundary =
      boundaries
      |> Enum.reverse()
      |> Enum.find(fn index ->
        kept = messages |> Enum.drop(index) |> Enum.flat_map(project)
        estimate(kept) <= keep_budget
      end)

    if boundary, do: Enum.split(messages, boundary), else: {[], messages}
  end

  def summarize(messages, state, opts \\ []) do
    state = Map.put(state, :on_activity, Keyword.get(opts, :on_activity))

    transcript =
      messages
      |> Enum.reject(fn m -> m.role in [:status, :notification] end)
      |> Enum.map_join("\n\n---\n\n", fn msg ->
        label =
          case msg.role do
            :user -> "User"
            :assistant -> "Assistant"
            :tool_result -> "Tool (#{msg.tool_name})"
            :compaction_summary -> "Previous summary"
            r -> to_string(r)
          end

        text =
          case msg.content do
            s when is_binary(s) ->
              s

            blocks when is_list(blocks) ->
              Enum.map_join(blocks, "\n", fn
                %{type: :text, text: t} -> t
                %{type: :thinking, thinking: t} -> "[thinking: #{t}]"
                %{"type" => "text", "text" => t} -> t
                b -> inspect(b)
              end)

            nil ->
              ""
          end

        "#{label}: #{text}"
      end)

    window = state.context_window || 100_000

    output_limit =
      Provider.output_token_limit(state.provider, state.model, state.provider_options)

    output_limit = min(output_limit || max(1, div(window, 8)), max(1, div(window, 8)))
    output_limit = min(output_limit, Keyword.get(opts, :summary_output_limit, output_limit))
    summarize_transcript(state, transcript, "", [], window, output_limit)
  end

  defp summarize_transcript(state, "", summary, request_ids, _window, _output_limit) do
    if summary_cancelled?(state),
      do: {:error, ProviderError.from_reason(:cancelled), request_ids},
      else: {:ok, summary, request_ids}
  end

  defp summarize_transcript(state, transcript, summary, request_ids, window, output_limit) do
    overhead = ContextPolicy.snapshot(messages: [summary_message("", summary)])
    available = window - output_limit - overhead.next_request_estimated_input_tokens - 32

    cond do
      summary_cancelled?(state) ->
        {:error, ProviderError.from_reason(:cancelled), request_ids}

      available > 0 ->
        {chunk, rest} = split_summary_chunk(transcript, available * 4)

        case request_summary(state, summary_message(chunk, summary), output_limit) do
          {:ok, result, attempts} when byte_size(result) > 0 ->
            summarize_transcript(
              state,
              rest,
              result,
              request_ids ++ attempts,
              window,
              output_limit
            )

          {:ok, _empty, attempts} ->
            {:error, :empty_summary, request_ids ++ attempts}

          {:error, reason, attempts} ->
            {:error, reason, request_ids ++ attempts}
        end

      true ->
        {:error, ProviderError.from_exception("context token limit exceeded during compaction"),
         request_ids}
    end
  end

  defp summary_cancelled?(state), do: state.cancelled?.()

  defp split_summary_chunk(text, size) when byte_size(text) <= size, do: {text, ""}

  defp split_summary_chunk(text, size) do
    <<chunk::binary-size(^size), rest::binary>> = text
    if String.valid?(chunk), do: {chunk, rest}, else: split_summary_chunk(text, size - 1)
  end

  defp summary_message(transcript, previous_summary) do
    prompt = """
    Create a detailed summary of the following coding session transcript. Preserve all important information: files read and their key content, files edited and what changed, commands run and their output, decisions made and why, and the current state of any work in progress.

    Incorporate the previous summary into the updated summary. Preserve the user's current task and all unfinished work so execution can continue from this summary.

    <previous_summary>
    #{previous_summary}
    </previous_summary>

    <transcript>
    #{transcript}
    </transcript>

    Reply with the summary only.
    """

    %{role: :user, content: [%{type: :text, text: prompt}]}
  end

  defp request_summary(state, message, output_limit) do
    retry_summary(state, message, output_limit, 0, [])
  end

  defp retry_summary(state, message, output_limit, retries, ids) do
    case request_summary_once(state, message, output_limit, List.last(ids)) do
      {:ok, text, id} ->
        {:ok, text, ids ++ [id]}

      {:error, reason, id} ->
        ids = ids ++ [id]

        if retries < 5 and Keyword.get(state.provider_options, :retry) != false and
             is_map(reason) and Map.get(reason, :retry_class) in [:connection, :stream] do
          delay = summary_retry_delay(state.provider_options, reason, retries)

          case wait_summary_retry(state, delay) do
            :ok -> retry_summary(state, message, output_limit, retries + 1, ids)
            :cancelled -> {:error, ProviderError.from_reason(:cancelled), ids}
          end
        else
          {:error, reason, ids}
        end
    end
  end

  defp summary_retry_delay(options, error, retries) do
    base = if error.retry_class == :connection, do: 5_000, else: 200
    fallback = min(base * Integer.pow(2, retries), 60_000)

    delay =
      case Keyword.get(options, :retry_delay) do
        fun when is_function(fun, 1) -> fun.(retries)
        ms when is_integer(ms) and ms >= 0 -> ms
        _ -> fallback
      end

    max(delay, Map.get(error, :retry_after_ms) || 0)
  end

  defp wait_summary_retry(state, delay) do
    cond do
      summary_cancelled?(state) ->
        :cancelled

      delay <= 0 ->
        :ok

      true ->
        elapsed = min(delay, 25)
        Process.sleep(elapsed)
        wait_summary_retry(state, delay - elapsed)
    end
  end

  defp request_summary_once(state, message, output_limit, retry_of) do
    params = %{
      model: state.model,
      session_id: state.session_id,
      log_session_id: state.log_session_id,
      turn_id: state.turn_id,
      purpose: :compaction,
      retry_of: retry_of,
      context: %{
        messages: [message],
        system_prompt: nil,
        tools: []
      },
      options: Keyword.put(state.provider_options, :max_tokens, output_limit)
    }

    request =
      params
      |> Map.put(:origin_session_id, state.session_id)
      |> ProviderRequest.new()
      |> ProviderRequest.begin(System.monotonic_time(:millisecond), DateTime.utc_now())

    state.emit.(:request_started, request, nil)
    meter_summary_request(state, request)
  end

  defp meter_summary_request(state, request) do
    {text, request, status, reason} =
      state.provider
      |> Provider.stream(request)
      |> Enum.reduce_while({"", request, nil, nil}, fn event, acc ->
        renew_activity(state, event)
        reduce_summary_event(event, acc)
      end)

    status = status || :failed

    finished =
      ProviderRequest.finish(
        request,
        status,
        System.monotonic_time(:millisecond),
        DateTime.utc_now()
      )

    state.emit.(:request_finished, finished, if(status == :completed, do: nil, else: reason))

    if status == :completed,
      do: {:ok, text, request.request_id},
      else: {:error, reason || :stream_ended_without_terminal, request.request_id}
  rescue
    exception ->
      finished =
        ProviderRequest.finish(
          request,
          :failed,
          System.monotonic_time(:millisecond),
          DateTime.utc_now()
        )

      state.emit.(:request_finished, finished, exception)

      {:error, ProviderError.from_exception(exception), request.request_id}
  catch
    kind, reason ->
      finished =
        ProviderRequest.finish(
          request,
          :failed,
          System.monotonic_time(:millisecond),
          DateTime.utc_now()
        )

      state.emit.(:request_finished, finished, {kind, reason})

      {:error, ProviderError.from_exception({kind, reason}), request.request_id}
  end

  defp renew_activity(%{on_activity: on_activity} = state, %ProviderEvent{type: type})
       when is_function(on_activity, 0) and type != :response_failed do
    if summary_cancelled?(state), do: throw(:cancelled)

    case on_activity.() do
      :ok -> :ok
      error -> throw({:provider_activity_rejected, error})
    end
  end

  defp renew_activity(_state, _event), do: :ok

  defp reduce_summary_event(
         %ProviderEvent{type: :content_text_delta},
         {text, request, status, reason}
       ) do
    request = ProviderRequest.mark_output(request, System.monotonic_time(:millisecond), :text)
    {:cont, {text, request, status, reason}}
  end

  defp reduce_summary_event(%ProviderEvent{type: :content_thinking_delta}, acc) do
    {text, request, status, reason} = acc
    request = ProviderRequest.mark_output(request, System.monotonic_time(:millisecond), :thinking)
    {:cont, {text, request, status, reason}}
  end

  defp reduce_summary_event(%ProviderEvent{type: :usage_updated, usage: usage}, acc) do
    {text, request, status, reason} = acc
    {:cont, {text, put_request_usage(request, usage), status, reason}}
  end

  defp reduce_summary_event(
         %ProviderEvent{type: :response_completed, message: message, usage: usage},
         {_text, request, _status, _reason}
       ) do
    text = summary_message_text(message)
    request = put_request_usage(request, usage || ProviderUsage.from_map(message[:usage]))

    request =
      if text == "",
        do: request,
        else: ProviderRequest.mark_output(request, System.monotonic_time(:millisecond), :text)

    {:halt, {text, request, :completed, nil}}
  end

  defp reduce_summary_event(
         %ProviderEvent{type: :response_failed, error: error, usage: usage},
         {text, request, _, _}
       ) do
    status = if match?(%ProviderError{kind: :cancelled}, error), do: :cancelled, else: :failed
    {:halt, {text, put_request_usage(request, usage), status, error}}
  end

  defp reduce_summary_event(_event, acc), do: {:cont, acc}

  defp summary_message_text(%{content: blocks}) when is_list(blocks) do
    Enum.map_join(blocks, "", fn
      %{type: :text, text: text} -> text
      _block -> ""
    end)
  end

  defp summary_message_text(%{content: text}) when is_binary(text), do: text
  defp summary_message_text(_message), do: ""

  defp put_request_usage(request, %ProviderUsage{} = usage),
    do: ProviderRequest.put_usage(request, usage)

  defp put_request_usage(request, _usage), do: request
end
