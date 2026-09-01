defmodule Sigma.Agent.RepositoryProcess do
  @moduledoc """
  Lightweight process that tracks runtime status for one repository.
  """

  use GenServer

  def start_link(opts) do
    repo_path = Keyword.fetch!(opts, :repo_path)
    GenServer.start_link(__MODULE__, repo_path, name: Sigma.Agent.Runtime.via(repo_path, :process))
  end

  def get_session(pid, session_id, opts) do
    GenServer.call(pid, {:get_session, session_id, opts}, 30_000)
  end

  def status(pid) do
    GenServer.call(pid, :status)
  end

  def session_operation(pid, source_session_id, operation) do
    GenServer.call(pid, {:session_operation, source_session_id, operation}, :infinity)
  end

  @impl true
  def init(repo_path) do
    {:ok, %{repo_path: repo_path, sessions: %{}}}
  end

  @impl true
  def handle_call({:get_session, session_id, opts}, _from, state) do
    case Map.get(state.sessions, session_id) do
      %{session: session_pid} = handle when is_pid(session_pid) ->
        if Process.alive?(session_pid) do
          {:reply, {:ok, handle}, state}
        else
          start_session(session_id, opts, state)
        end

      _ ->
        start_session(session_id, opts, state)
    end
  end

  def handle_call(:status, _from, state) do
    sessions =
      state.sessions
      |> Enum.reject(fn {_id, handle} -> stale_session?(handle) end)
      |> Map.new(fn {id, handle} ->
        status =
          if Process.alive?(handle.session) do
            Sigma.Agent.SessionProcess.status(handle.session)
          else
            %{status: :stopped}
          end

        {id, status}
      end)

    {:reply, %{repo_path: state.repo_path, status: :active, sessions: sessions}, state}
  end

  def handle_call({:session_operation, source_session_id, operation}, _from, state) do
    started_at = System.monotonic_time()
    handle = running_session(state, source_session_id)

    result =
      case acquire_operation(handle) do
        :ok ->
          result =
            safely_perform_operation(fn ->
              with :ok <- flush_session(handle) do
                perform_operation(source_session_id, operation)
              end
            end)

          release_after_operation(handle, operation, result)
          result

        {:error, _reason} = error ->
          error
      end

    state = finalize_file_operation(state, source_session_id, operation, result, handle)

    :telemetry.execute(
      [:sigma, :session, :operation],
      %{duration: System.monotonic_time() - started_at},
      %{
        repo_path: state.repo_path,
        session_id: source_session_id,
        operation: operation_name(operation),
        result: operation_result(result)
      }
    )

    {:reply, result, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    sessions =
      Map.reject(state.sessions, fn {_session_id, handle} ->
        Map.get(handle, :monitor_ref) == ref
      end)

    {:noreply, %{state | sessions: sessions}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp start_session(session_id, opts, state) do
    repo_path = state.repo_path

    case Sigma.Agent.RepositorySessionDynamicSupervisor.start_session(repo_path, session_id, opts) do
      {:ok, supervisor} ->
        handle = session_handle(repo_path, session_id, supervisor)
        {:reply, {:ok, handle}, put_in(state.sessions[session_id], handle)}

      {:error, {:already_started, supervisor}} ->
        handle = session_handle(repo_path, session_id, supervisor)
        {:reply, {:ok, handle}, put_in(state.sessions[session_id], handle)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp session_handle(repo_path, session_id, supervisor) do
    handle = %{
      repo_path: repo_path,
      session_id: session_id,
      repository: Sigma.Agent.Runtime.lookup(repo_path, :process),
      session_supervisor: supervisor,
      session: Sigma.Agent.Runtime.lookup(repo_path, session_id, :session),
      agent: Sigma.Agent.Runtime.lookup(repo_path, session_id, :agent),
      writer: Sigma.Agent.Runtime.lookup(repo_path, session_id, :writer),
      policy: Sigma.Agent.Runtime.lookup(repo_path, session_id, :policy),
      tasks: Sigma.Agent.Runtime.lookup(repo_path, session_id, :tasks)
    }

    Map.put(handle, :monitor_ref, Process.monitor(supervisor))
  end

  defp stale_session?(%{session: session_pid}),
    do: not (is_pid(session_pid) and Process.alive?(session_pid))

  defp running_session(state, session_id) do
    case Map.get(state.sessions, session_id) do
      %{session: session} = handle when is_pid(session) ->
        if Process.alive?(session), do: handle, else: nil

      _handle ->
        runtime_session(state.repo_path, session_id)
    end
  end

  defp runtime_session(repo_path, session_id) do
    case Sigma.Agent.Runtime.lookup(repo_path, session_id, :agent) do
      agent when is_pid(agent) ->
        %{
          agent: agent,
          session: Sigma.Agent.Runtime.lookup(repo_path, session_id, :session),
          session_supervisor: Sigma.Agent.Runtime.lookup(repo_path, session_id, :supervisor),
          writer: Sigma.Agent.Runtime.lookup(repo_path, session_id, :writer)
        }

      nil ->
        nil
    end
  end

  defp acquire_operation(nil), do: :ok

  defp acquire_operation(%{agent: agent}) when is_pid(agent) do
    Sigma.Agent.begin_session_operation(agent)
  catch
    :exit, reason -> {:error, {:session_unavailable, reason}}
  end

  defp acquire_operation(_handle), do: :ok

  defp release_operation(%{agent: agent}) when is_pid(agent) do
    Sigma.Agent.end_session_operation(agent)
  catch
    :exit, _reason -> :ok
  end

  defp release_operation(_handle), do: :ok

  defp release_after_operation(_handle, operation, {:ok, _result})
       when elem(operation, 0) in [:rename, :delete],
       do: :ok

  defp release_after_operation(handle, _operation, _result), do: release_operation(handle)

  defp safely_perform_operation(fun) do
    fun.()
  rescue
    exception -> {:error, {:session_operation_exception, exception.__struct__}}
  catch
    kind, reason -> {:error, {:session_operation_failure, kind, reason}}
  end

  defp flush_session(nil), do: :ok
  defp flush_session(%{writer: nil}), do: :ok

  defp flush_session(%{writer: writer}) do
    case apply(Sigma.Session.Writer, :flush, [writer]) do
      {:ok, _writer_status} -> :ok
      {:error, _reason} = error -> error
      other -> {:error, {:session_flush_failed, other}}
    end
  catch
    :exit, reason -> {:error, {:session_flush_failed, reason}}
  end

  defp perform_operation(_source_session_id, {:switch, target_session_id, sessions_dir, opts}) do
    with {:ok, target_path} <-
           apply(Sigma.Session.SessionFiles, :jsonl_path, [sessions_dir, target_session_id]),
         {:ok, snapshot} <- apply(Sigma.Session.Log, :snapshot, [target_path]),
         :ok <- validate_switch_snapshot(snapshot) do
      validator = Keyword.get(opts, :validate)

      case run_optional_validator(validator, snapshot) do
        :ok -> {:ok, %{session_id: target_session_id, snapshot: snapshot}}
        {:error, _reason} = error -> error
      end
    else
      {:error, :invalid_session_id} = error -> error
      {:error, reason} -> {:error, {:switch_target_invalid, reason}}
    end
  end

  defp perform_operation(
         source_session_id,
         {:fork, target_session_id, sessions_dir, message_id, opts}
       ) do
    case apply(Sigma.Session.SessionFiles, :fork, [
           sessions_dir,
           source_session_id,
           target_session_id,
           message_id,
           opts
         ]) do
      {:ok, _journal_session_id} -> {:ok, %{session_id: target_session_id}}
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_fork_result, other}}
    end
  end

  defp perform_operation(source_session_id, {:rename, target_session_id, sessions_dir, _opts}) do
    case apply(Sigma.Session.SessionFiles, :rename, [sessions_dir, source_session_id, target_session_id]) do
      :ok -> {:ok, %{session_id: target_session_id}}
      {:error, _reason} = error -> error
    end
  end

  defp perform_operation(source_session_id, {:delete, sessions_dir, _opts}) do
    case apply(Sigma.Session.SessionFiles, :delete, [sessions_dir, source_session_id]) do
      :ok -> {:ok, %{session_id: source_session_id, deleted: true}}
      {:error, _reason} = error -> error
    end
  end

  defp perform_operation(
         source_session_id,
         {:adopt, source_sessions_dir, target_sessions_dir, replacement_cwd, opts}
       ) do
    case apply(Sigma.Session.SessionFiles, :adopt, [
           source_sessions_dir,
           target_sessions_dir,
           source_session_id,
           replacement_cwd,
           opts
         ]) do
      :ok -> {:ok, %{session_id: source_session_id, cwd: Path.expand(replacement_cwd)}}
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_adoption_result, other}}
    end
  end

  defp validate_switch_snapshot(%{header: header, diagnostics: diagnostics})
       when is_map(header) do
    blocking = Enum.reject(diagnostics, &recoverable_switch_diagnostic?/1)
    if blocking == [], do: :ok, else: {:error, {:invalid_journal, blocking}}
  end

  defp validate_switch_snapshot(_snapshot), do: {:error, :missing_session_header}

  defp recoverable_switch_diagnostic?(%{kind: kind})
       when kind in [:invalid_payload, :message_repair, :trailing_incomplete_json],
       do: true

  defp recoverable_switch_diagnostic?(_diagnostic), do: false

  defp run_optional_validator(nil, _snapshot), do: :ok

  defp run_optional_validator(validator, snapshot) when is_function(validator, 1) do
    case validator.(snapshot) do
      :ok -> :ok
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_switch_validation_result, other}}
    end
  rescue
    exception -> {:error, {:switch_validation_exception, exception.__struct__}}
  catch
    kind, reason -> {:error, {:switch_validation_failure, kind, reason}}
  end

  defp operation_name({name, _target, _sessions_dir, _opts}), do: name
  defp operation_name({name, _target, _sessions_dir, _message_id, _opts}), do: name
  defp operation_name({name, _sessions_dir, _opts}), do: name
  defp operation_name(_operation), do: :unknown

  defp operation_result({:ok, _result}), do: :ok
  defp operation_result({:error, :session_busy}), do: :busy
  defp operation_result({:error, _reason}), do: :error

  defp finalize_file_operation(state, session_id, operation, {:ok, _result}, handle)
       when elem(operation, 0) in [:rename, :delete] do
    if handle && is_pid(handle[:session_supervisor]) do
      sessions_supervisor = Sigma.Agent.Runtime.lookup(state.repo_path, :sessions)

      if is_pid(sessions_supervisor) do
        DynamicSupervisor.terminate_child(sessions_supervisor, handle.session_supervisor)
      end
    end

    %{state | sessions: Map.delete(state.sessions, session_id)}
  end

  defp finalize_file_operation(state, _session_id, _operation, _result, _handle), do: state
end
