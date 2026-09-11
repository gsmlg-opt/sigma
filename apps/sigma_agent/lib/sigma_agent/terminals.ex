defmodule Sigma.Agent.Terminals do
  @moduledoc "Repository/session-qualified internal terminal facade."

  alias Sigma.Agent.Terminals.{Error, Manager, ResourceLedger}

  @default_cleanup_timeout_ms 15_000

  def issue_operation(repo_path, session_id, id, kind, payload \\ nil),
    do: call(repo_path, session_id, &Manager.issue_operation(&1, id, kind, payload))

  def list(repo_path, session_id, cursor \\ nil),
    do: call(repo_path, session_id, &Manager.list(&1, cursor))

  def subscribe(repo_path, session_id, observer \\ self()),
    do: call(repo_path, session_id, &Manager.subscribe(&1, observer))

  def resource_summary(repo_path, session_id) do
    case manager(repo_path, session_id) do
      {:ok, manager} ->
        try do
          Manager.resource_summary(manager)
        catch
          :exit, _reason -> unavailable_summary(repo_path, session_id, :ledger_unavailable)
        end

      {:error, error} ->
        unavailable_summary(repo_path, session_id, error)
    end
  end

  def can_stop(repo_path, session_id) do
    case manager(repo_path, session_id) do
      {:ok, manager} -> Manager.can_stop(manager)
      {:error, _error} -> offline_can_stop(repo_path, session_id)
    end
  catch
    :exit, _reason -> {:error, Error.new(:session_unavailable, %{}, retryable: true)}
  end

  def begin_drain(repo_path, session_id, mode, opts \\ []) do
    case manager(repo_path, session_id) do
      {:ok, manager} ->
        with {:ok, drain} <- Manager.begin_drain(manager, mode, opts) do
          {:ok, %{manager: manager, drain: drain}}
        end

      {:error, _error} ->
        with {:ok, _summary} <- offline_can_stop(repo_path, session_id) do
          {:ok, %{manager: nil, drain: nil}}
        end
    end
  catch
    :exit, _reason -> {:error, Error.new(:session_unavailable, %{}, retryable: true)}
  end

  def cleanup_all(token, timeout_ms \\ @default_cleanup_timeout_ms)

  def cleanup_all(%{manager: nil, drain: nil}, _timeout_ms), do: :ok

  def cleanup_all(%{manager: manager, drain: drain}, timeout_ms)
      when is_pid(manager) and is_integer(timeout_ms) and timeout_ms > 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    with {:ok, runs} <- Manager.cleanup_all(manager, drain),
         :ok <- await_all(manager, runs, deadline),
         %{managed_run_count: 0, retained_count: 0} <- Manager.resource_summary(manager) do
      :ok
    else
      {:error, _error} = error -> error
      _summary -> {:error, Error.new(:cleanup_unconfirmed, %{}, retryable: true)}
    end
  catch
    :exit, {:timeout, _call} ->
      {:error, Error.new(:cleanup_timeout, %{}, retryable: true)}

    :exit, _reason ->
      {:error, Error.new(:cleanup_unconfirmed, %{}, retryable: true)}
  end

  def release_drain(%{manager: nil, drain: nil}), do: :ok

  def release_drain(%{manager: manager, drain: drain}) when is_pid(manager) do
    Manager.release_drain(manager, drain)
  catch
    :exit, _reason -> :ok
  end

  def validate_incarnation(repo_path, session_id, incarnation_id) do
    call(repo_path, session_id, &Manager.validate_incarnation(&1, incarnation_id))
  end

  def ensure_initial(repo_path, session_id, operation, attrs \\ %{}),
    do: call(repo_path, session_id, &Manager.ensure_initial(&1, operation, attrs))

  def create(repo_path, session_id, operation, attrs \\ %{}),
    do: call(repo_path, session_id, &Manager.create(&1, operation, attrs))

  def rename(repo_path, session_id, terminal_id, label, revision, operation),
    do: call(repo_path, session_id, &Manager.rename(&1, terminal_id, label, revision, operation))

  def close(repo_path, session_id, terminal_id, generation, operation),
    do: call(repo_path, session_id, &Manager.close(&1, terminal_id, generation, operation))

  def retry_cleanup(repo_path, session_id, terminal_id, generation, operation),
    do:
      call(repo_path, session_id, &Manager.retry_cleanup(&1, terminal_id, generation, operation))

  def await_cleanup(repo_path, session_id, terminal_id, generation),
    do: call(repo_path, session_id, &Manager.await_cleanup(&1, terminal_id, generation))

  def restart(repo_path, session_id, terminal_id, generation, operation, attrs \\ %{}),
    do:
      call(repo_path, session_id, &Manager.restart(&1, terminal_id, generation, operation, attrs))

  def attach(repo_path, session_id, terminal_id, generation, observer, rendered_sequence \\ 0),
    do:
      call(repo_path, session_id, fn manager ->
        Manager.attach(manager, terminal_id, generation, observer, rendered_sequence)
      end)

  def detach(repo_path, session_id, terminal_id, generation, attachment_id),
    do: call(repo_path, session_id, &Manager.detach(&1, terminal_id, generation, attachment_id))

  def acquire_control(repo_path, session_id, terminal_id, generation, attachment_id),
    do:
      call(
        repo_path,
        session_id,
        &Manager.acquire_control(&1, terminal_id, generation, attachment_id)
      )

  def takeover_control(
        repo_path,
        session_id,
        terminal_id,
        generation,
        attachment_id,
        expected_epoch
      ),
      do:
        call(repo_path, session_id, fn manager ->
          Manager.takeover_control(
            manager,
            terminal_id,
            generation,
            attachment_id,
            expected_epoch
          )
        end)

  def renew_control(repo_path, session_id, terminal_id, generation, attachment_id, epoch),
    do:
      call(repo_path, session_id, fn manager ->
        Manager.renew_control(manager, terminal_id, generation, attachment_id, epoch)
      end)

  def release_control(repo_path, session_id, terminal_id, generation, attachment_id, epoch),
    do:
      call(repo_path, session_id, fn manager ->
        Manager.release_control(manager, terminal_id, generation, attachment_id, epoch)
      end)

  def input(repo_path, session_id, terminal_id, generation, request, bytes),
    do:
      call(repo_path, session_id, fn manager ->
        Manager.input(manager, terminal_id, generation, request, bytes)
      end)

  def resize(repo_path, session_id, terminal_id, generation, request, columns, rows),
    do:
      call(repo_path, session_id, fn manager ->
        Manager.resize(manager, terminal_id, generation, request, columns, rows)
      end)

  def acknowledge(repo_path, session_id, terminal_id, generation, attachment_id, sequence),
    do:
      call(repo_path, session_id, fn manager ->
        Manager.acknowledge(manager, terminal_id, generation, attachment_id, sequence)
      end)

  def touch_attachment(repo_path, session_id, terminal_id, generation, attachment_id),
    do:
      call(repo_path, session_id, fn manager ->
        Manager.touch_attachment(manager, terminal_id, generation, attachment_id)
      end)

  def resync(repo_path, session_id, terminal_id, generation, attachment_id, rendered_sequence),
    do:
      call(repo_path, session_id, fn manager ->
        Manager.resync(manager, terminal_id, generation, attachment_id, rendered_sequence)
      end)

  defp await_all(manager, runs, deadline) do
    Enum.reduce_while(runs, :ok, fn run, :ok ->
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining <= 0 do
        {:halt, {:error, Error.new(:cleanup_timeout, %{}, retryable: true)}}
      else
        case Manager.await_cleanup(
               manager,
               run.terminal.terminal_id,
               run.generation,
               remaining
             ) do
          {:ok, :closed} -> {:cont, :ok}
          {:error, _error} = error -> {:halt, error}
          _other -> {:halt, {:error, Error.new(:cleanup_unconfirmed, %{}, retryable: true)}}
        end
      end
    end)
  end

  defp offline_can_stop(repo_path, session_id) do
    summary =
      ResourceLedger.summary_scope(
        ResourceLedger,
        Sigma.Agent.Runtime.normalize_repo_path(repo_path),
        session_id
      )

    case summary do
      %{trustworthy?: true, managed_run_count: 0} ->
        {:ok, %{session: nil, retained_history?: summary.retained_count > 0}}

      %{trustworthy?: true} ->
        {:error,
         Error.new(:session_draining, %{
           reason: :terminal_resources_present,
           managed_run_count: summary.managed_run_count
         })}

      %{trustworthy?: false} ->
        {:error, Error.new(:cleanup_unconfirmed, %{reason: :ledger_untrusted}, retryable: true)}
    end
  catch
    :exit, _reason ->
      {:error, Error.new(:session_unavailable, %{reason: :ledger_unavailable}, retryable: true)}
  end

  defp call(repo_path, session_id, function) do
    with {:ok, manager} <- manager(repo_path, session_id), do: function.(manager)
  catch
    :exit, _reason -> {:error, Error.new(:catalog_unavailable, %{}, retryable: true)}
  end

  defp manager(repo_path, session_id) do
    case Sigma.Agent.Runtime.lookup(repo_path, session_id, :terminal_manager) do
      pid when is_pid(pid) -> {:ok, pid}
      _ -> {:error, Error.new(:catalog_unavailable, %{}, retryable: true)}
    end
  end

  defp unavailable_summary(repo_path, session_id, error) do
    summary =
      try do
        ResourceLedger.summary_scope(
          ResourceLedger,
          Sigma.Agent.Runtime.normalize_repo_path(repo_path),
          session_id
        )
      catch
        :exit, _reason -> unknown_summary()
      end

    typed_error =
      case error do
        %Error{} = typed -> typed
        reason -> Error.new(:session_unavailable, %{reason: reason}, retryable: true)
      end

    {:error, typed_error, Map.merge(summary, %{available?: false})}
  end

  defp unknown_summary do
    %{
      trustworthy?: false,
      retained_count: :unknown,
      managed_run_count: :unknown,
      resource_pin?: :unknown,
      entries: :unknown
    }
  end
end
