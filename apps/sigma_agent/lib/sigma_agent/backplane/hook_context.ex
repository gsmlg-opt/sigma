defmodule Sigma.Agent.Backplane.HookContext do
  @moduledoc false

  alias Backplane.AgentRuntime.Error

  # Runtime owns correlation, checkpointing, projection and producer fencing.
  # Keep identity independent of feedback text and mutable tool arguments so a
  # conflicting retry cannot create a second canonical record.
  def deliver(context, invocation, text, stage) when is_binary(text) do
    with :ok <- append(context, invocation, text, stage) do
      observe(context, invocation, text)
    end
  end

  defp append(%{append_feedback: append}, invocation, text, stage)
       when is_function(append, 1) do
    identity = {invocation.invocation_id, stage}
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(identity))
    id = "sigma-hook-" <> Base.url_encode64(digest, padding: false)

    case append.(%{id: id, text: text, source: "sigma.hooks", stage: stage}) do
      {:ok, %{id: ^id, store_mode: mode}} when mode in [:durable, :ephemeral] -> :ok
      {:error, %Error{}} = error -> error
      _ -> {:error, Error.new(:malformed_result, "invalid Runtime hook feedback receipt")}
    end
  end

  defp append(%{on_hook_context: sink}, _invocation, _text, _stage)
       when is_function(sink, 2),
       do: :ok

  defp append(_context, _invocation, _text, _stage),
    do:
      {:error,
       Error.new(
         :unsupported_capability,
         "tool hook context requires Runtime feedback or an explicit sink"
       )}

  # A supplied compatibility sink remains observable and can refuse preparation.
  # If Runtime already accepted the feedback, observer failure cannot roll that
  # committed history back. No observer runs when Runtime acceptance fails.
  defp observe(%{on_hook_context: sink}, invocation, text) when is_function(sink, 2) do
    case sink.(invocation, text) do
      :ok -> :ok
      {:error, %Error{}} = error -> error
      _ -> {:error, Error.new(:malformed_result, "invalid tool hook context sink result")}
    end
  end

  defp observe(_context, _invocation, _text), do: :ok
end
