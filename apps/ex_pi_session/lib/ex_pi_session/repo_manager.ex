defmodule ExPiSession.RepoManager do
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

  def add_repo(path) do
    path = Path.expand(path)
    root = get_repos_root()
    File.mkdir_p!(root)
    repo_path = Path.join(root, @repo_file)

    entry = %{
      "path" => path,
      "added_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "name" => Path.basename(path)
    }

    # Append if not already present
    existing = list_repos()
    if !Enum.any?(existing, fn r -> r["path"] == path end) do
      File.write!(repo_path, Jason.encode!(entry) <> "\n", [:append])
    end

    {:ok, entry}
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

  defp get_repos_root do
    case :code.priv_dir(:ex_pi_session) do
      {:error, :bad_name} -> Path.expand("priv", File.cwd!())
      path -> List.to_string(path)
    end
  end
end
