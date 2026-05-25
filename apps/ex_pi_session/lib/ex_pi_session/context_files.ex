defmodule PiSession.ContextFiles do
  @moduledoc """
  Assembles project context from repo-local instruction files.

  Walks from filesystem root down to `cwd`. In each directory, prefers
  `AGENTS.md`; falls back to `CLAUDE.md` only when `AGENTS.md` is absent.
  Files are concatenated after the global prompt, with `/`-rooted entries
  appearing first and `cwd` entries last — so deeper directories have
  higher attention precedence (matches upstream pi).

  Files are NOT re-read between calls; this is invoked once per session at
  mount, so no caching layer is needed.
  """

  @candidates ["AGENTS.md", "CLAUDE.md"]

  @doc """
  Returns assembled context: `global_prompt` followed by each
  discovered context file (tagged with its absolute path so the LLM can
  distinguish global rules from project rules).

  `global_prompt` may be `nil` or empty; either is treated as "no global
  section". `cwd` must be an absolute path.

  Options:
    * `:stop_at` — only include directories under this path during the
      walk (defaults to `nil`, meaning walk all the way to `/`).
  """
  @spec assemble(String.t() | nil, Path.t(), keyword()) :: String.t()
  def assemble(global_prompt, cwd, opts \\ []) do
    sections =
      [global_section(global_prompt) | Enum.map(walk_files(cwd, opts), &file_section/1)]
      |> Enum.reject(&(&1 == nil or &1 == ""))

    Enum.join(sections, "\n\n")
  end

  @doc """
  Returns the list of context file paths the walk would include, in
  global-to-deepest order. Useful for tests and Settings previews.

  Options:
    * `:stop_at` — only include directories under this path during the
      walk (defaults to `nil`).
  """
  @spec walk_files(Path.t(), keyword()) :: [Path.t()]
  def walk_files(cwd, opts \\ []) do
    stop_at = opts |> Keyword.get(:stop_at) |> maybe_expand()

    cwd
    |> Path.expand()
    |> ancestors_oldest_first()
    |> Enum.filter(&below_or_equal?(&1, stop_at))
    |> Enum.map(&pick_file/1)
    |> Enum.reject(&is_nil/1)
  end

  defp maybe_expand(nil), do: nil
  defp maybe_expand(path), do: Path.expand(path)

  defp below_or_equal?(_dir, nil), do: true

  defp below_or_equal?(dir, root) do
    dir == root or String.starts_with?(dir, root <> "/")
  end

  defp ancestors_oldest_first(absolute_path) do
    absolute_path
    |> Path.split()
    |> Enum.scan("", fn segment, acc ->
      if acc == "", do: segment, else: Path.join(acc, segment)
    end)
  end

  defp pick_file(dir) do
    Enum.find_value(@candidates, fn name ->
      path = Path.join(dir, name)
      if File.regular?(path), do: path
    end)
  end

  defp global_section(nil), do: nil
  defp global_section(""), do: nil
  defp global_section(text), do: text

  defp file_section(path) do
    case File.read(path) do
      {:ok, content} -> "# Context: #{path}\n\n#{content}"
      {:error, _} -> nil
    end
  end
end
