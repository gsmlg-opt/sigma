defmodule Sigma.Agent.Backplane.ContextControls do
  @moduledoc false

  alias Sigma.Agent.ContextPolicy

  @timeout 5_000

  def request(owner, kind, run_id) do
    ref = make_ref()
    monitor = Process.monitor(owner)
    send(owner, {:backplane_context_control, self(), ref, kind, run_id})

    try do
      receive do
        {:backplane_context_control, ^ref, result} -> result
        {:DOWN, ^monitor, :process, ^owner, _reason} -> nil
      after
        @timeout -> nil
      end
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  def window(
        %{run: %{run_id: run_id, incarnation: incarnation}, conversation: conversation},
        run_id
      ) do
    %{run_id: run_id, incarnation: incarnation, window: Map.get(conversation, :context_window, 1)}
  end

  def window(_status, _run_id), do: nil

  def tokens_left(snapshot, opts) do
    policy = ContextPolicy.policy(snapshot, opts)
    reserve = Keyword.get(opts, :output_reserve)

    if snapshot.stale == false and snapshot.estimate_coverage == :complete and
         is_integer(reserve) and reserve >= 0 and is_integer(policy.context_window) and
         is_integer(policy.tokens_remaining) and is_integer(policy.hard_tokens_remaining) do
      min(policy.tokens_remaining, policy.hard_tokens_remaining)
    end
  end
end
