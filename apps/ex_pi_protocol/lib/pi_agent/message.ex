defmodule PiAgent.Message do
  @moduledoc """
  Rich domain type for messages within the agent loop.

  Mirrors `PiAi.Message` but adds:
  - `id`: A unique identifier for the message in the conversation.
  - `metadata`: Arbitrary map for UI hints, tracing, etc.
  - `redacted`: Whether the message content is hidden from the LLM.
  - `attachments`: Support for UI-level attachments.
  - Custom roles: `:thought`, `:status`, `:notification`, etc.
  """

  @type id :: String.t()

  @type role ::
          PiAi.Message.role()
          | :thought
          | :status
          | :notification
          | :branch_summary
          | :compaction_summary
          | :bash_execution
          | :artifact

  defstruct [
    :id,
    :role,
    :content,
    :timestamp,
    :api,
    :provider,
    :model,
    :response_model,
    :response_id,
    :usage,
    :stop_reason,
    :error_message,
    :tool_call_id,
    :tool_name,
    :is_error,
    :attachments,
    :status_type,
    :level,
    :from_id,
    :tokens_before,
    :command,
    :exit_code,
    :summary,
    metadata: %{},
    redacted: false
  ]

  @type t :: %__MODULE__{
          id: id(),
          role: role(),
          content: any(),
          timestamp: integer(),
          metadata: map(),
          redacted: boolean(),
          api: String.t() | nil,
          provider: String.t() | nil,
          model: String.t() | nil,
          response_model: String.t() | nil,
          response_id: String.t() | nil,
          usage: PiAi.Message.usage() | nil,
          stop_reason: PiAi.Message.stop_reason() | nil,
          error_message: String.t() | nil,
          tool_call_id: String.t() | nil,
          tool_name: String.t() | nil,
          is_error: boolean() | nil,
          attachments: [any()] | nil,
          status_type: atom() | nil,
          level: :info | :warning | :error | nil,
          from_id: String.t() | nil,
          tokens_before: integer() | nil,
          command: String.t() | nil,
          exit_code: integer() | nil,
          summary: String.t() | nil
        }

  @doc """
  New system message.
  """
  def system(id, content, timestamp \\ DateTime.to_unix(DateTime.utc_now(), :millisecond)) do
    %__MODULE__{
      id: id,
      role: :system,
      content: content,
      timestamp: timestamp,
      metadata: %{}
    }
  end

  @doc """
  New user message.
  """
  def user(id, content, timestamp \\ DateTime.to_unix(DateTime.utc_now(), :millisecond)) do
    %__MODULE__{
      id: id,
      role: :user,
      content: content,
      timestamp: timestamp,
      metadata: %{}
    }
  end

  @doc """
  New assistant message.
  """
  def assistant(id, params) do
    struct(__MODULE__, Map.merge(params, %{id: id, role: :assistant}))
  end

  @doc """
  New tool result message.
  """
  def tool_result(id, params) do
    struct(__MODULE__, Map.merge(params, %{id: id, role: :tool_result}))
  end

  @doc """
  New thought message.
  """
  def thought(id, content, timestamp \\ DateTime.to_unix(DateTime.utc_now(), :millisecond)) do
    %__MODULE__{
      id: id,
      role: :thought,
      content: content,
      timestamp: timestamp,
      metadata: %{}
    }
  end

  @doc """
  New status message.
  """
  def status(
        id,
        content,
        status_type \\ nil,
        timestamp \\ DateTime.to_unix(DateTime.utc_now(), :millisecond)
      ) do
    %__MODULE__{
      id: id,
      role: :status,
      content: content,
      status_type: status_type,
      timestamp: timestamp,
      metadata: %{}
    }
  end

  @doc """
  New notification message.
  """
  def notification(
        id,
        content,
        level \\ :info,
        timestamp \\ DateTime.to_unix(DateTime.utc_now(), :millisecond)
      ) do
    %__MODULE__{
      id: id,
      role: :notification,
      content: content,
      level: level,
      timestamp: timestamp,
      metadata: %{}
    }
  end
end
