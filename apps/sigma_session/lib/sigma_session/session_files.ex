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

  defp safe_path(sessions_dir, id, suffix) do
    if valid_session_id?(id) do
      {:ok, Path.join(sessions_dir, id <> suffix)}
    else
      {:error, :invalid_session_id}
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
        rollback_jsonl_move(new_jsonl_path, old_jsonl_path)
        error
    end
  end

  defp rollback_jsonl_move(new_jsonl_path, old_jsonl_path) do
    with {:ok, _new_stat} <- File.lstat(new_jsonl_path),
         {:error, :enoent} <- File.lstat(old_jsonl_path) do
      move_file_no_overwrite(new_jsonl_path, old_jsonl_path)
    end

    :ok
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
    case JsonlFile.read(source_jsonl_path) do
      {:ok, entries} ->
        Enum.find_value(entries, fn
          %{"type" => "session", "cwd" => cwd} when is_binary(cwd) -> cwd
          _entry -> nil
        end)

      _ ->
        nil
    end
  end

  defp write_fork_metadata_or_cleanup(metadata, target_meta_path, target_jsonl_path, opts) do
    case write_fork_metadata(metadata, target_meta_path, opts) do
      :ok ->
        :ok

      {:error, _reason} = error ->
        rm_optional(target_jsonl_path)
        error
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
