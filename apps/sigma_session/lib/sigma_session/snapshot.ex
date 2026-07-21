defmodule Sigma.Session.Snapshot do
  @moduledoc """
  Deterministic replay result for one active journal branch.
  """

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
          service_tier: term(),
          mcp_server_ids: [String.t()],
          mode: String.t(),
          mode_data: map() | nil,
          compaction: map() | nil,
          branch_summary: map() | nil,
          diagnostics: [map()]
        }
end
