defmodule Sigma.Agent.MessageTransformer do
  @moduledoc """
  Transforms `Sigma.Agent.Message` to `Sigma.Ai.Message`.
  """

  alias Sigma.Agent.Message, as: AgentMessage
  alias Sigma.Ai.Message, as: AiMessage

  @doc """
  Applies a sequence of transformations to the message list.

  This is a composition slot in the agent loop to prepare the context
  before `convert_to_llm/1` is called.

  ## Options
    * `:transforms` - A list of functions that each take a list of messages
      and return a new list of messages. Applied sequentially.
  """
  @spec transform_context([AgentMessage.t()], keyword()) :: [AgentMessage.t()]
  def transform_context(messages, opts \\ []) do
    transforms = Keyword.get(opts, :transforms, [])

    Enum.reduce(transforms, messages, fn transform, acc ->
      transform.(acc)
    end)
  end

  @doc """
  Removes redacted messages from the list.
  """
  @spec prune_redacted([AgentMessage.t()]) :: [AgentMessage.t()]
  def prune_redacted(messages) do
    Enum.reject(messages, & &1.redacted)
  end

  @doc """
  Injects a system message at the beginning of the list.
  """
  @spec inject_system([AgentMessage.t()], String.t()) :: [AgentMessage.t()]
  def inject_system(messages, content) do
    id = "system-#{DateTime.to_unix(DateTime.utc_now(), :microsecond)}"
    [AgentMessage.system(id, content) | messages]
  end

  @doc """
  Truncates the message list to the last `n` messages.
  """
  @spec truncate_context([AgentMessage.t()], integer()) :: [AgentMessage.t()]
  def truncate_context(messages, n) do
    Enum.take(messages, -n)
  end

  @doc """
  Converts a list of `Sigma.Agent.Message` to a list of `Sigma.Ai.Message`.

  It performs the following transformations:
  - Filters out messages with `redacted: true`.
  - Filters out UI-only messages (e.g., `:status`, `:notification`).
  - Merges consecutive `:thought` messages into the following `:assistant` message as thinking blocks.
  - Drops `:thought` messages that are not followed by an `:assistant` message.
  - Maps `:user`, `:assistant`, and `:tool_result` roles to `Sigma.Ai.Message` roles.
  - Ensures content formats are compatible with `Sigma.Ai.Message`.
  """
  @spec convert_to_llm([AgentMessage.t()]) :: [AiMessage.t()]
  def convert_to_llm(messages) when is_list(messages) do
    messages
    |> Enum.reject(& &1.redacted)
    |> Enum.reduce([], fn msg, acc ->
      case msg.role do
        :system ->
          [convert_system(msg) | acc]

        :user ->
          [convert_user(msg) | acc]

        :assistant ->
          {thoughts, rest} = take_thoughts(acc)
          [merge_assistant(msg, thoughts) | rest]

        :tool_result ->
          [convert_tool_result(msg) | acc]

        :thought ->
          [msg | acc]

        :compaction_summary ->
          [convert_compaction_summary(msg) | acc]

        # UI-only and other roles are dropped by default
        _ ->
          acc
      end
    end)
    |> Enum.reject(fn
      %AgentMessage{role: :thought} -> true
      _ -> false
    end)
    |> Enum.reverse()
  end

  defp take_thoughts(acc) do
    Enum.split_while(acc, fn
      %AgentMessage{role: :thought} -> true
      _ -> false
    end)
  end

  defp convert_system(msg) do
    %{
      role: :system,
      content: msg.content,
      timestamp: msg.timestamp
    }
  end

  defp convert_user(msg) do
    %{
      role: :user,
      content: msg.content,
      timestamp: msg.timestamp
    }
  end

  defp convert_tool_result(msg) do
    content =
      case msg.content do
        content when is_binary(content) ->
          [%{type: :text, text: content}]

        content when is_list(content) ->
          content

        nil ->
          []
      end

    %{
      role: :tool_result,
      tool_call_id: msg.tool_call_id,
      tool_name: msg.tool_name,
      content: content,
      is_error: msg.is_error || false,
      timestamp: msg.timestamp
    }
  end

  defp merge_assistant(msg, thoughts) do
    thought_blocks =
      thoughts
      |> Enum.reverse()
      |> Enum.map(fn t ->
        %{
          type: :thinking,
          thinking: t.content,
          redacted: false
        }
      end)

    original_content =
      case msg.content do
        content when is_binary(content) ->
          [%{type: :text, text: content}]

        content when is_list(content) ->
          content

        nil ->
          []
      end

    %{
      role: :assistant,
      content: thought_blocks ++ original_content,
      api: msg.api,
      provider: msg.provider,
      model: msg.model,
      response_model: msg.response_model,
      response_id: msg.response_id,
      usage: msg.usage || empty_usage(),
      stop_reason: msg.stop_reason,
      error_message: msg.error_message,
      timestamp: msg.timestamp
    }
  end

  # Compaction summaries are sent as assistant messages so the sequence is:
  # assistant(summary) → user(first kept prompt) → assistant → ...
  # which is a valid alternating order for all providers.
  defp convert_compaction_summary(msg) do
    %{
      role: :assistant,
      content: [%{type: :text, text: "[Summary of earlier conversation]\n\n#{msg.content}"}],
      api: nil,
      provider: nil,
      model: nil,
      response_model: nil,
      response_id: nil,
      usage: empty_usage(),
      stop_reason: "end_turn",
      error_message: nil,
      timestamp: msg.timestamp
    }
  end

  defp empty_usage do
    %{
      input: 0,
      output: 0,
      cache_read: 0,
      cache_write: 0,
      total_tokens: 0,
      cost: %{
        input: 0.0,
        output: 0.0,
        cache_read: 0.0,
        cache_write: 0.0,
        total: 0.0
      }
    }
  end
end
