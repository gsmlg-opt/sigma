defmodule Sigma.Agent.Terminals.Replay do
  @moduledoc "Pure snapshot-to-live replay decisions."

  alias Sigma.Agent.Terminals.{Error, Identity}

  @enforce_keys [:run, :earliest_sequence, :latest_sequence]
  defstruct [:run, :earliest_sequence, :latest_sequence, :checkpoint_sequence]

  @type t :: %__MODULE__{}

  @spec new(Identity.Run.t(), keyword()) :: t()
  def new(%Identity.Run{} = run, opts) do
    %__MODULE__{
      run: run,
      earliest_sequence: Keyword.fetch!(opts, :earliest_sequence),
      latest_sequence: Keyword.fetch!(opts, :latest_sequence),
      checkpoint_sequence: Keyword.get(opts, :checkpoint_sequence)
    }
  end

  @spec decide(t(), Identity.Run.t(), non_neg_integer()) :: tuple()
  def decide(%__MODULE__{run: run} = state, %Identity.Run{} = requested_run, rendered_sequence) do
    with :ok <- same_run(run, requested_run) do
      cond do
        rendered_sequence == state.latest_sequence ->
          {:live, state.latest_sequence + 1}

        rendered_sequence >= state.earliest_sequence - 1 and
            rendered_sequence < state.latest_sequence ->
          {:replay, (rendered_sequence + 1)..state.latest_sequence}

        is_integer(state.checkpoint_sequence) ->
          range =
            if state.checkpoint_sequence < state.latest_sequence,
              do: (state.checkpoint_sequence + 1)..state.latest_sequence,
              else: nil

          {:snapshot_then_replay, state.checkpoint_sequence, range}

        true ->
          {:error, Error.new(:snapshot_unavailable)}
      end
    end
  end

  defp same_run(run, run), do: :ok

  defp same_run(%Identity.Run{terminal: terminal}, %Identity.Run{terminal: terminal}),
    do: {:error, Error.new(:stale_run_generation)}

  defp same_run(_expected, _actual), do: {:error, Error.new(:stale_terminal)}
end
