defmodule Sigma.Agent.Backplane.CanonicalHistory do
  @moduledoc false

  # JSONL keeps host metadata inside Sigma messages. Runtime validates feedback
  # at the top level when seeding a fresh run; keep the original ID and content.
  def runtime_messages(messages), do: Enum.map(messages, &runtime_message/1)

  def checkpoint_messages(%{conversation: conversation}) do
    conversation
    |> Map.get(:host_feedback, [])
    |> Enum.map(fn record ->
      %{
        role: :user,
        content: "[Host feedback] #{record["source"]} / #{record["stage"]}\n#{record["text"]}",
        host_feedback: Map.delete(record, "projected")
      }
    end)
  end

  defp runtime_message(%{role: :user, metadata: metadata} = message) do
    case Map.get(metadata, :host_feedback, Map.get(metadata, "host_feedback")) do
      nil ->
        message

      feedback ->
        message
        |> Map.take([:id, :role, :content, :timestamp, :metadata])
        |> Map.put(:host_feedback, feedback)
    end
  end

  defp runtime_message(message), do: message
end
