defmodule Sigma.Ai.ProviderEvent do
  @moduledoc "Normalized event emitted by every provider adapter."

  @enforce_keys [:type]
  defstruct [:type, :index, :delta, :message, :tool_call, :usage, :stop_reason, :error]
end
