defmodule Sigma.Agent.Terminals.ScreenStream do
  @moduledoc "Bounded, ordered output and coherent checkpoint state for one terminal run."

  alias Sigma.Agent.Terminals.{Error, Identity, Limits, OutputFrame, Replay}

  defstruct [
    :run,
    :limits,
    :checkpoint,
    next_sequence: 1,
    frames: [],
    replay_bytes: 0,
    dimensions: {120, 24},
    native_sequence: 0,
    degraded: nil,
    parser_tail: <<>>
  ]

  @type event ::
          OutputFrame.t() | %{run: Identity.Run.t(), sequence: pos_integer(), resize: tuple()}

  def new(%Identity.Run{} = run, %Limits{} = limits) do
    %__MODULE__{
      run: run,
      limits: limits,
      dimensions: {limits.initial_columns, limits.initial_rows}
    }
  end

  def append_output(%__MODULE__{} = stream, bytes) when is_binary(bytes) do
    append_output(stream, nil, bytes)
  end

  def append_output(%__MODULE__{} = stream, native_sequence, bytes)
      when is_binary(bytes) and (is_nil(native_sequence) or is_integer(native_sequence)) do
    with :ok <- validate_native_sequence(stream, native_sequence),
         {:ok, frame} <- OutputFrame.new(stream.run, stream.next_sequence, bytes, stream.limits),
         :ok <- parser_capacity(stream, bytes) do
      {tail, responses} = device_responses(stream.parser_tail <> bytes)

      stream =
        stream
        |> append(frame, byte_size(bytes))
        |> Map.put(:parser_tail, tail)
        |> maybe_put_native_sequence(native_sequence)

      {:ok, frame, responses, stream}
    end
  end

  def append_resize(%__MODULE__{} = stream, columns, rows) do
    event = %{run: stream.run, sequence: stream.next_sequence, resize: {columns, rows}}
    stream = stream |> append(event, 0) |> Map.put(:dimensions, {columns, rows})
    {:ok, event, stream}
  end

  def checkpoint(%__MODULE__{} = stream, bytes) when is_binary(bytes) do
    accept_checkpoint(stream, nil, elem(stream.dimensions, 0), elem(stream.dimensions, 1), bytes)
  end

  def accept_checkpoint(%__MODULE__{} = stream, native_sequence, columns, rows, bytes)
      when is_binary(bytes) do
    if byte_size(bytes) <= stream.limits.max_snapshot_bytes do
      healing? = is_integer(native_sequence) and not is_nil(stream.degraded)

      with :ok <- validate_checkpoint_sequence(stream, native_sequence) do
        sequence = if healing?, do: stream.next_sequence, else: stream.next_sequence - 1

        checkpoint = %{
          sequence: sequence,
          bytes: bytes,
          dimensions: {columns, rows},
          source_sequence: native_sequence
        }

        stream = %{
          stream
          | checkpoint: checkpoint,
            dimensions: {columns, rows},
            native_sequence: native_sequence || stream.native_sequence,
            degraded: nil,
            frames: if(healing?, do: [], else: stream.frames),
            replay_bytes: if(healing?, do: 0, else: stream.replay_bytes),
            next_sequence: if(healing?, do: stream.next_sequence + 1, else: stream.next_sequence)
        }

        {:ok, stream}
      end
    else
      {:error,
       Error.new(:snapshot_unavailable, %{
         reason: :snapshot_too_large,
         maximum_bytes: stream.limits.max_snapshot_bytes
       })}
    end
  end

  def mark_gap(%__MODULE__{} = stream, expected, actual) do
    %{stream | degraded: %{reason: :sequence_gap, expected: expected, actual: actual}}
  end

  def delivery(%__MODULE__{} = stream, %Identity.Run{} = run, rendered_sequence) do
    replay =
      Replay.new(stream.run,
        earliest_sequence: earliest_sequence(stream),
        latest_sequence: stream.next_sequence - 1,
        checkpoint_sequence: stream.checkpoint && stream.checkpoint.sequence
      )

    with decision <- Replay.decide(replay, run, rendered_sequence),
         {:ok, delivery} <- materialize(stream, decision) do
      {:ok, delivery}
    end
  end

  defp append(stream, event, bytes) do
    stream = %{
      stream
      | frames: stream.frames ++ [event],
        replay_bytes: stream.replay_bytes + bytes,
        next_sequence: stream.next_sequence + 1
    }

    trim(stream)
  end

  defp trim(%{replay_bytes: bytes, limits: %{max_raw_replay_bytes: maximum}} = stream)
       when bytes > maximum do
    case stream.frames do
      [%OutputFrame{bytes: dropped} | rest] ->
        trim(%{stream | frames: rest, replay_bytes: bytes - byte_size(dropped)})

      [_resize | rest] ->
        trim(%{stream | frames: rest})

      [] ->
        %{stream | replay_bytes: 0}
    end
  end

  defp trim(stream), do: invalidate_gapped_checkpoint(stream)

  defp invalidate_gapped_checkpoint(%{checkpoint: %{sequence: sequence}} = stream) do
    if earliest_sequence(stream) > sequence + 1, do: %{stream | checkpoint: nil}, else: stream
  end

  defp invalidate_gapped_checkpoint(stream), do: stream

  defp earliest_sequence(%{frames: [frame | _]}), do: frame.sequence
  defp earliest_sequence(%{next_sequence: next}), do: next

  defp materialize(_stream, {:error, error}), do: {:error, error}

  defp materialize(_stream, {:live, next}),
    do: {:ok, %{mode: :live, next_sequence: next, events: []}}

  defp materialize(stream, {:replay, range}) do
    {:ok, %{mode: :replay, events: events(stream, range)}}
  end

  defp materialize(stream, {:snapshot_then_replay, sequence, range}) do
    case stream.checkpoint do
      %{sequence: ^sequence} = snapshot ->
        {:ok, %{mode: :snapshot_then_replay, snapshot: snapshot, events: events(stream, range)}}

      _ ->
        {:error, Error.new(:snapshot_unavailable)}
    end
  end

  defp events(_stream, first..last//_step) when first > last, do: []
  defp events(_stream, nil), do: []
  defp events(stream, range), do: Enum.filter(stream.frames, &(&1.sequence in range))

  defp validate_native_sequence(_stream, nil), do: :ok

  defp validate_native_sequence(stream, sequence) when sequence == stream.native_sequence + 1,
    do: :ok

  defp validate_native_sequence(stream, sequence) when sequence <= stream.native_sequence,
    do: {:error, Error.new(:snapshot_unavailable, %{reason: :stale_output, sequence: sequence})}

  defp validate_native_sequence(stream, sequence),
    do:
      {:error,
       Error.new(:snapshot_unavailable, %{
         reason: :sequence_gap,
         expected: stream.native_sequence + 1,
         actual: sequence
       })}

  defp validate_checkpoint_sequence(_stream, nil), do: :ok

  defp validate_checkpoint_sequence(%{degraded: nil} = stream, sequence)
       when sequence == stream.native_sequence and is_integer(sequence),
       do: :ok

  defp validate_checkpoint_sequence(%{degraded: degraded} = stream, sequence)
       when not is_nil(degraded) and sequence >= stream.native_sequence and is_integer(sequence),
       do: :ok

  defp validate_checkpoint_sequence(stream, sequence),
    do:
      {:error,
       Error.new(:snapshot_unavailable, %{
         reason: :stale_checkpoint,
         expected: stream.native_sequence,
         actual: sequence
       })}

  defp maybe_put_native_sequence(stream, nil), do: stream
  defp maybe_put_native_sequence(stream, sequence), do: %{stream | native_sequence: sequence}

  defp parser_capacity(stream, bytes) do
    if byte_size(stream.parser_tail) + byte_size(bytes) <= stream.limits.max_parser_backlog_bytes,
      do: :ok,
      else:
        {:error, Error.new(:capacity_exhausted, %{resource: :parser_backlog}, retryable: true)}
  end

  # Device status queries are parsed once on the server stream. Replay never enters this path.
  defp device_responses(bytes) do
    parts = :binary.split(bytes, <<27, "[5n">>, [:global])
    count = length(parts) - 1
    tail_source = List.last(parts)
    tail = ansi_prefix(tail_source)
    {tail, List.duplicate(<<27, "[0n">>, count)}
  end

  defp ansi_prefix(bytes) do
    cond do
      String.ends_with?(bytes, <<27, "[5">>) -> <<27, "[5">>
      String.ends_with?(bytes, <<27, "[">>) -> <<27, "[">>
      String.ends_with?(bytes, <<27>>) -> <<27>>
      true -> <<>>
    end
  end
end
