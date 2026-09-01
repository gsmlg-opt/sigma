defmodule Sigma.Coding.ToolError do
  @moduledoc "Stable fail-closed tool error returned to the agent loop."

  @enforce_keys [:kind, :message]
  defstruct [:kind, :message, :details, retryable: false]

  @type t :: %__MODULE__{
          kind: atom(),
          message: String.t(),
          retryable: boolean(),
          details: map() | nil
        }

  def new(kind, reason, opts \\ []) do
    %__MODULE__{
      kind: kind,
      message: bounded_message(reason),
      retryable: Keyword.get(opts, :retryable, false),
      details: Keyword.get(opts, :details)
    }
  end

  defp bounded_message(reason) when is_binary(reason), do: truncate(reason)
  defp bounded_message(reason), do: reason |> inspect(limit: 50, printable_limit: 4_096) |> truncate()

  defp truncate(message) when byte_size(message) <= 8_192, do: message
  defp truncate(message), do: binary_part(message, 0, 8_192) <> "…"
end
