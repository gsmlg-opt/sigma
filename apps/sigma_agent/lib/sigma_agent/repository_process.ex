defmodule Sigma.Agent.RepositoryProcess do
  @moduledoc """
  Lightweight process that tracks runtime status for one repository.
  """

  use GenServer

  def start_link(opts) do
    repo_path = Keyword.fetch!(opts, :repo_path)

    GenServer.start_link(__MODULE__, repo_path,
      name: Sigma.Agent.Runtime.via(repo_path, :process)
    )
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
    {:ok, %{repo_path: repo_path, sessions: %{}, operations: %{}}}
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
    operation_key = operation_key(source_session_id, operation)

    {result, state} =
      case validate_operation_contract(operation) do
        :ok ->
          run_session_operation(state, source_session_id, operation, operation_key)

        {:error, _reason} = error ->
          {error, state}
      end

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

  defp run_session_operation(state, source_session_id, operation, operation_key) do
    case operation_key && Map.fetch(state.operations, operation_key) do
      {:ok, %{fingerprint: fingerprint, result: cached_result}} ->
        if fingerprint == operation_fingerprint(operation) do
          {cached_result, state}
        else
          {{:error, :operation_conflict}, state}
        end

      _ ->
        case recover_operation_result(source_session_id, operation) do
          {:ok, recovered_result} ->
            {recovered_result,
             cache_operation_result(state, operation_key, operation, recovered_result)}

          :not_found ->
            perform_new_operation(state, source_session_id, operation, operation_key)
        end
    end
  end

  defp perform_new_operation(state, source_session_id, operation, operation_key) do
    handle = running_session(state, source_session_id)

    result =
      case acquire_operation(handle) do
        :ok ->
          result =
            safely_perform_operation(fn ->
              with :ok <- flush_session(handle),
                   :ok <- validate_operation_checkpoint(source_session_id, operation),
                   :ok <- persist_operation_started(handle, source_session_id, operation) do
                performed =
                  perform_with_terminal_drain(
                    state.repo_path,
                    source_session_id,
                    operation,
                    fn -> perform_operation(source_session_id, operation, handle) end
                  )

                case persist_operation_result(handle, source_session_id, operation, performed) do
                  :ok ->
                    performed

                  {:error, reason} ->
                    {:error, {:operation_result_persistence_failed, performed, reason}}
                end
              end
            end)

          release_after_operation(handle, operation, result)
          result

        {:error, _reason} = error ->
          error
      end

    state =
      finalize_file_operation(
        state,
        source_session_id,
        operation,
        operation_effect_result(result),
        handle
      )

    state = cache_operation_result(state, operation_key, operation, result)
    {result, state}
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
       when elem(operation, 0) in [:rename, :delete, :adopt],
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

  defp perform_with_terminal_drain(repo_path, source_session_id, operation, perform) do
    case terminal_drain_policy(source_session_id, operation) do
      nil ->
        perform.()

      {mode, opts} ->
        with {:ok, token} <-
               Sigma.Agent.Terminals.begin_drain(repo_path, source_session_id, mode, opts) do
          result =
            with :ok <-
                   Sigma.Agent.Terminals.cleanup_all(
                     token,
                     Keyword.get(opts, :terminal_cleanup_timeout_ms, 15_000)
                   ) do
              perform.()
            end

          if match?({:error, _reason}, result),
            do: Sigma.Agent.Terminals.release_drain(token)

          result
        end
    end
  end

  defp terminal_drain_policy(_source_session_id, {:delete, _sessions_dir, opts}),
    do: {:delete, opts}

  defp terminal_drain_policy(source_session_id, {:rename, target_session_id, _dir, opts})
       when source_session_id != target_session_id,
       do: {:identity_change, opts}

  defp terminal_drain_policy(
         _source_session_id,
         {:adopt, _source_dir, _target_dir, _cwd, opts}
       ),
       do: {:identity_change, opts}

  defp terminal_drain_policy(_source_session_id, _operation), do: nil

  defp perform_switch_operation(target_session_id, sessions_dir, opts) do
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
         _source_session_id,
         {:switch, target_session_id, sessions_dir, opts},
         _handle
       ),
       do: perform_switch_operation(target_session_id, sessions_dir, opts)

  defp perform_operation(source_session_id, {:retry, sessions_dir, message_id, opts}, handle) do
    admission_ref = make_ref()

    with %{agent: agent, writer: writer} when is_pid(agent) and is_pid(writer) <- handle,
         {:ok, source_path} <-
           apply(Sigma.Session.SessionFiles, :jsonl_path, [sessions_dir, source_session_id]),
         {:ok, checkpoint} <-
           apply(Sigma.Session.Log, :retry_checkpoint, [source_path, message_id]),
         :ok <- validate_retry_checkpoint(checkpoint, source_session_id, opts),
         {:ok, info} <- admit_retry(agent, writer, checkpoint, admission_ref) do
      {:ok,
       %{
         session_id: source_session_id,
         message_id: info.message_id,
         turn_id: info.turn_id,
         retry_of_turn_id: checkpoint.retry_of_turn_id,
         source_entry_id: checkpoint.source_entry_id,
         checkpoint_entry_id: checkpoint.checkpoint_entry_id
       }}
    else
      nil -> {:error, :session_not_running}
      {:error, _reason} = error -> error
      _ -> {:error, :session_not_running}
    end
  end

  defp perform_operation(_source_session_id, {:compact, _sessions_dir, _opts}, handle) do
    with %{agent: agent, writer: writer} when is_pid(agent) and is_pid(writer) <- handle,
         {:ok, %{active_leaf_id: source_leaf_id}} <-
           apply(Sigma.Session.Writer, :flush, [writer]) do
      Sigma.Agent.compact(agent, source_leaf_id: source_leaf_id)
    else
      nil -> {:error, :session_not_running}
      {:error, _reason} = error -> error
      _ -> {:error, :session_not_running}
    end
  end

  defp perform_operation(source_session_id, operation, _handle),
    do: perform_file_operation(source_session_id, operation)

  defp admit_retry(agent, writer, checkpoint, admission_ref) do
    with :ok <-
           apply(Sigma.Session.Writer, :checkout, [
             writer,
             checkpoint.checkpoint_entry_id,
             checkpoint.source_leaf_id
           ]) do
      result =
        with {:accepted, info} <-
               Sigma.Agent.retry(
                 agent,
                 checkpoint.context_messages,
                 checkpoint.content,
                 checkpoint.retry_of_turn_id,
                 attachments: checkpoint.attachments,
                 retry_admission_notify: {self(), admission_ref}
               ),
             :ok <- await_retry_admission(admission_ref) do
          {:ok, info}
        else
          {:rejected, reason} -> {:error, reason}
          {:error, _reason} = error -> error
        end

      if match?({:error, _reason}, result) do
        _ =
          apply(Sigma.Session.Writer, :checkout, [
            writer,
            checkpoint.source_leaf_id,
            checkpoint.checkpoint_entry_id
          ])
      end

      result
    end
  end

  defp await_retry_admission(ref) do
    receive do
      {:retry_admission, ^ref, :committed} -> :ok
      {:retry_admission, ^ref, {:error, reason}} -> {:error, {:retry_rejected, reason}}
    after
      30_000 -> {:error, :retry_admission_timeout}
    end
  end

  defp validate_retry_checkpoint(checkpoint, source_session_id, opts) do
    expected_revision = Keyword.get(opts, :expected_source_revision)
    expected_leaf = Keyword.get(opts, :expected_source_leaf)
    selected_provider = Keyword.get(opts, :provider_id)
    selected_model = Keyword.get(opts, :model_id)

    cond do
      not is_nil(expected_revision) and expected_revision != checkpoint.source_revision ->
        {:error,
         {:revision_conflict,
          %{
            expected: expected_revision,
            actual: checkpoint.source_revision,
            source_session_id: source_session_id
          }}}

      not is_nil(expected_leaf) and expected_leaf != checkpoint.source_leaf_id ->
        {:error,
         {:leaf_conflict,
          %{
            expected: expected_leaf,
            actual: checkpoint.source_leaf_id,
            source_session_id: source_session_id
          }}}

      true ->
        with :ok <- validate_retry_attachments(checkpoint) do
          validate_retry_model(checkpoint, selected_provider, selected_model)
        end
    end
  end

  defp validate_retry_attachments(%{attachments: attachments}) when attachments in [nil, []],
    do: :ok

  defp validate_retry_attachments(%{attachments: attachments, content: content})
       when is_list(attachments) and is_list(content) do
    materialized_images =
      Enum.count(content, fn
        %{type: :image, data: data} when is_binary(data) and data != "" -> true
        %{"type" => "image", "data" => data} when is_binary(data) and data != "" -> true
        _part -> false
      end)

    if materialized_images >= length(attachments),
      do: :ok,
      else: {:error, :retry_attachments_unavailable}
  end

  defp validate_retry_attachments(_checkpoint), do: {:error, :retry_attachments_unavailable}

  defp validate_retry_model(checkpoint, nil, nil) do
    original = {checkpoint.provider_id, checkpoint.model_id}
    current = {checkpoint.current_provider_id, checkpoint.current_model_id}

    if original == current do
      :ok
    else
      {:error, {:retry_model_selection_required, retry_model_details(checkpoint)}}
    end
  end

  defp validate_retry_model(_checkpoint, provider_id, model_id)
       when not is_binary(provider_id) or provider_id == "" or not is_binary(model_id) or
              model_id == "",
       do: {:error, :invalid_retry_model_selection}

  defp validate_retry_model(checkpoint, provider_id, model_id) do
    if {provider_id, model_id} ==
         {checkpoint.current_provider_id, checkpoint.current_model_id} do
      :ok
    else
      {:error, {:retry_replacement_model_unavailable, retry_model_details(checkpoint)}}
    end
  end

  defp retry_model_details(checkpoint) do
    %{
      original_provider_id: checkpoint.provider_id,
      original_model_id: checkpoint.model_id,
      current_provider_id: checkpoint.current_provider_id,
      current_model_id: checkpoint.current_model_id
    }
  end

  defp perform_file_operation(
         source_session_id,
         {:fork, target_session_id, sessions_dir, message_id, opts}
       ) do
    with result <-
           apply(Sigma.Session.SessionFiles, :fork, [
             sessions_dir,
             source_session_id,
             target_session_id,
             message_id,
             opts
           ]) do
      case result do
        {:ok, _journal_session_id} -> {:ok, %{session_id: target_session_id}}
        {:error, _reason} = error -> error
        other -> {:error, {:invalid_fork_result, other}}
      end
    end
  end

  defp perform_file_operation(
         source_session_id,
         {:rename, target_session_id, sessions_dir, _opts}
       ) do
    case apply(Sigma.Session.SessionFiles, :rename, [
           sessions_dir,
           source_session_id,
           target_session_id
         ]) do
      :ok -> {:ok, %{session_id: target_session_id}}
      {:error, _reason} = error -> error
    end
  end

  defp perform_file_operation(source_session_id, {:delete, sessions_dir, _opts}) do
    case apply(Sigma.Session.SessionFiles, :delete, [sessions_dir, source_session_id]) do
      :ok -> {:ok, %{session_id: source_session_id, deleted: true}}
      {:error, _reason} = error -> error
    end
  end

  defp perform_file_operation(
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

  defp validate_operation_checkpoint(
         source_session_id,
         {:fork, _target_session_id, sessions_dir, _message_id, opts}
       ),
       do: validate_source_checkpoint(sessions_dir, source_session_id, opts)

  defp validate_operation_checkpoint(source_session_id, {:compact, sessions_dir, opts}),
    do: validate_source_checkpoint(sessions_dir, source_session_id, opts)

  defp validate_operation_checkpoint(_source_session_id, _operation), do: :ok

  # A fork is selected against a persisted source checkpoint. Re-read it after
  # the operation admission/flush so a stale browser cannot silently fork a
  # newer active leaf.
  defp validate_source_checkpoint(sessions_dir, source_session_id, opts) do
    expected_revision = Keyword.get(opts, :expected_source_revision)
    expected_leaf = Keyword.get(opts, :expected_source_leaf)

    if is_nil(expected_revision) and is_nil(expected_leaf) do
      :ok
    else
      with {:ok, source_path} <-
             apply(Sigma.Session.SessionFiles, :jsonl_path, [sessions_dir, source_session_id]),
           {:ok, snapshot} <- apply(Sigma.Session.Log, :snapshot, [source_path]) do
        actual_revision = snapshot_revision(snapshot)
        actual_leaf = snapshot.active_leaf_id

        cond do
          not is_nil(expected_revision) and expected_revision != actual_revision ->
            {:error,
             {:revision_conflict,
              %{
                expected: expected_revision,
                actual: actual_revision,
                source_session_id: source_session_id
              }}}

          not is_nil(expected_leaf) and expected_leaf != actual_leaf ->
            {:error,
             {:leaf_conflict,
              %{
                expected: expected_leaf,
                actual: actual_leaf,
                source_session_id: source_session_id
              }}}

          true ->
            :ok
        end
      else
        {:error, reason} -> {:error, {:source_checkpoint_unavailable, reason}}
      end
    end
  end

  defp snapshot_revision(snapshot) do
    length(snapshot.branch_entry_ids) + if(is_map(snapshot.header), do: 1, else: 0)
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

  defp operation_key(source_session_id, operation) do
    case operation_id(operation_opts(operation)) do
      operation_id when is_binary(operation_id) and operation_id != "" ->
        {source_session_id, operation_id}

      _ ->
        nil
    end
  end

  defp operation_opts({:switch, _target, _sessions_dir, opts}), do: opts
  defp operation_opts({:retry, _sessions_dir, _message_id, opts}), do: opts
  defp operation_opts({:compact, _sessions_dir, opts}), do: opts
  defp operation_opts({:fork, _target, _sessions_dir, _message_id, opts}), do: opts
  defp operation_opts({:rename, _target, _sessions_dir, opts}), do: opts
  defp operation_opts({:delete, _sessions_dir, opts}), do: opts
  defp operation_opts({:adopt, _source_dir, _target_dir, _cwd, opts}), do: opts
  defp operation_opts(_operation), do: []

  defp validate_operation_contract(operation)
       when elem(operation, 0) in [:retry, :fork, :compact] do
    opts = operation_opts(operation)

    cond do
      not (is_binary(operation_id(opts)) and operation_id(opts) != "") ->
        {:error, :operation_id_required}

      not Keyword.has_key?(opts, :expected_source_revision) ->
        {:error, :expected_source_revision_required}

      not valid_expected_revision?(Keyword.get(opts, :expected_source_revision)) ->
        {:error, :invalid_expected_source_revision}

      not Keyword.has_key?(opts, :expected_source_leaf) ->
        {:error, :expected_source_leaf_required}

      not valid_expected_leaf?(Keyword.get(opts, :expected_source_leaf)) ->
        {:error, :invalid_expected_source_leaf}

      true ->
        :ok
    end
  end

  defp validate_operation_contract(_operation), do: :ok

  defp valid_expected_revision?(revision), do: is_integer(revision) and revision >= 0
  defp valid_expected_leaf?(nil), do: true
  defp valid_expected_leaf?(leaf), do: is_binary(leaf) and leaf != ""

  defp operation_id(opts) when is_list(opts), do: Keyword.get(opts, :operation_id)
  defp operation_id(_opts), do: nil

  defp operation_fingerprint({:switch, target, sessions_dir, _opts}),
    do: :erlang.phash2({:switch, target, sessions_dir})

  defp operation_fingerprint({:fork, target, sessions_dir, message_id, opts}),
    do:
      :erlang.phash2(
        {:fork, target, sessions_dir, message_id, Keyword.get(opts, :expected_source_revision),
         Keyword.get(opts, :expected_source_leaf)}
      )

  defp operation_fingerprint({:retry, sessions_dir, message_id, opts}),
    do:
      :erlang.phash2(
        {:retry, sessions_dir, message_id, Keyword.get(opts, :expected_source_revision),
         Keyword.get(opts, :expected_source_leaf), Keyword.get(opts, :provider_id),
         Keyword.get(opts, :model_id)}
      )

  defp operation_fingerprint({:compact, sessions_dir, opts}),
    do:
      :erlang.phash2(
        {:compact, sessions_dir, Keyword.get(opts, :expected_source_revision),
         Keyword.get(opts, :expected_source_leaf)}
      )

  defp operation_fingerprint({:rename, target, sessions_dir, _opts}),
    do: :erlang.phash2({:rename, target, sessions_dir})

  defp operation_fingerprint({:delete, sessions_dir, _opts}),
    do: :erlang.phash2({:delete, sessions_dir})

  defp operation_fingerprint({:adopt, source_dir, target_dir, cwd, _opts}),
    do: :erlang.phash2({:adopt, source_dir, target_dir, cwd})

  defp operation_fingerprint(operation), do: :erlang.phash2(operation)

  defp recover_operation_result(source_session_id, operation) do
    operation_id = operation_id(operation_opts(operation))
    sessions_dir = operation_sessions_dir(operation)

    if is_binary(operation_id) and operation_id != "" and is_binary(sessions_dir) do
      with {:ok, path} <-
             apply(Sigma.Session.SessionFiles, :jsonl_path, [sessions_dir, source_session_id]),
           {:ok, records} <- apply(Sigma.Session.Log, :operation_results, [path]) do
        case Enum.find(records, fn record ->
               (record[:operation_id] || record["operation_id"]) == operation_id and
                 operation_record_matches?(record, operation)
             end) do
          nil ->
            if Enum.any?(records, fn record ->
                 (record[:operation_id] || record["operation_id"]) == operation_id
               end) do
              {:ok, {:error, :operation_conflict}}
            else
              case apply(Sigma.Session.Log, :operation_interrupted?, [
                     path,
                     operation_id,
                     operation_fingerprint(operation),
                     Sigma.Session.Storage.JsonlFile
                   ]) do
                {:ok, true} -> {:ok, {:error, {:operation_interrupted, operation_id}}}
                {:error, :operation_conflict} -> {:ok, {:error, :operation_conflict}}
                _ -> :not_found
              end
            end

          record ->
            recover_recorded_result(record)
        end
      else
        _ -> :not_found
      end
    else
      :not_found
    end
  end

  defp recover_recorded_result(record) do
    case record[:status] || record["status"] do
      :completed ->
        case record[:result] || record["result"] do
          result when is_map(result) -> {:ok, {:ok, normalize_operation_result(result)}}
          _ -> :not_found
        end

      :failed ->
        case record[:error_term] || record["error_term"] do
          encoded when is_binary(encoded) ->
            with {:ok, binary} <- Base.url_decode64(encoded, padding: false) do
              {:ok, {:error, :erlang.binary_to_term(binary, [:safe])}}
            else
              _ -> :not_found
            end

          _ ->
            :not_found
        end

      _ ->
        :not_found
    end
  rescue
    _ -> :not_found
  end

  defp operation_record_matches?(record, operation) do
    fingerprint = record[:fingerprint] || record["fingerprint"]
    is_nil(fingerprint) or fingerprint == operation_fingerprint(operation)
  end

  defp normalize_operation_result(result) do
    Map.new(result, fn {key, value} ->
      {case key do
         "session_id" -> :session_id
         "deleted" -> :deleted
         "cwd" -> :cwd
         "snapshot" -> :snapshot
         "message_id" -> :message_id
         "turn_id" -> :turn_id
         "retry_of_turn_id" -> :retry_of_turn_id
         "source_entry_id" -> :source_entry_id
         "checkpoint_entry_id" -> :checkpoint_entry_id
         "compaction_id" -> :compaction_id
         "summary_id" -> :summary_id
         "source_leaf_id" -> :source_leaf_id
         _ -> key
       end, value}
    end)
  end

  defp operation_sessions_dir({:switch, _target, sessions_dir, _opts}), do: sessions_dir
  defp operation_sessions_dir({:retry, sessions_dir, _message, _opts}), do: sessions_dir
  defp operation_sessions_dir({:compact, sessions_dir, _opts}), do: sessions_dir
  defp operation_sessions_dir({:fork, _target, sessions_dir, _message, _opts}), do: sessions_dir
  defp operation_sessions_dir({:rename, _target, sessions_dir, _opts}), do: sessions_dir
  defp operation_sessions_dir({:delete, sessions_dir, _opts}), do: sessions_dir
  defp operation_sessions_dir(_operation), do: nil

  defp persist_operation_started(%{writer: writer}, source_session_id, operation)
       when is_pid(writer) do
    case operation_id(operation_opts(operation)) do
      id when is_binary(id) and id != "" ->
        attrs = %{
          operation_id: id,
          fingerprint: operation_fingerprint(operation),
          operation: operation_name(operation),
          source_session_id: source_session_id,
          status: :started
        }

        case apply(Sigma.Session.Writer, :append, [writer, {:operation_started, attrs}]) do
          {:ok, _entry_id} -> :ok
          {:error, reason} -> {:error, {:operation_start_persistence_failed, reason}}
          other -> {:error, {:operation_start_persistence_failed, other}}
        end

      _ ->
        :ok
    end
  catch
    :exit, reason -> {:error, {:operation_start_persistence_failed, reason}}
  end

  defp persist_operation_started(_handle, _source_session_id, _operation), do: :ok

  defp persist_operation_result(%{writer: writer}, source_session_id, operation, result)
       when is_pid(writer) do
    case operation_record(source_session_id, operation, result) do
      nil ->
        :ok

      attrs ->
        try do
          case apply(Sigma.Session.Writer, :append, [writer, {:operation_finished, attrs}]) do
            {:ok, _entry_id} -> :ok
            {:error, reason} -> {:error, reason}
            other -> {:error, other}
          end
        catch
          kind, reason -> {:error, {kind, reason}}
        end
    end
  end

  defp persist_operation_result(_handle, _source_session_id, _operation, _result), do: :ok

  defp operation_record(source_session_id, operation, {:ok, result}) when is_map(result) do
    case operation_id(operation_opts(operation)) do
      id when is_binary(id) and id != "" ->
        %{
          operation_id: id,
          fingerprint: operation_fingerprint(operation),
          operation: operation_name(operation),
          source_session_id: source_session_id,
          status: :completed,
          result: result
        }

      _ ->
        nil
    end
  end

  defp operation_record(source_session_id, operation, {:error, reason}) do
    case operation_id(operation_opts(operation)) do
      id when is_binary(id) and id != "" ->
        %{
          operation_id: id,
          fingerprint: operation_fingerprint(operation),
          operation: operation_name(operation),
          source_session_id: source_session_id,
          status: :failed,
          error: inspect(reason, limit: 100),
          error_term: reason |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)
        }

      _ ->
        nil
    end
  end

  defp operation_record(_source_session_id, _operation, _result), do: nil

  defp cache_operation_result(state, nil, _operation, _result), do: state

  defp cache_operation_result(state, _operation_key, _operation, {:error, :session_busy}),
    do: state

  defp cache_operation_result(state, operation_key, operation, result) do
    put_in(state.operations[operation_key], %{
      fingerprint: operation_fingerprint(operation),
      result: result
    })
  end

  defp operation_result({:ok, _result}), do: :ok
  defp operation_result({:error, :session_busy}), do: :busy
  defp operation_result({:error, _reason}), do: :error

  defp operation_effect_result(
         {:error, {:operation_result_persistence_failed, performed, _reason}}
       ),
       do: performed

  defp operation_effect_result(result), do: result

  defp finalize_file_operation(state, session_id, operation, {:ok, _result}, handle)
       when elem(operation, 0) in [:rename, :delete, :adopt] do
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
