defmodule Sigma.Session.Snapshot do
  @moduledoc """
  Deterministic replay result for one active journal branch.
  """

  @typedoc """
  Persisted service-tier selection.

  Legacy scalars are `auto`, `default`, `flex`, `scale`, `priority`,
  `openai-only`, or `claude-only`. Current journals use a non-empty map keyed by
  `openai`, `anthropic`, or `google`, with `auto`, `default`, `flex`, `scale`, or
  `priority` values. `nil` clears the selection.
  """
  @type service_tier :: String.t() | service_tier_by_family() | nil

  @typedoc """
  Per-family service tiers as persisted by current journals.

  Runtime validation enforces the documented keys and values; Elixir typespecs
  cannot express literal binary unions.
  """
  @type service_tier_by_family :: %{optional(String.t()) => String.t()}

  @typedoc "A tagged journal or storage diagnostic reason."
  @type diagnostic_reason :: atom() | tuple()

  @typedoc """
  A recoverable replay diagnostic.

  Journal diagnostics include `entry_index` and `entry_id`. Storage diagnostics
  may omit either location and add storage-specific fields.
  """
  @type diagnostic :: %{
          required(:kind) => atom(),
          required(:reason) => diagnostic_reason(),
          optional(:entry_index) => non_neg_integer(),
          required(:entry_id) => term(),
          optional(atom()) => term()
        }

  defstruct [
    :header,
    :session_id,
    :cwd,
    :parent_session_id,
    :active_leaf_id,
    :provider_id,
    :model_id,
    :reasoning_level,
    :configured_reasoning_level,
    :service_tier,
    :mode_data,
    :compaction,
    :branch_summary,
    branch_entry_ids: [],
    messages: [],
    mcp_server_ids: [],
    mode: "none",
    diagnostics: []
  ]

  @type t :: %__MODULE__{
          header: map() | nil,
          session_id: String.t() | nil,
          cwd: String.t() | nil,
          parent_session_id: String.t() | nil,
          active_leaf_id: String.t() | nil,
          branch_entry_ids: [String.t()],
          messages: [Sigma.Agent.Message.t()],
          provider_id: String.t() | nil,
          model_id: String.t() | nil,
          reasoning_level: String.t() | nil,
          configured_reasoning_level: String.t() | nil,
          service_tier: service_tier(),
          mcp_server_ids: [String.t()],
          mode: String.t(),
          mode_data: map() | nil,
          compaction: map() | nil,
          branch_summary: map() | nil,
          diagnostics: [diagnostic()]
        }
end
