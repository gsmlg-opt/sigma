defmodule Sigma.Agent.Terminals.Limits do
  @moduledoc "Configurable terminal resource and transport limits."

  defstruct max_retained_tabs_per_session: 8,
            max_managed_runs_per_node: 32,
            max_retained_records_per_node: 128,
            max_observers_per_terminal: 4,
            max_raw_replay_bytes: 1_048_576,
            max_snapshot_bytes: 2_097_152,
            max_aggregate_retention_bytes: 134_217_728,
            max_pending_output_bytes_per_attachment: 262_144,
            max_parser_backlog_bytes: 262_144,
            max_input_frame_bytes: 16_384,
            max_output_frame_bytes: 65_536,
            min_columns: 2,
            max_columns: 500,
            min_rows: 1,
            max_rows: 300,
            initial_columns: 120,
            initial_rows: 24,
            controller_lease_ms: 15_000,
            controller_renewal_ms: 5_000,
            attachment_inactivity_ms: 60_000,
            mutation_dedup_window_ms: 600_000,
            max_operation_records: 1_024,
            cleanup_budget_ms: 5_000,
            max_catalog_page_entries: 64

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(overrides \\ []) do
    struct!(__MODULE__, overrides)
  end

  @spec valid_dimensions?(t(), integer(), integer()) :: boolean()
  def valid_dimensions?(%__MODULE__{} = limits, columns, rows) do
    is_integer(columns) and columns >= limits.min_columns and columns <= limits.max_columns and
      is_integer(rows) and rows >= limits.min_rows and rows <= limits.max_rows
  end
end
