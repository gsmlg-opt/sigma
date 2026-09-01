defmodule Sigma.Protocol.Envelope do
  @moduledoc "Versioned transport-neutral command and event envelope."

  alias Sigma.Protocol.Error

  @version 1

  @commands ~w(
    session.create
    session.resume
    session.status
    session.switch
    session.fork
    session.dump
    session.export
    prompt.submit
    prompt.steer
    prompt.follow_up
    turn.cancel
    permission.resolve
    mcp.elicitation.resolve
    model.select
    subscription.attach
    subscription.detach
  )

  @events ~w(
    session.snapshot
    prompt.admitted
    turn.started
    message.started
    message.delta
    message.completed
    tool.started
    tool.update
    tool.completed
    permission.required
    turn.completed
    turn.failed
    turn.cancelled
    session.error
  )

  @enforce_keys [:version, :id, :session_id, :timestamp, :type, :kind]
  defstruct [
    :version,
    :id,
    :session_id,
    :turn_id,
    :timestamp,
    :type,
    :kind,
    payload: %{},
    error: nil
  ]

  @type kind :: :command | :event

  @type t :: %__MODULE__{
          version: pos_integer(),
          id: String.t(),
          session_id: String.t(),
          turn_id: String.t() | nil,
          timestamp: integer(),
          type: String.t(),
          kind: kind(),
          payload: map(),
          error: Error.t() | nil
        }

  def version, do: @version
  def commands, do: @commands
  def events, do: @events

  def command(type, session_id, payload \\ %{}, opts \\ [])

  def command(type, session_id, payload, opts)
      when type in @commands and is_binary(session_id) and session_id != "" and is_map(payload) do
    new(:command, type, session_id, payload, opts)
  end

  def command(_type, _session_id, _payload, _opts), do: {:error, :invalid_command}

  def event(type, session_id, payload \\ %{}, opts \\ [])

  def event(type, session_id, payload, opts)
      when type in @events and is_binary(session_id) and session_id != "" and is_map(payload) do
    new(:event, type, session_id, payload, opts)
  end

  def event(_type, _session_id, _payload, _opts), do: {:error, :invalid_event}

  defp new(kind, type, session_id, payload, opts) do
    {:ok,
     %__MODULE__{
       version: @version,
       id: Keyword.get(opts, :id, random_id()),
       session_id: session_id,
       turn_id: Keyword.get(opts, :turn_id),
       timestamp: Keyword.get(opts, :timestamp, System.system_time(:millisecond)),
       type: type,
       kind: kind,
       payload: payload,
       error: Keyword.get(opts, :error)
     }}
  end

  defp random_id do
    "evt_" <> (:crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower))
  end
end
