defmodule PiAgent.Event do
  @moduledoc """
  Defines agent-level events for UI updates and tracing.

  These events are distinct from `PiAi.StreamEvent` (token-level deltas) and
  represent higher-level agent lifecycle stages.
  """

  # Agent lifecycle
  @type t ::
          {:agent_start, cwd :: String.t()}
          | {:agent_end, [PiAgent.Message.t()]}
          # Turn lifecycle - one assistant response + any tool calls/results
          | {:turn_start}
          | {:turn_end, PiAgent.Message.t(), [PiAgent.Message.t()]}
          # Message lifecycle - emitted for user, assistant, and toolResult messages
          | {:message_start, PiAgent.Message.t()}
          # Only emitted for assistant messages during streaming
          | {:message_update, PiAgent.Message.t(), PiAi.Message.stream_event()}
          | {:message_end, PiAgent.Message.t()}
          # Tool execution lifecycle
          | {:tool_execution_start, tool_call_id :: String.t(), tool_name :: String.t(),
             args :: any()}
          | {:tool_execution_update, tool_call_id :: String.t(), tool_name :: String.t(),
             args :: any(), partial_result :: any()}
          | {:tool_execution_end, tool_call_id :: String.t(), tool_name :: String.t(),
             result :: any(), is_error :: boolean()}
end
