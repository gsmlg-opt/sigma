defmodule PiSession.RepoManager do
  @moduledoc """
  Manages the list of known repositories (working directories).
  """

  @repo_file "repos.jsonl"

  def list_repos do
    root = get_repos_root()
    File.mkdir_p!(root)
    path = Path.join(root, @repo_file)

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)
      |> Enum.sort_by(fn r -> r["path"] end)
      |> Enum.uniq_by(fn r -> r["path"] end)
    else
      []
    end
  end

  def get_repo(path) do
    path = Path.expand(path)
    Enum.find(list_repos(), fn repo -> repo["path"] == path end)
  end

  def add_repo(path, opts \\ []) do
    path = Path.expand(path)
    name = Keyword.get(opts, :name) |> normalize_name(path)

    root = get_repos_root()
    File.mkdir_p!(root)
    repo_path = Path.join(root, @repo_file)

    entry = %{
      "path" => path,
      "added_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "name" => name,
      "mcp_server_ids" => []
    }

    # Append if not already present
    existing = list_repos()

    if !Enum.any?(existing, fn r -> r["path"] == path end) do
      File.write!(repo_path, Jason.encode!(entry) <> "\n", [:append])
    end

    {:ok, entry}
  end

  defp normalize_name(nil, path), do: Path.basename(path)

  defp normalize_name(name, path) do
    case String.trim(name) do
      "" -> Path.basename(path)
      trimmed -> trimmed
    end
  end

  @doc """
  Updates the repo entry matching `old_path` by merging `updates` over its
  current fields (typically `"name"` and/or `"path"`). Returns
  `{:ok, new_entry}` on success.

  Errors:
    * `:not_found` — no repo with `old_path`
    * `:path_conflict` — a different repo already uses the new path
  """
  def update_repo(old_path, updates) do
    old_path = Path.expand(old_path)
    new_path = updates |> Map.get("path", old_path) |> Path.expand()

    repos = list_repos()

    cond do
      !Enum.any?(repos, &(&1["path"] == old_path)) ->
        {:error, :not_found}

      new_path != old_path and Enum.any?(repos, &(&1["path"] == new_path)) ->
        {:error, :path_conflict}

      true ->
        updated_repos =
          Enum.map(repos, fn r ->
            if r["path"] == old_path do
              r |> Map.merge(updates) |> Map.put("path", new_path)
            else
              r
            end
          end)

        write_repos(updated_repos)
        {:ok, Enum.find(updated_repos, &(&1["path"] == new_path))}
    end
  end

  def remove_repo(path) do
    path = Path.expand(path)
    root = get_repos_root()
    repo_path = Path.join(root, @repo_file)

    if File.exists?(repo_path) do
      new_contents =
        repo_path
        |> File.stream!()
        |> Enum.reject(fn line ->
          r = Jason.decode!(line)
          r["path"] == path
        end)
        |> Enum.join("")

      File.write!(repo_path, new_contents)
    end

    :ok
  end

  def mcp_server_ids(path) do
    path
    |> get_repo()
    |> case do
      %{"mcp_server_ids" => ids} when is_list(ids) -> ids
      _ -> []
    end
  end

  def set_mcp_server_ids(path, ids) when is_list(ids) do
    update_repo(path, %{"mcp_server_ids" => Enum.uniq(ids)})
  end

  defp write_repos(repos) do
    root = get_repos_root()
    File.mkdir_p!(root)
    repo_path = Path.join(root, @repo_file)
    contents = repos |> Enum.map(&(Jason.encode!(&1) <> "\n")) |> IO.iodata_to_binary()
    File.write!(repo_path, contents)
  end

  defp get_repos_root do
    PiSession.ConfigManager.agent_dir()
  end
end
