defmodule Sigma.Agent.TurnState do
  @moduledoc "Pure active-turn lifecycle state."

  @active_phases [
    :streaming_provider,
    :running_tools,
    :waiting_permission,
    :waiting_elicitation,
    :cancelling,
    :session_operation
  ]

  @phases @active_phases ++ [:idle, :completed, :failed, :cancelled]

  defstruct [:turn_id, :cancellation_ref, :cancel_timer, :provider_retry, phase: :idle]

  def idle, do: %__MODULE__{}

  def start(turn_id, cancellation_ref) do
    %__MODULE__{
      turn_id: turn_id,
      cancellation_ref: cancellation_ref,
      phase: :streaming_provider
    }
  end

  def transition(%__MODULE__{} = turn, phase) when phase in @phases do
    retry =
      if phase == :streaming_provider and is_map(turn.provider_retry),
        do: %{turn.provider_retry | status: :requesting},
        else: nil

    %{turn | phase: phase, provider_retry: retry}
  end

  def active?(%__MODULE__{phase: phase}), do: phase in @active_phases
end
