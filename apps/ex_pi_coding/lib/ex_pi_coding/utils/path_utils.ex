defmodule PiCoding.Utils.PathUtils do
  @moduledoc """
  Utilities for path resolution and safety checks.
  """

  @doc """
  Resolves a path relative to the given cwd and ensures it's within the cwd.

  ## Parameters
  - `path`: The path to resolve.
  - `cwd`: The current working directory.

  ## Returns
  - `{:ok, resolved_path}`: The path is within the cwd.
  - `{:error, reason}`: The path is outside the cwd or invalid.
  """
  def safe_resolve(path, cwd) do
    expanded_cwd = Path.expand(cwd)
    resolved_path = Path.expand(path, expanded_cwd)

    # Resolve symlinks on both sides so a symlink within cwd cannot escape to outside.
    with {:ok, real_cwd} <- resolve_real_path(expanded_cwd),
         {:ok, real_path} <- resolve_real_path(resolved_path) do
      if within_cwd?(real_path, real_cwd) do
        {:ok, resolved_path}
      else
        {:error,
         "Access denied: Path '#{path}' is outside of the current working directory '#{cwd}'."}
      end
    else
      {:error, :symlink_loop} ->
        {:error, "Access denied: Path '#{path}' contains a symlink loop."}
    end
  end

  @symlink_depth_limit 40

  defp resolve_real_path(path, depth \\ 0)

  defp resolve_real_path(_path, depth) when depth >= @symlink_depth_limit do
    {:error, :symlink_loop}
  end

  defp resolve_real_path(path, depth) do
    case File.read_link(path) do
      {:ok, target} ->
        target =
          if Path.type(target) == :absolute,
            do: target,
            else: Path.expand(target, Path.dirname(path))

        resolve_real_path(target, depth + 1)

      {:error, :enoent} ->
        parent = Path.dirname(path)

        if parent == path do
          {:ok, path}
        else
          case resolve_real_path(parent, depth + 1) do
            {:ok, real_parent} -> {:ok, Path.join(real_parent, Path.basename(path))}
            error -> error
          end
        end

      {:error, _} ->
        # Not a symlink — path is its own real location.
        {:ok, path}
    end
  end

  defp within_cwd?(path, cwd) do
    cwd_prefix = if String.ends_with?(cwd, "/"), do: cwd, else: cwd <> "/"
    path == cwd or String.starts_with?(path, cwd_prefix)
  end
end
