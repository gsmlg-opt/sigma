defmodule Sigma.Ai.ManagedCancellation do
  @moduledoc "Cancellation from acknowledged live MultiAgent interruptions, never from snapshot status."
  def key(session, run, incarnation), do: {:managed_child, session, run, incarnation}

  def observe(%{type: :interrupted, agent: agent}, listener, public_run) do
    metadata = agent[:host_metadata] || %{}
    session = metadata["child_session_id"] || metadata[:child_session_id]

    if is_binary(session) and is_binary(agent.run_id) and not is_nil(agent.incarnation) do
      Sigma.Ai.ResponsesCancellation.request(
        key(session, agent.run_id, agent.incarnation),
        {listener, %{turn_id: public_run.(agent.run_id), target: agent.name}}
      )
    end

    :ok
  end

  def observe(_, _, _), do: :ok
end
