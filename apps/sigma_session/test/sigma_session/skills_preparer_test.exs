defmodule Sigma.Session.SkillsPreparerTest do
  use ExUnit.Case, async: true

  alias Sigma.Session.Skills.Skill
  alias Sigma.Session.Skills.Snapshot

  @tag :tmp_dir
  test "prepares immutable instructions and resources with a package digest", %{tmp_dir: tmp_dir} do
    {skill, source_root} = skill_fixture(tmp_dir, "immutable")
    File.mkdir_p!(Path.join(source_root, "references"))
    File.write!(Path.join(source_root, "references/guide.md"), "original guide")
    storage_root = Path.join(tmp_dir, "storage")

    assert {:ok, snapshot} = Snapshot.prepare(skill, storage_root: storage_root)
    assert snapshot.entry_body == "Original body"
    assert snapshot.digest =~ ~r/^sha256:[0-9a-f]{64}$/
    digest = snapshot.digest

    assert %{source_id: "repository", skill_id: "immutable", artifact_digest: ^digest} =
             snapshot.ref

    assert %{files: files, artifact_digest: ^digest} = snapshot.manifest
    assert Enum.map(files, & &1.path) == ["SKILL.md", "references/guide.md"]
    refute package_struct?(snapshot)

    File.write!(skill.path, "---\nname: immutable\ndescription: Changed\n---\nChanged body")
    File.write!(Path.join(source_root, "references/guide.md"), "changed guide")

    assert snapshot.entry_body == "Original body"
    assert File.read!(Path.join(snapshot.root, "references/guide.md")) == "original guide"
    refute File.exists?(Path.join(snapshot.ownership.operation_root, "bundle-1.tar.gz"))

    assert :ok = Snapshot.release(snapshot)
    refute File.exists?(snapshot.root)
    assert :ok = Snapshot.release(snapshot)
  end

  @tag :tmp_dir
  test "same content produces the same exact package digest and manifest", %{tmp_dir: tmp_dir} do
    {skill, _source_root} = skill_fixture(tmp_dir, "deterministic")
    storage_root = Path.join(tmp_dir, "storage")

    assert {:ok, first} = Snapshot.prepare(skill, storage_root: storage_root)
    assert {:ok, second} = Snapshot.prepare(skill, storage_root: storage_root)
    assert first.digest == second.digest
    assert first.manifest == second.manifest
    assert :ok = Snapshot.release(first)
    assert :ok = Snapshot.release(second)
  end

  @tag :tmp_dir
  test "rejects a directory and document name mismatch", %{tmp_dir: tmp_dir} do
    {skill, _source_root} = skill_fixture(tmp_dir, "directory-name", document_name: "other-name")
    storage_root = Path.join(tmp_dir, "storage")

    assert {:error, :unsafe_archive} = Snapshot.prepare(skill, storage_root: storage_root)
    assert File.ls!(storage_root) == []
  end

  @tag :tmp_dir
  test "rejects symlinks and special entries without publishing a destination", %{
    tmp_dir: tmp_dir
  } do
    storage_root = Path.join(tmp_dir, "storage")
    {symlink_skill, symlink_root} = skill_fixture(tmp_dir, "linked")
    outside = Path.join(tmp_dir, "outside.txt")
    File.write!(outside, "outside")
    File.ln_s!(outside, Path.join(symlink_root, "linked.txt"))

    assert {:error, :unsafe_archive} =
             Snapshot.prepare(symlink_skill, storage_root: storage_root)

    assert File.ls!(storage_root) == []

    {special_skill, special_root} = skill_fixture(tmp_dir, "special")
    {_output, 0} = System.cmd("mkfifo", [Path.join(special_root, "pipe")])

    assert {:error, :unsafe_archive} =
             Snapshot.prepare(special_skill, storage_root: storage_root)

    assert File.ls!(storage_root) == []
  end

  @tag :tmp_dir
  test "retries source changes once and removes the owned operation", %{tmp_dir: tmp_dir} do
    {skill, _source_root} = skill_fixture(tmp_dir, "changing")
    storage_root = Path.join(tmp_dir, "storage")
    calls = :atomics.new(1, [])
    {:ok, attempts} = Agent.start_link(fn -> MapSet.new() end)

    cancelled? = fn ->
      call = :atomics.add_get(calls, 1, 1)
      Agent.update(attempts, &MapSet.union(&1, active_pack_attempts(storage_root)))
      suffix = if rem(call, 2) == 0, do: "short", else: "a longer body"
      File.write!(skill.path, "---\nname: changing\ndescription: Changing\n---\n#{suffix}")
      false
    end

    assert {:error, :source_changed} =
             Snapshot.prepare(skill, storage_root: storage_root, cancelled?: cancelled?)

    assert Agent.get(attempts, & &1) == MapSet.new([1, 2])
    assert File.ls!(storage_root) == []
  end

  @tag :tmp_dir
  test "cleans owned storage after cancellation and limit failures", %{tmp_dir: tmp_dir} do
    storage_root = Path.join(tmp_dir, "storage")
    {cancelled_skill, _source_root} = skill_fixture(tmp_dir, "cancelled")

    assert {:error, :artifact_unavailable} =
             Snapshot.prepare(cancelled_skill,
               storage_root: storage_root,
               cancelled?: fn -> true end
             )

    assert File.ls!(storage_root) == []

    {oversize_skill, oversize_root} = skill_fixture(tmp_dir, "oversize")
    File.write!(Path.join(oversize_root, "large.bin"), :binary.copy("x", 5 * 1024 * 1024 + 1))

    assert {:error, :unsafe_archive} =
             Snapshot.prepare(oversize_skill, storage_root: storage_root)

    assert File.ls!(storage_root) == []
  end

  @tag :tmp_dir
  test "release refuses malformed and unowned directories", %{tmp_dir: tmp_dir} do
    assert {:error, :invalid_snapshot} = Snapshot.release(%{})

    operation_root = Path.join(tmp_dir, "sigma-skill-preparation.foreign")
    prepared_root = Path.join(operation_root, "prepared")
    File.mkdir_p!(prepared_root)

    snapshot = %{
      root: prepared_root,
      ownership: %{operation_root: operation_root, token: Base.encode64("foreign-token")}
    }

    assert {:error, :unowned_snapshot} = Snapshot.release(snapshot)
    assert File.dir?(operation_root)
  end

  defp skill_fixture(tmp_dir, directory, opts \\ []) do
    name = Keyword.get(opts, :document_name, directory)
    source_root = Path.join([tmp_dir, "sources", directory])
    entry_path = Path.join(source_root, "SKILL.md")
    File.mkdir_p!(source_root)
    File.write!(entry_path, "---\nname: #{name}\ndescription: #{name}\n---\nOriginal body")

    skill = %Skill{
      name: name,
      description: name,
      path: entry_path,
      source: :repository,
      skill_id: "repository:#{directory}",
      source_id: "repository",
      source_key: directory
    }

    {skill, source_root}
  end

  defp active_pack_attempts(storage_root) do
    storage_root
    |> Path.join("sigma-skill-preparation.*")
    |> Path.wildcard()
    |> Enum.flat_map(&File.ls!/1)
    |> Enum.flat_map(fn entry ->
      cond do
        String.starts_with?(entry, ".bundle-1.tar.gz.stage.") -> [1]
        String.starts_with?(entry, ".bundle-2.tar.gz.stage.") -> [2]
        true -> []
      end
    end)
    |> MapSet.new()
  end

  defp package_struct?(%module{}) when is_atom(module) do
    module |> Atom.to_string() |> String.starts_with?("Elixir.Backplane.SkillProtocol.")
  end

  defp package_struct?(map) when is_map(map),
    do: Enum.any?(map, fn {key, value} -> package_struct?(key) or package_struct?(value) end)

  defp package_struct?(list) when is_list(list), do: Enum.any?(list, &package_struct?/1)
  defp package_struct?(_value), do: false
end
