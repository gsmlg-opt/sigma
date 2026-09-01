defmodule Sigma.Coding.ToolUpdate do
  @moduledoc "Normalized partial output from one running tool call."

  @enforce_keys [:tool_call_id, :sequence, :content]
  defstruct [:tool_call_id, :sequence, :content, details: %{}]

  @type t :: %__MODULE__{
          tool_call_id: String.t(),
          sequence: pos_integer(),
          content: [map()],
          details: term()
        }
end
