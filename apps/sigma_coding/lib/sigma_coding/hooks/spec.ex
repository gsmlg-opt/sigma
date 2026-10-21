defmodule Sigma.Coding.Hooks.Spec do
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
    defstruct [:cmd, :timeout_ms, :status_message, :additional_context_limit, async: false]

    @type t :: %__MODULE__{
            cmd: String.t(),
            timeout_ms: pos_integer(),
            status_message: String.t() | nil,
            additional_context_limit: non_neg_integer() | nil,
            async: boolean()
          }
  end

  defmodule McpTool do
    @moduledoc "An MCP tool handler executed by the host's connected MCP client."
    @enforce_keys [:server, :tool]
    defstruct [:server, :tool, :timeout_ms, :status_message, input: %{}]

    @type t :: %__MODULE__{
            server: String.t(),
            tool: String.t(),
            input: map(),
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
          :pre_model_request
          | :post_model_request
          | :pre_tool_use
          | :permission_request
          | :post_tool_use
          | :user_prompt_submit
          | :stop
          | :session_start
          | :session_end
          | :pre_compact
          | :post_compact
          | :subagent_start
          | :subagent_stop
          | :interrupt

  @type matcher :: Regex.t() | :any | String.t()

  @type origin :: {:user | :project | :plugin, path :: String.t()}

  @type dialect :: :codex | :claude | :pi

  @type t :: %__MODULE__{
          event: event(),
          matcher: matcher(),
          handler:
            Command.t() | McpTool.t() | Http.t() | {:unsupported, type :: atom() | String.t()},
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

  Controls retain the most restrictive decision; context is accumulated
  independently. Input replacements are ordered: the latest completion wins.

  Precedence (most restrictive wins):
    halt > block > defer > ask > input changes > allow > proceed
  """
  @type outcome ::
          :proceed
          | :allow
          | {:modify, input_patch :: map()}
          | {:replace_input, input :: map()}
          | {:ask, reason :: String.t()}
          | {:defer, reason :: String.t()}
          | {:context, text :: String.t()}
          | {:block, reason :: String.t()}
          | {:halt, reason :: String.t() | nil}
          | {:with_context, outcome(), text :: String.t()}
end
