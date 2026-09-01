defmodule Sigma.Coding.ToolExecution do
  @moduledoc false

  @enforce_keys [:index, :tool_call, :tool, :metadata, :deadline_ms, :cancellation_ref, :run]
  defstruct [:index, :tool_call, :tool, :metadata, :deadline_ms, :cancellation_ref, :run]
end
