defmodule Sigma.Agent.Terminals.Error do
  @moduledoc "Typed errors shared inside the terminal feature boundary."

  @codes [
    :backend_missing,
    :capacity_exhausted,
    :catalog_snapshot_too_large,
    :catalog_unavailable,
    :cleanup_failed,
    :cleanup_timeout,
    :cleanup_unconfirmed,
    :control_conflict,
    :control_occupied,
    :controller_lease_expired,
    :invalid_dimensions,
    :invalid_label,
    :invalid_operation_ticket,
    :invalid_terminal_identity,
    :invalid_transition,
    :not_controller,
    :operation_conflict,
    :operation_expired,
    :operation_history_full,
    :operation_outcome_unknown,
    :output_frame_too_large,
    :retained_tab_limit,
    :session_draining,
    :session_unavailable,
    :session_scope_mismatch,
    :snapshot_unavailable,
    :stale_catalog_revision,
    :stale_control_epoch,
    :stale_run_generation,
    :stale_session_incarnation,
    :stale_terminal,
    :startup_failed,
    :terminal_identity_conflict,
    :terminal_not_found,
    :unsupported_platform,
    :unknown
  ]

  @code_by_string Map.new(@codes, &{Atom.to_string(&1), &1})

  @enforce_keys [:code]
  defstruct [:code, details: %{}, retryable: false]

  @type code :: unquote(Enum.reduce(@codes, &{:|, [], [&1, &2]}))
  @type t :: %__MODULE__{code: code(), details: map(), retryable: boolean()}

  @spec new(code(), map(), keyword()) :: t()
  def new(code, details \\ %{}, opts \\ []) when code in @codes and is_map(details) do
    %__MODULE__{code: code, details: details, retryable: Keyword.get(opts, :retryable, false)}
  end

  @spec from_code(binary()) :: t()
  def from_code(code) when is_binary(code), do: new(Map.get(@code_by_string, code, :unknown))
end
