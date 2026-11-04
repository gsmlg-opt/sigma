defmodule Sigma.Agent.Backplane.GoalHost do
  @moduledoc """
  Public Backplane Goal host callbacks supplied by trusted session integration.

  Reservation must only reserve ordinary admission, without dispatch, event
  persistence or synchronous calls back into the Goal coordinator. Release is
  called separately by the coordinator after `Goal.idle/2` has returned.
  Instruction recording must acknowledge canonical user provenance.

  Production release returns the actual gated Task PID and a host-owned atomic
  control cell: 0 prepares, 1 opens effects, 2 cancels, 3 supersedes and 4 seals.
  The coordinator monitors the executor before releasing it. Only pure hosted
  configuration precedes that gate; actual DOWN and a sealed no-effect entry
  permit public unstarted settlement. The Agent joins that acknowledgement
  before terminal events and never dispatches interrupt hooks for this path.
  """

  @behaviour Backplane.AgentRuntime.Goal.Host
  alias Backplane.AgentRuntime.Error

  @impl true
  def record_user_instruction(context, thread_id, instruction),
    do: invoke(context, :record_instruction, thread_id, instruction)

  @impl true
  def start_turn_if_idle(context, thread_id, request),
    do: invoke(context, :reserve_turn, thread_id, request)

  def release_turn(context, thread_id, admission),
    do: invoke(context, :release_turn, thread_id, admission)

  defp invoke(context, name, thread_id, input) do
    case Map.get(context, name) do
      function when is_function(function, 2) -> function.(thread_id, input)
      _ -> {:error, Error.new(:unsupported_capability, "goal host #{name} is unavailable")}
    end
  rescue
    _ -> {:error, Error.new(:execution_failure, "goal host #{name} failed")}
  catch
    :exit, _ -> {:error, Error.new(:execution_failure, "goal host #{name} unavailable")}
  end
end
