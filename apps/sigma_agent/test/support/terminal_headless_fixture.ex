defmodule Sigma.Agent.Terminals.HeadlessFixture do
  @moduledoc false

  defstruct bytes: <<>>, alternate_screen?: false

  def write(%__MODULE__{} = terminal, bytes) do
    all = terminal.bytes <> bytes

    %{
      terminal
      | bytes: all,
        alternate_screen?: update_alternate(terminal.alternate_screen?, all)
    }
  end

  def serialize(%__MODULE__{} = terminal),
    do: :erlang.term_to_binary({terminal.bytes, terminal.alternate_screen?})

  def restore(bytes) do
    {output, alternate?} = :erlang.binary_to_term(bytes, [:safe])
    %__MODULE__{bytes: output, alternate_screen?: alternate?}
  end

  defp update_alternate(current, bytes) do
    cond do
      :binary.match(bytes, <<27, "[?1049h">>) != :nomatch -> true
      :binary.match(bytes, <<27, "[?1049l">>) != :nomatch -> false
      true -> current
    end
  end
end
