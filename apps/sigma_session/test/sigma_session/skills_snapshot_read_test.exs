defmodule Sigma.Session.SkillsSnapshotReadTest do
  use ExUnit.Case, async: true

  alias Backplane.SkillProtocol.Error
  alias Sigma.Session.Skills.{Skill, Snapshot}

  @moduletag :tmp_dir

  test "readonly snapshot resources preserve verified inventory, containment and byte limits", %{
    tmp_dir: dir
  } do
    source = Path.join(dir, "safe")
    File.mkdir_p!(source)
    entry = Path.join(source, "SKILL.md")
    File.write!(entry, "---\nname: safe\ndescription: Safe\n---\nOriginal body")
    File.write!(Path.join(source, "guide.md"), "Original guide")

    skill = %Skill{
      name: "safe",
      description: "Safe",
      path: entry,
      source: :repository,
      skill_id: "repository:safe",
      source_id: "repository",
      source_key: "safe"
    }

    assert {:ok, snapshot} = Snapshot.prepare(skill, storage_root: Path.join(dir, "storage"))
    on_exit(fn -> Snapshot.release(snapshot) end)

    File.write!(Path.join(source, "guide.md"), "Changed source")
    assert {:ok, "Original guide"} = Snapshot.read(snapshot, "guide.md")
    assert {:ok, document} = Snapshot.read(snapshot, "SKILL.md")
    assert document =~ "Original body"

    assert {:error, %Error{code: :limit_exceeded}} =
             Snapshot.read(snapshot, "guide.md", max_bytes: 3)

    for path <- ["../safe/guide.md", Path.join(source, "guide.md"), "..\\guide.md"] do
      assert {:error, %Error{code: :invalid_request}} = Snapshot.read(snapshot, path)
    end

    File.write!(Path.join(snapshot.root, "unlisted.md"), "Unverified")
    assert {:error, %Error{code: :not_found}} = Snapshot.read(snapshot, "unlisted.md")
    File.rm!(Path.join(snapshot.root, "guide.md"))
    File.ln_s!(entry, Path.join(snapshot.root, "guide.md"))
    assert {:error, %Error{code: :invalid_request}} = Snapshot.read(snapshot, "guide.md")
    assert :ok = Snapshot.release(snapshot)
    assert {:error, %Error{}} = Snapshot.read(snapshot, "SKILL.md")
  end
end
