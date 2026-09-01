defmodule Sigma.Ai.ProviderStopReason do
  @moduledoc "Closed provider-neutral stop reason retaining the raw adapter value."

  @type reason :: :stop | :length | :tool_use | :content_filter | :cancelled | :error | :unknown
  defstruct [:reason, :raw]

  def normalize(reason) when reason in [:stop, :length, :tool_use, :cancelled],
    do: %__MODULE__{reason: reason, raw: reason}

  def normalize("stop"), do: %__MODULE__{reason: :stop, raw: "stop"}
  def normalize("end_turn"), do: %__MODULE__{reason: :stop, raw: "end_turn"}
  def normalize("max_tokens"), do: %__MODULE__{reason: :length, raw: "max_tokens"}
  def normalize("length"), do: %__MODULE__{reason: :length, raw: "length"}
  def normalize("tool_use"), do: %__MODULE__{reason: :tool_use, raw: "tool_use"}
  def normalize("tool_calls"), do: %__MODULE__{reason: :tool_use, raw: "tool_calls"}
  def normalize("content_filter"), do: %__MODULE__{reason: :content_filter, raw: "content_filter"}
  def normalize(nil), do: %__MODULE__{reason: :unknown, raw: nil}
  def normalize(raw), do: %__MODULE__{reason: :unknown, raw: raw}
end
