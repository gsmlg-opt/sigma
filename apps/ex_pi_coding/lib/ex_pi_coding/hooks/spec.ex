defmodule PiCoding.Hooks.Spec do
  @moduledoc """
  Canonical types for the hook system.

  A `HookSpec` is the normalized internal representation of a single hook
  entry from any supported config file (Codex hooks.json, Claude settings.json,
  or pi hooks.json). All discovery paths produce `HookSpec` structs; the runner
  and matcher operate exclusively on this type.
  """

  defmodule Command do
    @moduledoc "A command-type hook handler."
    @enforce_keys [:cmd]
    defstruct [:cmd, :timeout_ms, :status_message]

    @type t :: %__MODULE__{
            cmd: String.t(),
            timeout_ms: pos_integer(),
            status_message: String.t() | nil
          }
  end

  defmodule Http do
    @moduledoc "An HTTP-type hook handler (parsed but not executed in v1)."
    @enforce_keys [:url]
    defstruct [:url, :timeout_ms, :headers]

    @type t :: %__MODULE__{
            url: String.t(),
            timeout_ms: pos_integer(),
            headers: map()
          }
  end

  @enforce_keys [:event, :handler, :origin, :dialect]
  defstruct [
    :event,
    :matcher,
    :handler,
    :origin,
    :dialect,
    :trusted?,
    :unsupported_reason
  ]

  @type event ::
          :pre_tool_use
          | :permission_request
          | :post_tool_use
          | :user_prompt_submit
          | :stop
          | :session_start
          | :pre_compact

  @type matcher :: Regex.t() | :any | String.t()

  @type origin :: {:user | :project | :plugin, path :: String.t()}

  @type dialect :: :codex | :claude | :pi

  @type t :: %__MODULE__{
          event: event(),
          matcher: matcher(),
          handler: Command.t() | Http.t() | {:unsupported, type :: atom()},
          origin: origin(),
          dialect: dialect(),
          trusted?: boolean() | nil,
          unsupported_reason: String.t() | nil
        }

  # ---------------------------------------------------------------------------
  # Outcome type
  # ---------------------------------------------------------------------------

  @typedoc """
  The outcome of running one or more hooks against an event.

  Forms a join-semilattice where `:proceed` is the identity element and
  `:halt` is the absorbing element.

  Precedence (most restrictive wins):
    halt > block > defer > ask > modify/context > proceed
  """
  @type outcome ::
          :proceed
          | {:modify, input_patch :: map()}
          | {:ask, reason :: String.t()}
          | {:defer, reason :: String.t()}
          | {:context, text :: String.t()}
          | {:block, reason :: String.t()}
          | {:halt, reason :: String.t() | nil}
end
