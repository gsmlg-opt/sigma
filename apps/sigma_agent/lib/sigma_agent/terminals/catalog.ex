defmodule Sigma.Agent.Terminals.Catalog do
  @moduledoc "Pure retained-terminal catalog and lifecycle reducer."

  alias Sigma.Agent.Terminals.{Error, Identity, Limits, Operation}

  @states [:starting, :running, :stopping, :exited, :failed, :cleanup_failed]
  @resource_states [:reserved, :managed, :released, :unconfirmed]

  defmodule Terminal do
    @moduledoc false
    @enforce_keys [:identity, :label, :state, :resource_state]
    defstruct [
      :identity,
      :label,
      :state,
      :resource_state,
      :exit_status,
      :cleanup_error,
      :failure_reason,
      :cleanup_disposition,
      run_generation: 1
    ]

    @type t :: %__MODULE__{}
  end

  @enforce_keys [:session, :limits]
  defstruct [
    :session,
    :limits,
    terminals: [],
    revision: 0,
    next_ordinal: 1,
    operations: %{},
    known_since_ms: 0
  ]

  @type t :: %__MODULE__{}

  @spec new(Identity.Session.t(), Limits.t(), keyword()) :: t()
  def new(%Identity.Session{} = session, %Limits{} = limits, opts \\ []) do
    %__MODULE__{
      session: session,
      limits: limits,
      known_since_ms: Keyword.get(opts, :known_since_ms, 0)
    }
  end

  @spec from_terminals(Identity.Session.t(), [Terminal.t()], Limits.t()) :: t()
  def from_terminals(%Identity.Session{} = session, terminals, %Limits{} = limits) do
    %__MODULE__{
      session: session,
      limits: limits,
      terminals: terminals,
      revision: length(terminals),
      next_ordinal: length(terminals) + 1
    }
  end

  @spec terminal(Identity.Terminal.t(), binary(), atom(), atom()) :: Terminal.t()
  def terminal(%Identity.Terminal{} = identity, label, state, resource_state)
      when state in @states and resource_state in @resource_states do
    %Terminal{identity: identity, label: label, state: state, resource_state: resource_state}
  end

  @spec ensure_initial(t(), Operation.t(), binary(), non_neg_integer()) ::
          {:ok, Terminal.t(), t(), :applied | :converged | :replayed} | {:error, Error.t()}
  def ensure_initial(%__MODULE__{} = catalog, %Operation{} = operation, terminal_id, now_ms) do
    with {:new, catalog} <- operation_status(catalog, operation, now_ms) do
      case catalog.terminals do
        [first | _] ->
          {:ok, first, remember(catalog, operation, first, now_ms), :converged}

        [] ->
          apply_create(catalog, operation, terminal_id, now_ms)
      end
    else
      {:replay, terminal} -> {:ok, terminal, catalog, :replayed}
      {:error, error} -> {:error, error}
    end
  end

  @spec create(t(), Operation.t(), binary(), non_neg_integer()) ::
          {:ok, Terminal.t(), t(), :applied | :replayed} | {:error, Error.t()}
  def create(%__MODULE__{} = catalog, %Operation{} = operation, terminal_id, now_ms) do
    with {:new, catalog} <- operation_status(catalog, operation, now_ms) do
      apply_create(catalog, operation, terminal_id, now_ms)
    else
      {:replay, terminal} -> {:ok, terminal, catalog, :replayed}
      {:error, error} -> {:error, error}
    end
  end

  @spec transition(Terminal.t(), term()) :: {:ok, Terminal.t()} | {:error, Error.t()}
  def transition(%Terminal{state: :starting} = terminal, :started) do
    {:ok, %{terminal | state: :running, resource_state: :managed}}
  end

  def transition(%Terminal{state: :starting} = terminal, :close_requested) do
    {:ok, %{terminal | state: :stopping, cleanup_disposition: :close}}
  end

  def transition(%Terminal{state: :starting} = terminal, {:startup_failed, reason}) do
    {:ok,
     %{
       terminal
       | state: :stopping,
         failure_reason: reason,
         cleanup_disposition: :failed
     }}
  end

  def transition(%Terminal{state: :running} = terminal, :close_requested) do
    {:ok, %{terminal | state: :stopping, cleanup_disposition: :close}}
  end

  def transition(%Terminal{state: :running} = terminal, {:shell_exited, status}) do
    {:ok,
     %{
       terminal
       | state: :stopping,
         exit_status: status,
         cleanup_disposition: :exit
     }}
  end

  def transition(
        %Terminal{state: state, cleanup_disposition: disposition} = terminal,
        :cleanup_confirmed
      )
      when state in [:stopping, :cleanup_failed] and disposition in [:exit, :failed] do
    retained_state = if disposition == :exit, do: :exited, else: :failed

    {:ok,
     %{
       terminal
       | state: retained_state,
         resource_state: :released,
         cleanup_error: nil,
         cleanup_disposition: nil
     }}
  end

  def transition(%Terminal{state: :stopping} = terminal, {:cleanup_failed, reason}) do
    {:ok,
     %{terminal | state: :cleanup_failed, resource_state: :unconfirmed, cleanup_error: reason}}
  end

  def transition(%Terminal{state: :cleanup_failed} = terminal, :retry_cleanup) do
    {:ok, %{terminal | state: :stopping, cleanup_error: nil}}
  end

  def transition(%Terminal{state: state, resource_state: :released} = terminal, :restart)
      when state in [:exited, :failed] do
    {:ok,
     %{
       terminal
       | state: :starting,
         resource_state: :reserved,
         run_generation: terminal.run_generation + 1,
         exit_status: nil,
         cleanup_error: nil,
         failure_reason: nil,
         cleanup_disposition: nil
     }}
  end

  def transition(%Terminal{} = terminal, event) do
    {:error, Error.new(:invalid_transition, %{state: terminal.state, event: event})}
  end

  @spec retained_count(t()) :: non_neg_integer()
  def retained_count(%__MODULE__{terminals: terminals}), do: length(terminals)

  @spec managed_run_count(t()) :: non_neg_integer()
  def managed_run_count(%__MODULE__{terminals: terminals}) do
    Enum.count(terminals, &(&1.resource_state in [:reserved, :managed, :unconfirmed]))
  end

  @spec resource_pin?(t()) :: boolean()
  def resource_pin?(catalog), do: managed_run_count(catalog) > 0

  @spec state_counts(t()) :: map()
  def state_counts(%__MODULE__{terminals: terminals}) do
    Map.new(@states, fn state -> {state, Enum.count(terminals, &(&1.state == state))} end)
  end

  @spec snapshot(t(), nil | non_neg_integer() | map()) :: {:ok, map()} | {:error, Error.t()}
  def snapshot(catalog, cursor \\ nil)

  def snapshot(%__MODULE__{} = catalog, nil), do: snapshot_page(catalog, 0)
  def snapshot(%__MODULE__{} = catalog, 0), do: snapshot_page(catalog, 0)

  def snapshot(%__MODULE__{revision: revision} = catalog, %{offset: offset, revision: revision})
      when is_integer(offset) and offset >= 0,
      do: snapshot_page(catalog, offset)

  def snapshot(%__MODULE__{revision: actual}, %{revision: expected}) do
    {:error, Error.new(:stale_catalog_revision, %{expected: expected, actual: actual})}
  end

  defp snapshot_page(catalog, cursor) do
    page_size = catalog.limits.max_catalog_page_entries
    entries = Enum.slice(catalog.terminals, cursor, page_size)

    next_offset =
      if cursor + length(entries) < retained_count(catalog),
        do: cursor + length(entries),
        else: nil

    next =
      if next_offset,
        do: %{offset: next_offset, revision: catalog.revision},
        else: nil

    {:ok,
     %{
       session: catalog.session,
       revision: catalog.revision,
       entries: entries,
       retained_count: retained_count(catalog),
       state_counts: state_counts(catalog),
       next_cursor: next
     }}
  end

  defp apply_create(catalog, operation, terminal_id, now_ms) do
    cond do
      not (is_binary(terminal_id) and terminal_id != "") ->
        {:error, Error.new(:invalid_terminal_identity)}

      Enum.any?(catalog.terminals, &(&1.identity.terminal_id == terminal_id)) ->
        {:error, Error.new(:terminal_identity_conflict, %{terminal_id: terminal_id})}

      retained_count(catalog) >= catalog.limits.max_retained_tabs_per_session ->
        {:error, Error.new(:retained_tab_limit)}

      true ->
        ordinal = catalog.next_ordinal
        identity = Identity.terminal(catalog.session, terminal_id)
        terminal = terminal(identity, "Terminal #{ordinal}", :starting, :reserved)

        catalog =
          catalog
          |> Map.update!(:terminals, &(&1 ++ [terminal]))
          |> Map.update!(:revision, &(&1 + 1))
          |> Map.update!(:next_ordinal, &(&1 + 1))
          |> remember(operation, terminal, now_ms)

        {:ok, terminal, catalog, :applied}
    end
  end

  defp operation_status(catalog, operation, now_ms) do
    catalog = prune_operations(catalog, now_ms)
    expires_at_ms = operation.issued_at_ms + catalog.limits.mutation_dedup_window_ms

    cond do
      operation.issued_at_ms > now_ms ->
        {:error,
         Error.new(:invalid_operation_ticket, %{
           issued_at_ms: operation.issued_at_ms,
           server_now_ms: now_ms
         })}

      operation.issued_at_ms < catalog.known_since_ms ->
        {:error, Error.new(:operation_outcome_unknown, %{operation_id: operation.id})}

      now_ms >= expires_at_ms ->
        {:error, Error.new(:operation_expired, %{operation_id: operation.id})}

      record = catalog.operations[operation.id] ->
        if record.kind == operation.kind and record.fingerprint == operation.fingerprint do
          {:replay, record.outcome}
        else
          {:error, Error.new(:operation_conflict, %{operation_id: operation.id})}
        end

      map_size(catalog.operations) >= catalog.limits.max_operation_records ->
        {:error, Error.new(:operation_history_full, %{}, retryable: true)}

      true ->
        {:new, catalog}
    end
  end

  defp remember(catalog, operation, outcome, _now_ms) do
    record = %{
      kind: operation.kind,
      fingerprint: operation.fingerprint,
      outcome: outcome,
      expires_at_ms: operation.issued_at_ms + catalog.limits.mutation_dedup_window_ms
    }

    put_in(catalog.operations[operation.id], record)
  end

  defp prune_operations(catalog, now_ms) do
    operations =
      Map.reject(catalog.operations, fn {_id, record} -> now_ms >= record.expires_at_ms end)

    %{catalog | operations: operations}
  end
end
