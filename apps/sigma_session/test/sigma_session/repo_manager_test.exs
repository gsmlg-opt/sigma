defmodule Sigma.Session.RepoManagerTest do
  use ExUnit.Case, async: false

  alias Sigma.Session.RepoManager

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:sigma_session, :agent_dir)
    agent_dir = Path.join(tmp_dir, "agent")
    Application.put_env(:sigma_session, :agent_dir, agent_dir)

    on_exit(fn ->
      if previous do
        Application.put_env(:sigma_session, :agent_dir, previous)
      else
        Application.delete_env(:sigma_session, :agent_dir)
      end
    end)

    :ok
  end

  @tag :tmp_dir
  test "add_repo defaults disabled_skills to an empty list", %{tmp_dir: tmp_dir} do
    workdir = Path.join(tmp_dir, "repo-a")
    File.mkdir_p!(workdir)

    {:ok, entry} = RepoManager.add_repo(workdir)
    assert entry["disabled_skills"] == []
    assert RepoManager.disabled_skills(workdir) == []
  end

  @tag :tmp_dir
  test "set_disabled_skills persists deduplicated sorted names", %{tmp_dir: tmp_dir} do
    workdir = Path.join(tmp_dir, "repo-b")
    File.mkdir_p!(workdir)
    RepoManager.add_repo(workdir)

    RepoManager.set_disabled_skills(workdir, ["zeta", "alpha", "zeta", "  alpha  ", ""])

    assert RepoManager.disabled_skills(workdir) == ["alpha", "zeta"]

    # Rename/move carries the disabled list because update_repo merges fields.
    new_path = Path.join(tmp_dir, "repo-b-moved")
    RepoManager.update_repo(workdir, %{"path" => new_path})

    assert RepoManager.disabled_skills(new_path) == ["alpha", "zeta"]
    assert RepoManager.disabled_skills(workdir) == []
  end

  @tag :tmp_dir
  test "disabled_skills returns [] for unknown repos and rejects non-list values", %{
    tmp_dir: tmp_dir
  } do
    assert RepoManager.disabled_skills(Path.join(tmp_dir, "missing")) == []

    workdir = Path.join(tmp_dir, "repo-c")
    File.mkdir_p!(workdir)
    RepoManager.add_repo(workdir)
    {:ok, _} = RepoManager.update_repo(workdir, %{"disabled_skills" => "not-a-list"})
    assert RepoManager.disabled_skills(workdir) == []

    assert RepoManager.set_disabled_skills(workdir, :not_a_list) == {:error, :invalid_names}
    assert RepoManager.disabled_skills(workdir) == []
  end
end
