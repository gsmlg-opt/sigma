defmodule Sigma.Coding.Utils.PathUtils do
  @moduledoc """
  Utilities for path resolution and safety checks.
  """

  @doc """
  Resolves a path relative to the given cwd and ensures it's within the cwd.

  ## Parameters
  - `path`: The path to resolve.
  - `cwd`: The current working directory.
  - `opts`: Optional safety exceptions.

  ## Returns
  - `{:ok, resolved_path}`: The path is within the cwd, or matches an explicit exception.
  - `{:error, reason}`: The path is outside the cwd or invalid.
  """
  def safe_resolve(path, cwd, opts \\ []) do
    expanded_cwd = Path.expand(cwd)
    resolved_path = Path.expand(path, expanded_cwd)

    # Resolve symlinks on both sides so a symlink within cwd cannot escape to outside.
    with {:ok, real_cwd} <- resolve_real_path(expanded_cwd),
         {:ok, real_path} <- resolve_real_path(resolved_path) do
      if within_cwd?(real_path, real_cwd) or
           allowed_external_path?(resolved_path, real_path, opts) do
        {:ok, real_path}
      else
        {:error,
         "Access denied: Path '#{path}' is outside of the current working directory '#{cwd}'."}
      end
    else
      {:error, :symlink_loop} ->
        {:error, "Access denied: Path '#{path}' contains a symlink loop."}
    end
  end

  @doc "Returns the symlink-resolved resource key used by access checks and scheduling."
  def canonical_resource_key(path, cwd, opts \\ []) do
    with {:ok, resolved_path} <- safe_resolve(path, cwd, opts),
         {:ok, real_path} <- resolve_real_path(resolved_path) do
      {:ok, Path.expand(real_path)}
    end
  end

  @doc """
  Returns `path` relative to `cwd`, accounting for symlink resolutions in either path.
  """
  def relative_to(path, cwd) do
    expanded_cwd = Path.expand(cwd)

    case resolve_real_path(expanded_cwd) do
      {:ok, real_cwd} ->
        case Path.relative_to(path, real_cwd) do
          ^path -> Path.relative_to(path, expanded_cwd)
          rel -> rel
        end

      _ ->
        Path.relative_to(path, expanded_cwd)
    end
  end

  @symlink_depth_limit 40

  defp resolve_real_path(path, depth \\ 0)

  defp resolve_real_path(_path, depth) when depth >= @symlink_depth_limit do
    {:error, :symlink_loop}
  end

  defp resolve_real_path(path, depth) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce_while({:ok, ""}, fn segment, {:ok, resolved} ->
      candidate = if resolved == "", do: segment, else: Path.join(resolved, segment)

      case File.read_link(candidate) do
        {:ok, target} ->
          target =
            if Path.type(target) == :absolute,
              do: target,
              else: Path.expand(target, Path.dirname(candidate))

          case resolve_real_path(target, depth + 1) do
            {:ok, real_target} -> {:cont, {:ok, real_target}}
            {:error, _reason} = error -> {:halt, error}
          end

        {:error, _reason} ->
          {:cont, {:ok, candidate}}
      end
    end)
  end

  defp within_cwd?(path, cwd) do
    cwd_prefix = if String.ends_with?(cwd, "/"), do: cwd, else: cwd <> "/"
    path == cwd or String.starts_with?(path, cwd_prefix)
  end

  defp allowed_external_path?(path, real_path, opts) do
    Keyword.get(opts, :allow_skill_files?, false) and
      Path.basename(path) == "SKILL.md" and
      Path.basename(real_path) == "SKILL.md" and
      File.regular?(real_path)
  end
end
