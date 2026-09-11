defmodule Sigma.Agent.Terminals.OutputFrame do
  @moduledoc "Bounded raw terminal output frame."

  alias Sigma.Agent.Terminals.{Error, Identity, Limits}

  @enforce_keys [:run, :sequence, :bytes]
  defstruct [:run, :sequence, :bytes]

  @type t :: %__MODULE__{run: Identity.Run.t(), sequence: pos_integer(), bytes: binary()}

  @spec new(Identity.Run.t(), pos_integer(), binary(), Limits.t()) ::
          {:ok, t()} | {:error, Error.t()}
  def new(%Identity.Run{} = run, sequence, bytes, %Limits{} = limits)
      when is_integer(sequence) and sequence > 0 and is_binary(bytes) do
    if byte_size(bytes) <= limits.max_output_frame_bytes do
      {:ok, %__MODULE__{run: run, sequence: sequence, bytes: bytes}}
    else
      {:error,
       Error.new(:output_frame_too_large, %{
         actual_bytes: byte_size(bytes),
         maximum_bytes: limits.max_output_frame_bytes
       })}
    end
  end
end
