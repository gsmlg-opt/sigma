defmodule Sigma.Agent.Terminals.Operation do
  @moduledoc "Server-issued identity ticket for one deliberate terminal mutation."

  @enforce_keys [:id, :kind, :issued_at_ms, :fingerprint]
  defstruct [:id, :kind, :issued_at_ms, :fingerprint]

  @opaque t :: %__MODULE__{
            id: binary(),
            kind: atom(),
            issued_at_ms: non_neg_integer(),
            fingerprint: term()
          }

  @spec issue(binary(), atom(), non_neg_integer(), term()) :: t()
  def issue(id, kind, issued_at_ms, payload \\ nil)
      when is_binary(id) and id != "" and is_atom(kind) and is_integer(issued_at_ms) and
             issued_at_ms >= 0 do
    %__MODULE__{id: id, kind: kind, issued_at_ms: issued_at_ms, fingerprint: {kind, payload}}
  end
end
