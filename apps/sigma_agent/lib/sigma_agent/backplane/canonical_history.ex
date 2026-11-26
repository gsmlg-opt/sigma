defmodule Sigma.Agent.Backplane.CanonicalHistory do
  @moduledoc false

  # JSONL keeps host metadata inside Sigma messages. Runtime validates feedback
  # at the top level when seeding a fresh run; keep the original ID and content.
  def runtime_messages(messages),
    do: messages |> Enum.flat_map(&provider_messages/1) |> Enum.map(&runtime_message/1)

  def failed_message(%{message: %{role: :assistant} = message} = snapshot) do
    id = message[:id] || "msg_assistant_#{snapshot.failed_attempt.attempt_id}"
    metadata = Map.get(message, :metadata) || %{}

    metadata =
      metadata
      |> Map.put(:turn_id, snapshot.failed_attempt.run_id)
      |> Map.put(:provider_failure, %{
        failed_attempt: snapshot.failed_attempt,
        response_id: snapshot[:response_id],
        error: failure_reason(snapshot.error),
        retry: snapshot[:retry]
      })

    Sigma.Agent.Message.assistant(id, %{
      content: message.content,
      model: message[:model],
      provider: message[:provider],
      usage: message[:usage],
      timestamp: message[:timestamp] || System.system_time(:millisecond),
      response_id: snapshot[:response_id] || message[:response_id],
      stop_reason: :error,
      error_message: failure_reason(snapshot.error),
      metadata: metadata
    })
  end

  def failed_message(_snapshot), do: nil

  # Preserve original failed tool calls in the journal. They have no admitted
  # effects or results, so only textual content enters a replacement request.
  def provider_messages(%{role: :assistant, metadata: metadata} = message)
      when is_map(metadata) do
    if metadata[:provider_failure] || metadata["provider_failure"] do
      content =
        case message.content do
          text when is_binary(text) ->
            text

          blocks when is_list(blocks) ->
            Enum.filter(blocks, fn
              %{type: :text, text: text} -> is_binary(text) and String.valid?(text)
              %{type: :thinking, thinking: text} -> is_binary(text) and String.valid?(text)
              _ -> false
            end)
        end

      if content in [[], ""],
        do: [],
        else: [
          %{
            message
            | content: content,
              metadata: Map.drop(metadata, [:openai_responses_hosted, "openai_responses_hosted"])
          }
        ]
    else
      [message]
    end
  end

  def provider_messages(message), do: [message]

  defp failure_reason(%{message: message}) when is_binary(message), do: message
  defp failure_reason(error), do: inspect(error)

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
