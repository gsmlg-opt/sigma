defmodule Sigma.Web.SamgitaHost.ThreadIdTest do
  use ExUnit.Case, async: false

  alias Sigma.Session.RepoManager
  alias Sigma.Web.SamgitaHost.ThreadId

  setup context do
    root =
      Path.join(
        System.tmp_dir!(),
        "sigma-thread-id-#{context.test}-#{System.unique_integer([:positive])}"
      )

    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)
    previous_agent_dir = Application.get_env(:sigma_session, :agent_dir)
    Application.put_env(:sigma_session, :agent_dir, Path.join(root, "agent"))
    {:ok, _} = RepoManager.add_repo(repo, name: "Thread Repo")

    on_exit(fn ->
      if previous_agent_dir do
        Application.put_env(:sigma_session, :agent_dir, previous_agent_dir)
      else
        Application.delete_env(:sigma_session, :agent_dir)
      end

      File.rm_rf!(root)
    end)

    {:ok, repo: repo, root: root}
  end

  test "encode/decode round-trips a registered repository", %{repo: repo} do
    assert {:ok, decoded} = repo |> ThreadId.encode("s1") |> ThreadId.decode()
    assert decoded.repo_path == repo
    assert decoded.session_id == "s1"
    assert decoded.sessions_dir == Sigma.Session.ConfigManager.ensure_sessions_dir(repo)
  end

  test "session ids containing dots survive decode", %{repo: repo} do
    assert {:ok, %{session_id: "a.b"}} = repo |> ThreadId.encode("a.b") |> ThreadId.decode()
  end

  test "decode rejects malformed ids" do
    for bad <- ["nodot", "!!!.x", ".x", "abc.", 123] do
      assert ThreadId.decode(bad) == {:error, :not_found}
    end
  end

  test "decode rejects unregistered repositories", %{root: root} do
    other = Path.join(root, "other")
    assert ThreadId.decode(ThreadId.encode(other, "s1")) == {:error, :not_found}
  end

  test "repository/1 accepts only registered absolute paths", %{repo: repo, root: root} do
    assert ThreadId.repository(repo) == {:ok, repo}
    assert ThreadId.repository(Path.join(root, "other")) == {:error, :invalid_params}
    assert ThreadId.repository("relative/path") == {:error, :invalid_params}
    assert ThreadId.repository(nil) == {:error, :invalid_params}
  end
end
