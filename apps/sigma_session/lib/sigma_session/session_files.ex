defmodule Sigma.Session.SessionFiles do
  @moduledoc """
  Safe file operations for session JSONL logs and sidecar metadata.
  """

  alias Sigma.Session.Log
  alias Sigma.Session.Storage.JsonlFile

  def valid_session_id?(id) when is_binary(id) do
    id != "" and id not in [".", ".."] and Path.type(id) == :relative and
      Path.basename(id) == id and not String.contains?(id, ["/", "\\", <<0>>])
  end

  def valid_session_id?(_id), do: false

  def jsonl_path(sessions_dir, id), do: safe_path(sessions_dir, id, ".jsonl")

  def meta_path(sessions_dir, id), do: safe_path(sessions_dir, id, ".meta.json")

  @doc "Creates a new journal and sidecar without overwriting an existing session."
  def create(sessions_dir, id, metadata, cwd, opts \\ [])

  def create(sessions_dir, id, metadata, cwd, opts)
      when is_map(metadata) and is_binary(cwd) and cwd != "" do
    with {:ok, target_jsonl_path} <- jsonl_path(sessions_dir, id),
         {:ok, target_meta_path} <- meta_path(sessions_dir, id),
         :ok <- ensure_absent(target_jsonl_path),
         :ok <- ensure_absent(target_meta_path),
         {:ok, encoded_metadata} <- encode_metadata(metadata),
         {:ok, temp_jsonl_path} <- unused_temp_path(target_jsonl_path) do
      create_from_temp(
        temp_jsonl_path,
        target_jsonl_path,
        target_meta_path,
        encoded_metadata,
        cwd,
        Keyword.get(opts, :model)
      )
    end
  end

  def create(_sessions_dir, _id, _metadata, _cwd, _opts),
    do: {:error, :invalid_session_metadata}

  def rename(sessions_dir, old_id, new_id) do
    with {:ok, old_jsonl_path} <- jsonl_path(sessions_dir, old_id),
         {:ok, new_jsonl_path} <- jsonl_path(sessions_dir, new_id),
         {:ok, old_meta_path} <- meta_path(sessions_dir, old_id),
         {:ok, new_meta_path} <- meta_path(sessions_dir, new_id),
         :ok <- ensure_absent(new_jsonl_path),
         :ok <- ensure_absent(new_meta_path),
         :ok <-
           run_operation_hook(:before_jsonl_move, %{
             source: old_jsonl_path,
             target: new_jsonl_path
           }),
         :ok <- move_file_no_overwrite(old_jsonl_path, new_jsonl_path),
         :ok <-
           rename_metadata_with_rollback(
             old_meta_path,
             new_meta_path,
             new_jsonl_path,
             old_jsonl_path
           ) do
      :ok
    end
  end

  def delete(sessions_dir, id) do
    with {:ok, jsonl_path} <- jsonl_path(sessions_dir, id),
         {:ok, meta_path} <- meta_path(sessions_dir, id),
         :ok <- rm_optional(jsonl_path),
         :ok <- rm_optional(meta_path) do
      :ok
    end
  end

  def fork(sessions_dir, source_id, target_id, message_id, opts \\ []) do
    with {:ok, source_jsonl_path} <- jsonl_path(sessions_dir, source_id),
         {:ok, target_jsonl_path} <- jsonl_path(sessions_dir, target_id),
         {:ok, source_meta_path} <- meta_path(sessions_dir, source_id),
         {:ok, target_meta_path} <- meta_path(sessions_dir, target_id),
         :ok <- require_regular(source_jsonl_path),
         :ok <- ensure_absent(target_jsonl_path),
         :ok <- ensure_absent(target_meta_path),
         {:ok, metadata} <- read_metadata(source_meta_path),
         {:ok, cwd} <- fork_cwd(metadata, source_jsonl_path, opts),
         {:ok, new_session_id} <-
           Log.fork_at_message(source_jsonl_path, target_jsonl_path, message_id, cwd),
         :ok <-
           write_fork_metadata_or_cleanup(metadata, target_meta_path, target_jsonl_path, opts) do
      {:ok, new_session_id}
    end
  end

  @doc """
  Adopts a session into a validated replacement working directory.

  Conversation bytes are copied unchanged. Structural sidecar metadata is
  preserved with only `cwd` replaced, and cross-directory publication rolls
  back if source cleanup cannot complete.
  """
  def adopt(source_sessions_dir, target_sessions_dir, id, replacement_cwd, opts \\ []) do
    replacement_cwd = Path.expand(replacement_cwd)

    with true <- File.dir?(replacement_cwd),
         :ok <- File.mkdir_p(target_sessions_dir),
         {:ok, source_jsonl_path} <- jsonl_path(source_sessions_dir, id),
         {:ok, source_meta_path} <- meta_path(source_sessions_dir, id),
         {:ok, target_jsonl_path} <- jsonl_path(target_sessions_dir, id),
         {:ok, target_meta_path} <- meta_path(target_sessions_dir, id),
         :ok <- require_regular(source_jsonl_path),
         {:ok, metadata} <- read_metadata(source_meta_path),
         {:ok, metadata_content} <- adopted_metadata(metadata, replacement_cwd) do
      if source_jsonl_path == target_jsonl_path do
        adopt_in_place(target_meta_path, metadata_content, opts)
      else
        adopt_across_directories(
          source_jsonl_path,
          source_meta_path,
          target_jsonl_path,
          target_meta_path,
          metadata_content,
          opts
        )
      end
    else
      false -> {:error, :invalid_replacement_cwd}
      {:error, _reason} = error -> error
    end
  end

  defp safe_path(sessions_dir, id, suffix) do
    if valid_session_id?(id) do
      {:ok, Path.join(sessions_dir, id <> suffix)}
    else
      {:error, :invalid_session_id}
    end
  end

  defp encode_metadata(metadata) do
    case Jason.encode(metadata) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, reason} -> {:error, {:metadata_encode_failed, reason}}
    end
  end

  defp create_from_temp(
         temp_jsonl_path,
         target_jsonl_path,
         target_meta_path,
         encoded_metadata,
         cwd,
         model
       ) do
    with :ok <- build_new_session_log(temp_jsonl_path, cwd, model) do
      case write_file_no_overwrite(target_meta_path, encoded_metadata, :before_meta_publish) do
        :ok ->
          publish_created_jsonl_or_rollback(
            temp_jsonl_path,
            target_jsonl_path,
            target_meta_path
          )

        {:error, _reason} = error ->
          cleanup_new_session_temp(temp_jsonl_path, error)
      end
    end
  end

  defp build_new_session_log(temp_jsonl_path, cwd, model) do
    result =
      with :ok <- File.write(temp_jsonl_path, ""),
           :ok <- Log.ensure_session_header(temp_jsonl_path, cwd),
           :ok <- append_initial_model(temp_jsonl_path, model) do
        :ok
      end

    case result do
      :ok -> :ok
      {:error, _reason} = error -> cleanup_new_session_temp(temp_jsonl_path, error)
    end
  end

  defp append_initial_model(_jsonl_path, nil), do: :ok

  defp append_initial_model(jsonl_path, {provider_id, model_id}) do
    case Log.append_model_change(jsonl_path, provider_id, model_id) do
      {:ok, _entry_id} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp append_initial_model(_jsonl_path, _model), do: {:error, :invalid_initial_model}

  defp cleanup_new_session_temp(temp_jsonl_path, error) do
    case rm_optional(temp_jsonl_path) do
      :ok -> error
      cleanup_error -> {:error, {:session_create_cleanup_failed, error, cleanup_error}}
    end
  end

  defp publish_created_jsonl_or_rollback(temp_jsonl_path, jsonl_path, meta_path) do
    case publish_temp_file(temp_jsonl_path, jsonl_path, :before_jsonl_publish) do
      :ok ->
        :ok

      {:error, _reason} = error ->
        case rm_optional(meta_path) do
          :ok -> error
          rollback_error -> {:error, {:session_create_rollback_failed, error, rollback_error}}
        end
    end
  end

  defp require_regular(path) do
    if File.regular?(path), do: :ok, else: {:error, :enoent}
  end

  defp ensure_absent(path) do
    case File.lstat(path) do
      {:ok, _stat} -> {:error, :already_exists}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp move_optional_no_overwrite(source_path, target_path) do
    case File.lstat(source_path) do
      {:ok, _stat} -> move_file_no_overwrite(source_path, target_path)
      {:error, :enoent} -> ensure_absent(target_path)
      {:error, reason} -> {:error, reason}
    end
  end

  defp rename_metadata_with_rollback(old_meta_path, new_meta_path, new_jsonl_path, old_jsonl_path) do
    with :ok <-
           run_operation_hook(:before_meta_move, %{
             source: old_meta_path,
             target: new_meta_path
           }),
         :ok <- move_optional_no_overwrite(old_meta_path, new_meta_path) do
      :ok
    else
      {:error, _reason} = error ->
        case rollback_jsonl_move(new_jsonl_path, old_jsonl_path) do
          :ok -> error
          rollback_error -> {:error, {:rename_rollback_failed, error, rollback_error}}
        end
    end
  end

  defp rollback_jsonl_move(new_jsonl_path, old_jsonl_path) do
    case {File.lstat(new_jsonl_path), File.lstat(old_jsonl_path)} do
      {{:ok, _new_stat}, {:error, :enoent}} ->
        move_file_no_overwrite(new_jsonl_path, old_jsonl_path)

      {{:error, :enoent}, {:ok, _old_stat}} ->
        :ok

      state ->
        {:error, {:unexpected_rename_rollback_state, state}}
    end
  end

  defp move_file_no_overwrite(source_path, target_path) do
    case File.ln(source_path, target_path) do
      :ok ->
        case File.rm(source_path) do
          :ok ->
            :ok

          {:error, _reason} = error ->
            rm_optional(target_path)
            error
        end

      {:error, :eexist} ->
        {:error, :already_exists}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp rm_optional(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp read_metadata(path) do
    case File.read(path) do
      {:ok, content} ->
        {:ok,
         %{
           exists?: true,
           raw: content,
           data: decode_metadata(content)
         }}

      {:error, :enoent} ->
        {:ok, %{exists?: false, raw: nil, data: nil}}

      {:error, _reason} = error ->
        error
    end
  end

  defp decode_metadata(content) do
    case Jason.decode(content) do
      {:ok, metadata} when is_map(metadata) -> metadata
      _ -> nil
    end
  end

  defp adopted_metadata(%{exists?: true, data: nil}, _replacement_cwd),
    do: {:error, :invalid_session_metadata}

  defp adopted_metadata(%{data: data}, replacement_cwd) when is_map(data) do
    Jason.encode(Map.put(data, "cwd", replacement_cwd), pretty: true)
  end

  defp adopted_metadata(%{exists?: false}, replacement_cwd) do
    Jason.encode(%{"cwd" => replacement_cwd}, pretty: true)
  end

  defp adopt_in_place(meta_path, metadata_content, opts) do
    with {:ok, temp_path} <- unused_temp_path(meta_path) do
      result =
        with :ok <- File.write(temp_path, metadata_content),
             :ok <- run_adopt_hook(opts, :before_adopt_meta_replace, %{target: meta_path}),
             :ok <- File.rename(temp_path, meta_path) do
          :ok
        end

      if result != :ok, do: rm_optional(temp_path)
      result
    end
  end

  defp adopt_across_directories(
         source_jsonl_path,
         source_meta_path,
         target_jsonl_path,
         target_meta_path,
         metadata_content,
         opts
       ) do
    with :ok <- ensure_absent(target_jsonl_path),
         :ok <- ensure_absent(target_meta_path),
         {:ok, temp_jsonl_path} <- unused_temp_path(target_jsonl_path) do
      case prepare_adoption_metadata_temp(
             source_jsonl_path,
             temp_jsonl_path,
             target_meta_path,
             metadata_content
           ) do
        {:ok, temp_meta_path} ->
          publish_adoption(
            source_jsonl_path,
            source_meta_path,
            target_jsonl_path,
            target_meta_path,
            temp_jsonl_path,
            temp_meta_path,
            opts
          )

        {:error, _reason} = error ->
          rm_optional(temp_jsonl_path)
          error
      end
    end
  end

  defp prepare_adoption_metadata_temp(
         source_jsonl_path,
         temp_jsonl_path,
         target_meta_path,
         metadata_content
       ) do
    with :ok <- File.cp(source_jsonl_path, temp_jsonl_path),
         {:ok, temp_meta_path} <- unused_temp_path(target_meta_path) do
      case File.write(temp_meta_path, metadata_content) do
        :ok -> {:ok, temp_meta_path}
        {:error, _reason} = error ->
          rm_optional(temp_meta_path)
          error
      end
    end
  end

  defp publish_adoption(
         source_jsonl_path,
         source_meta_path,
         target_jsonl_path,
         target_meta_path,
         temp_jsonl_path,
         temp_meta_path,
         opts
       ) do
    case publish_temp_file(temp_meta_path, target_meta_path, :before_meta_publish) do
      :ok ->
        case publish_temp_file(temp_jsonl_path, target_jsonl_path, :before_jsonl_publish) do
          :ok ->
            finish_published_adoption(
              source_jsonl_path,
              source_meta_path,
              target_jsonl_path,
              target_meta_path,
              temp_jsonl_path,
              temp_meta_path,
              opts
            )

          {:error, _reason} = error ->
            meta_cleanup = rm_optional(target_meta_path)
            temp_cleanup = rm_optional(temp_jsonl_path)

            if meta_cleanup == :ok and temp_cleanup == :ok do
              error
            else
              {:error, {:adoption_publication_rollback_failed, error, meta_cleanup, temp_cleanup}}
            end
        end

      {:error, _reason} = error ->
        rm_optional(temp_jsonl_path)
        rm_optional(temp_meta_path)
        error
    end
  end

  defp finish_published_adoption(
         source_jsonl_path,
         source_meta_path,
         target_jsonl_path,
         target_meta_path,
         temp_jsonl_path,
         temp_meta_path,
         opts
       ) do
    result =
      with :ok <- run_adopt_hook(opts, :before_adopt_source_cleanup, %{source: source_jsonl_path}),
           :ok <- File.rm(source_jsonl_path),
           :ok <- rm_optional(source_meta_path) do
        :ok
      end

    case result do
      :ok ->
        :ok

      {:error, _reason} = error ->
        rollback_adoption(
          source_jsonl_path,
          source_meta_path,
          target_jsonl_path,
          target_meta_path,
          temp_jsonl_path,
          temp_meta_path,
          error
        )
    end
  end

  defp rollback_adoption(
         source_jsonl_path,
         _source_meta_path,
         target_jsonl_path,
         target_meta_path,
         temp_jsonl_path,
         temp_meta_path,
         error
       ) do
    restore_result =
      if File.exists?(source_jsonl_path) do
        :ok
      else
        File.cp(target_jsonl_path, source_jsonl_path)
      end

    cleanup_results =
      Enum.map(
        [target_jsonl_path, target_meta_path, temp_jsonl_path, temp_meta_path],
        &rm_optional/1
      )

    if restore_result == :ok and Enum.all?(cleanup_results, &(&1 == :ok)) do
      error
    else
      {:error, {:adoption_rollback_failed, error, restore_result, cleanup_results}}
    end
  end

  defp run_adopt_hook(opts, event, paths) do
    case Keyword.get(opts, :operation_hook) do
      hook when is_function(hook, 2) -> hook.(event, paths)
      nil -> :ok
      _hook -> {:error, :invalid_operation_hook}
    end
  end

  defp fork_cwd(metadata, source_jsonl_path, opts) do
    case Keyword.get(opts, :rewrite_cwd) do
      cwd when is_binary(cwd) ->
        {:ok, cwd}

      _ ->
        case metadata_cwd(metadata) || source_log_cwd(source_jsonl_path) do
          nil -> {:ok, Keyword.get(opts, :fallback_cwd, "")}
          cwd -> {:ok, cwd}
        end
    end
  end

  defp metadata_cwd(%{data: %{"cwd" => cwd}}) when is_binary(cwd), do: cwd
  defp metadata_cwd(_metadata), do: nil

  defp source_log_cwd(source_jsonl_path) do
    {:ok, entries} = JsonlFile.read(source_jsonl_path)

    Enum.find_value(entries, fn
      %{"type" => "session", "cwd" => cwd} when is_binary(cwd) -> cwd
      _entry -> nil
    end)
  end

  defp write_fork_metadata_or_cleanup(metadata, target_meta_path, target_jsonl_path, opts) do
    case write_fork_metadata(metadata, target_meta_path, opts) do
      :ok ->
        :ok

      {:error, _reason} = error ->
        case rm_optional(target_jsonl_path) do
          :ok -> error
          cleanup_error -> {:error, {:fork_rollback_failed, error, cleanup_error}}
        end
    end
  end

  defp write_fork_metadata(%{exists?: false}, target_meta_path, _opts) do
    with :ok <- run_operation_hook(:before_meta_publish, %{target: target_meta_path}) do
      ensure_absent(target_meta_path)
    end
  end

  defp write_fork_metadata(%{data: data, raw: raw}, target_meta_path, opts) do
    content =
      case Keyword.get(opts, :rewrite_cwd) do
        cwd when is_binary(cwd) ->
          metadata = data || %{}
          Jason.encode!(Map.put(metadata, "cwd", cwd), pretty: true)

        _ ->
          raw
      end

    write_file_no_overwrite(target_meta_path, content, :before_meta_publish)
  end

  defp write_file_no_overwrite(target_path, content, before_publish_event) do
    with :ok <- ensure_absent(target_path),
         {:ok, temp_path} <- unused_temp_path(target_path) do
      case File.write(temp_path, content) do
        :ok ->
          publish_temp_file(temp_path, target_path, before_publish_event)

        {:error, _reason} = error ->
          rm_optional(temp_path)
          error
      end
    end
  end

  defp publish_temp_file(temp_path, target_path, before_publish_event) do
    with :ok <-
           run_operation_hook(before_publish_event, %{
             source: temp_path,
             target: target_path
           }) do
      case File.ln(temp_path, target_path) do
        :ok ->
          rm_optional(temp_path)
          :ok

        {:error, :eexist} ->
          rm_optional(temp_path)
          {:error, :already_exists}

        {:error, reason} ->
          rm_optional(temp_path)
          {:error, reason}
      end
    else
      {:error, _reason} = error ->
        rm_optional(temp_path)
        error
    end
  end

  defp unused_temp_path(target_path, attempts \\ 8)

  defp unused_temp_path(_target_path, 0), do: {:error, :eexist}

  defp unused_temp_path(target_path, attempts) do
    temp_path = temp_path(target_path)

    case ensure_absent(temp_path) do
      :ok -> {:ok, temp_path}
      {:error, :already_exists} -> unused_temp_path(target_path, attempts - 1)
      {:error, _reason} = error -> error
    end
  end

  defp temp_path(target_path) do
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    Path.join(
      Path.dirname(target_path),
      ".#{Path.basename(target_path)}.#{suffix}.tmp"
    )
  end

  defp run_operation_hook(event, paths) do
    case Process.get({__MODULE__, :operation_hook}) do
      hook when is_function(hook, 2) -> hook.(event, paths)
      _other -> :ok
    end
  end
end
