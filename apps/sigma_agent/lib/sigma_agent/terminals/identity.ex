defmodule Sigma.Agent.Terminals.Identity do
  @moduledoc "Session-incarnation-qualified terminal identities."

  defmodule Session do
    @moduledoc false
    @enforce_keys [:repository_id, :session_id, :incarnation_id]
    defstruct [:repository_id, :session_id, :incarnation_id]

    @type t :: %__MODULE__{
            repository_id: binary(),
            session_id: binary(),
            incarnation_id: binary()
          }
  end

  defmodule Terminal do
    @moduledoc false
    @enforce_keys [:session, :terminal_id]
    defstruct [:session, :terminal_id]

    @type t :: %__MODULE__{session: Session.t(), terminal_id: binary()}
  end

  defmodule Run do
    @moduledoc false
    @enforce_keys [:terminal, :generation]
    defstruct [:terminal, :generation]

    @type t :: %__MODULE__{terminal: Terminal.t(), generation: pos_integer()}
  end

  @spec session(binary(), binary(), binary()) :: Session.t()
  def session(repository_id, session_id, incarnation_id) do
    %Session{
      repository_id: repository_id,
      session_id: session_id,
      incarnation_id: incarnation_id
    }
  end

  @spec terminal(Session.t(), binary()) :: Terminal.t()
  def terminal(%Session{} = session, terminal_id),
    do: %Terminal{session: session, terminal_id: terminal_id}

  @spec run(Terminal.t(), pos_integer()) :: Run.t()
  def run(%Terminal{} = terminal, generation) when is_integer(generation) and generation > 0,
    do: %Run{terminal: terminal, generation: generation}
end
