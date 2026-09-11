defmodule Sigma.Web.Session.TerminalBinding do
  @moduledoc "LiveView transport adapter for the session-owned terminal subsystem."

  alias Sigma.Agent.Terminals
  alias Sigma.Agent.Terminals.{Catalog, Error, Identity}
  alias Sigma.Coding.Terminal.Native

  @type capability :: %{status: atom(), reason: term(), details: map()}

  def capability do
    if Application.get_env(:sigma_web, :session_terminals_enabled, true) do
      case Native.capabilities() do
        {:ok, details} -> %{status: :available, reason: nil, details: details}
        {:error, :unsupported_platform} -> unavailable(:unsupported_platform)
        {:error, :backend_unavailable} -> unavailable(:backend_missing)
      end
    else
      unavailable(:disabled)
    end
  end

  def runtime_backend(%{status: :available}), do: Native
  def runtime_backend(_capability), do: nil

  def subscribe_and_list(repo_path, session_id, %{status: :available}) do
    with {:ok, session} <- Terminals.subscribe(repo_path, session_id),
         {:ok, snapshot} <- Terminals.list(repo_path, session_id) do
      {:ok, present(snapshot, %{}), session}
    end
  end

  def subscribe_and_list(_repo_path, _session_id, capability) do
    {:unavailable, unavailable_catalog(capability), nil}
  end

  def refresh(repo_path, session_id, attachments, %{status: :available}) do
    case Terminals.list(repo_path, session_id) do
      {:ok, snapshot} -> {:ok, present(snapshot, attachments)}
      {:error, error} -> {:error, unavailable_catalog(error)}
    end
  end

  def refresh(_repo_path, _session_id, _attachments, capability),
    do: {:error, unavailable_catalog(capability)}

  def create(repo_path, session_id, kind, cwd, observer)
      when kind in [:ensure_initial, :create] do
    operation_id = operation_id(kind)

    operation = Terminals.issue_operation(repo_path, session_id, operation_id, kind)

    result =
      apply(Terminals, kind, [
        repo_path,
        session_id,
        operation,
        %{cwd: cwd, creator: %{observer: observer}}
      ])

    emit(:create, %{count: 1}, %{
      repository_id: repo_path,
      session_id: session_id,
      outcome: outcome(result),
      operation: kind
    })

    result
  end

  def attach(repo_path, session_id, entry, observer, rendered_sequence \\ 0) do
    result =
      Terminals.attach(
        repo_path,
        session_id,
        entry.terminal_id,
        entry.generation,
        observer,
        rendered_sequence
      )

    emit(:attach, %{count: 1}, metadata(repo_path, session_id, entry, outcome: outcome(result)))
    result
  end

  def detach(repo_path, session_id, attachment) do
    result =
      Terminals.detach(
        repo_path,
        session_id,
        attachment.terminal_id,
        attachment.generation,
        attachment.attachment_id
      )

    emit(
      :detach,
      %{count: 1},
      metadata(repo_path, session_id, attachment, outcome: outcome(result))
    )

    result
  end

  def acquire_control(repo_path, session_id, attachment, takeover? \\ false) do
    result =
      if takeover? do
        Terminals.takeover_control(
          repo_path,
          session_id,
          attachment.terminal_id,
          attachment.generation,
          attachment.attachment_id,
          attachment.control_epoch
        )
      else
        Terminals.acquire_control(
          repo_path,
          session_id,
          attachment.terminal_id,
          attachment.generation,
          attachment.attachment_id
        )
      end

    emit(
      :control,
      %{count: 1},
      metadata(repo_path, session_id, attachment,
        outcome: outcome(result),
        takeover: takeover?
      )
    )

    result
  end

  def release_control(repo_path, session_id, %{controller?: true} = attachment) do
    Terminals.release_control(
      repo_path,
      session_id,
      attachment.terminal_id,
      attachment.generation,
      attachment.attachment_id,
      attachment.control_epoch
    )
  end

  def release_control(_repo_path, _session_id, _attachment), do: :ok

  def renew(repo_path, session_id, attachment) do
    Terminals.renew_control(
      repo_path,
      session_id,
      attachment.terminal_id,
      attachment.generation,
      attachment.attachment_id,
      attachment.control_epoch
    )
  end

  def touch(repo_path, session_id, attachment) do
    Terminals.touch_attachment(
      repo_path,
      session_id,
      attachment.terminal_id,
      attachment.generation,
      attachment.attachment_id
    )
  end

  def input(repo_path, session_id, session, attachment, catalog_revision, encoded) do
    with {:ok, bytes} <- Base.decode64(encoded),
         :ok <- validate_scope(session, attachment),
         request <- request(session, attachment, catalog_revision),
         result <-
           Terminals.input(
             repo_path,
             session_id,
             attachment.terminal_id,
             attachment.generation,
             request,
             bytes
           ) do
      emit(
        :input,
        %{bytes: byte_size(bytes)},
        metadata(repo_path, session_id, attachment, outcome: outcome(result))
      )

      result
    else
      :error -> {:error, Error.new(:unknown, %{reason: :invalid_base64})}
      {:error, _error} = error -> error
    end
  end

  def resize(repo_path, session_id, session, attachment, catalog_revision, columns, rows) do
    with :ok <- validate_scope(session, attachment),
         request <- request(session, attachment, catalog_revision),
         result <-
           Terminals.resize(
             repo_path,
             session_id,
             attachment.terminal_id,
             attachment.generation,
             request,
             columns,
             rows
           ) do
      emit(
        :resize,
        %{count: 1},
        metadata(repo_path, session_id, attachment, outcome: outcome(result))
      )

      result
    end
  end

  def acknowledge(repo_path, session_id, attachment, sequence) do
    Terminals.acknowledge(
      repo_path,
      session_id,
      attachment.terminal_id,
      attachment.generation,
      attachment.attachment_id,
      sequence
    )
  end

  def resync(repo_path, session_id, attachment, rendered_sequence) do
    result =
      Terminals.resync(
        repo_path,
        session_id,
        attachment.terminal_id,
        attachment.generation,
        attachment.attachment_id,
        rendered_sequence
      )

    emit(
      :resync,
      %{count: 1},
      metadata(repo_path, session_id, attachment, outcome: outcome(result))
    )

    result
  end

  def rename(repo_path, session_id, terminal_id, label, revision) do
    operation =
      Terminals.issue_operation(repo_path, session_id, operation_id(:rename), :rename, label)

    Terminals.rename(repo_path, session_id, terminal_id, label, revision, operation)
  end

  def restart(repo_path, session_id, entry, cwd, observer) do
    operation = Terminals.issue_operation(repo_path, session_id, operation_id(:restart), :restart)

    Terminals.restart(
      repo_path,
      session_id,
      entry.terminal_id,
      entry.generation,
      operation,
      %{cwd: cwd, creator: %{observer: observer}}
    )
  end

  def close(repo_path, session_id, entry, retry? \\ false) do
    kind = if retry?, do: :retry_cleanup, else: :close

    operation = Terminals.issue_operation(repo_path, session_id, operation_id(kind), kind)

    apply(Terminals, kind, [
      repo_path,
      session_id,
      entry.terminal_id,
      entry.generation,
      operation
    ])
  end

  def present(snapshot, attachments) do
    entries = Enum.map(snapshot.entries, &present_entry(&1, attachments))
    selected_id = entries |> List.first() |> then(&(&1 && &1.terminal_id))

    Map.merge(snapshot, %{status: :available, entries: entries, selected_id: selected_id})
  end

  defp present_entry(%Catalog.Terminal{} = terminal, attachments) do
    id = terminal.identity.terminal_id
    attachment = Map.get(attachments, id, %{})

    %{
      terminal_id: id,
      session: terminal.identity.session,
      generation: terminal.run_generation,
      label: terminal.label,
      state: terminal.state,
      resource_state: terminal.resource_state,
      exit_status: terminal.exit_status,
      cleanup_error: terminal.cleanup_error,
      failure_reason: terminal.failure_reason,
      startup_directory: Map.get(attachment, :startup_directory),
      attachment_id: Map.get(attachment, :attachment_id),
      control_epoch: Map.get(attachment, :control_epoch, 0),
      controller?: Map.get(attachment, :controller?, false),
      resynced?: Map.get(attachment, :resynced?, false),
      renaming?: Map.get(attachment, :renaming?, false),
      rename_value: Map.get(attachment, :rename_value),
      rename_error: Map.get(attachment, :rename_error)
    }
  end

  def unavailable_catalog(%{status: status, reason: reason} = capability) do
    %{
      status: status,
      reason: reason,
      capability: Map.get(capability, :details, %{}),
      entries: [],
      retained_count: nil,
      state_counts: %{},
      revision: 0,
      selected_id: nil
    }
  end

  def unavailable_catalog(%Error{} = error),
    do: unavailable_catalog(unavailable(:unavailable, %{error: error.code}))

  def attachment(result, cwd) do
    run = result.run

    %{
      terminal_id: run.terminal.terminal_id,
      session: run.terminal.session,
      generation: run.generation,
      attachment_id: result.attachment_id,
      control_epoch: result.control_epoch,
      controller?: result.controller,
      resynced?: true,
      rendered_sequence: 0,
      startup_directory: cwd
    }
  end

  defp request(session, attachment, catalog_revision) do
    terminal = Identity.terminal(session, attachment.terminal_id)

    %{
      run: Identity.run(terminal, attachment.generation),
      attachment_id: attachment.attachment_id,
      control_epoch: attachment.control_epoch,
      catalog_revision: catalog_revision
    }
  end

  defp validate_scope(%Identity.Session{} = session, attachment) do
    if attachment.session == session,
      do: :ok,
      else: {:error, Error.new(:session_scope_mismatch)}
  end

  defp unavailable(reason, details \\ %{}),
    do: %{status: reason, reason: reason, details: details}

  defp operation_id(kind),
    do: "web-#{kind}-#{System.unique_integer([:positive, :monotonic])}"

  defp outcome({:ok, _value}), do: :ok
  defp outcome(:ok), do: :ok
  defp outcome({:error, %Error{code: code}}), do: code
  defp outcome(_other), do: :error

  defp metadata(repo_path, session_id, value, extra) do
    Map.merge(
      %{
        repository_id: repo_path,
        session_id: session_id,
        incarnation_id: get_in(value, [Access.key(:session), Access.key(:incarnation_id)]),
        terminal_id: value.terminal_id,
        generation: value.generation
      },
      Map.new(extra)
    )
  end

  defp emit(event, measurements, metadata) do
    :telemetry.execute([:sigma, :terminal, event], measurements, metadata)
  end
end
