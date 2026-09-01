defmodule Sigma.Protocol.Error do
  @moduledoc "Transport-safe structured protocol error."

  @enforce_keys [:code, :message]
  defstruct [:code, :message, details: %{}]

  @type t :: %__MODULE__{
          code: String.t(),
          message: String.t(),
          details: map()
        }

  def new(code, message, details \\ %{})
      when is_binary(code) and is_binary(message) and is_map(details) do
    %__MODULE__{code: code, message: message, details: details}
  end
end
