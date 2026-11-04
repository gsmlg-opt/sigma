defmodule Sigma.Ai.ResponsesRecovery do
  @moduledoc "In-process checkpoints for explicitly negotiated background Responses streams."

  alias Sigma.Ai.ProviderError

  def new(options) do
    if options[:response_id] || options[:starting_after], do: invalid!(:cold_resume_unsupported)

    if Keyword.has_key?(options, :background) and options[:background] not in [true, false],
      do: invalid!(:invalid_background)

    case options[:responses_recovery] do
      value when value in [nil, false] ->
        nil

      %{capability: :openai_background_stream_v1} = config ->
        unless options[:background] == true, do: invalid!(:background_required)

        %{
          id: nil,
          cursor: nil,
          attempts: 0,
          max_attempts: bounded!(config, :max_attempts, 3, 1, 10),
          delay_ms: bounded!(config, :delay_ms, 250, 0, 5_000),
          deadline:
            System.monotonic_time(:millisecond) +
              bounded!(config, :max_elapsed_ms, 120_000, 1, 600_000)
        }

      _ ->
        invalid!(:unverified_recovery_capability)
    end
  end

  defp bounded!(config, key, default, min, max) do
    value = Map.get(config, key, default)
    if is_integer(value) and value >= min and value <= max, do: value, else: invalid!(key)
  end

  defp invalid!(reason),
    do:
      raise(ProviderError,
        kind: :invalid_request,
        message: "Responses recovery: #{reason}",
        retryable: false
      )

  def accept(nil, _event), do: {:apply, nil}
  def accept(state, %{"type" => "keepalive"}), do: {:skip, state}

  def accept(state, %{"sequence_number" => cursor} = event)
      when is_integer(cursor) and cursor >= 0 do
    id = get_in(event, ["response", "id"])

    cond do
      is_binary(id) and not is_nil(state.id) and id != state.id ->
        {:error, error(state, :response_id_changed)}

      state.id == nil and
          (not is_binary(id) or id == "" or get_in(event, ["response", "background"]) != true) ->
        {:error, error(state, :background_response_not_confirmed)}

      not is_nil(state.cursor) and cursor <= state.cursor ->
        {:skip, state}

      true ->
        {:apply, %{state | id: state.id || id, cursor: cursor}}
    end
  end

  # Malformed data and terminal/error sentinels must reach the protocol reducer,
  # but never advance a durable-event cursor.
  def accept(state, {:provider_error, _}), do: {:apply, state}
  def accept(state, :done), do: {:apply, state}
  def accept(state, _event), do: {:error, error(state, :missing_sequence_number)}

  def next_attempt(nil), do: {:error, :disabled}

  def next_attempt(state) do
    cond do
      is_nil(state.id) or is_nil(state.cursor) ->
        {:error, error(state, :no_checkpoint)}

      state.attempts >= state.max_attempts ->
        {:error, error(state, :attempts_exhausted)}

      System.monotonic_time(:millisecond) >= state.deadline ->
        {:error, error(state, :recovery_expired)}

      true ->
        {:ok, %{state | attempts: state.attempts + 1}}
    end
  end

  def error(state, reason) do
    %ProviderError{
      kind: :stream_interrupted,
      retryable: false,
      message: "Responses recovery stopped: #{reason}. No new response was created.",
      raw: %{reason: reason, response_id: state.id, starting_after: state.cursor}
    }
  end

  def delay(state), do: min(state.delay_ms * Integer.pow(2, state.attempts - 1), 5_000)

  def cancelled(nil), do: ProviderError.from_reason(:cancelled)

  def cancelled(state) do
    %{
      ProviderError.from_reason(:cancelled)
      | message:
          "Local response stream cancelled. The background response may still run upstream.",
        raw: %{response_id: state.id, starting_after: state.cursor, upstream_cancelled: false}
    }
  end
end
