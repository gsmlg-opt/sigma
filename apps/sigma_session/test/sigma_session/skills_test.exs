defmodule Sigma.Session.SkillsTest do
  use ExUnit.Case, async: false

  alias Sigma.Session.RepoManager
  alias Sigma.Session.Skills
  alias Sigma.Session.Skills.Catalog
  alias Sigma.Session.Skills.Snapshot

  @tag :tmp_dir
  test "discovers skill metadata from SKILL.md files", %{tmp_dir: tmp_dir} do
    skill_dir = Path.join([tmp_dir, ".agents", "skills", "repo-skill"])
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: repo-skill
      description: Helps with repository work
      disable-model-invocation: true
      ---
      Use this skill.
      """
    )

    assert %{skills: [skill], diagnostics: []} =
             Skills.list_dir(Path.join([tmp_dir, ".agents", "skills"]), :repository)

    assert skill.name == "repo-skill"
    assert skill.description == "Helps with repository work"
    assert skill.path == Path.join(skill_dir, "SKILL.md") |> Path.expand()
    assert skill.source == :repository
    assert skill.source_key == "repo-skill"
    assert skill.skill_id == skill.source_id <> ":repo-skill"
    assert skill.disable_model_invocation? == true
  end

  @tag :tmp_dir
  test "skips missing skill directories", %{tmp_dir: tmp_dir} do
    assert %{skills: [], diagnostics: []} =
             Skills.list_dir(Path.join([tmp_dir, ".agents", "skills"]), :repository)
  end

  @tag :tmp_dir
  test "reports invalid skill metadata", %{tmp_dir: tmp_dir} do
    skill_dir = Path.join([tmp_dir, ".agents", "skills", "broken-skill"])
    File.mkdir_p!(skill_dir)
    File.write!(Path.join(skill_dir, "SKILL.md"), "---\nname: broken-skill\n---\nBody")

    assert %{skills: [], diagnostics: [diagnostic]} =
             Skills.list_dir(Path.join([tmp_dir, ".agents", "skills"]), :repository)

    assert diagnostic.path == "broken-skill"
    assert diagnostic.message == "description is required"
  end

  @tag :tmp_dir
  test "applies standard name validation after package discovery", %{tmp_dir: tmp_dir} do
    skill_dir = Path.join([tmp_dir, ".agents", "skills", "legacy-name"])
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      "---\nname: Legacy_Name\ndescription: Legacy\n---\nBody"
    )

    assert %{skills: [], diagnostics: [%{path: "legacy-name", message: message}]} =
             Skills.list_dir(Path.dirname(skill_dir), :repository)

    assert message == "name must be lowercase kebab-case"
  end

  @tag :tmp_dir
  test "keeps valid siblings when a package-invalid candidate is diagnosed", %{tmp_dir: tmp_dir} do
    skills_root = Path.join([tmp_dir, ".agents", "skills"])

    for {directory, document} <- [
          {"valid", "---\nname: valid\ndescription: Valid\n---\nBody"},
          {"invalid", "---\ndescription: Missing name\n---\nBody"}
        ] do
      File.mkdir_p!(Path.join(skills_root, directory))
      File.write!(Path.join([skills_root, directory, "SKILL.md"]), document)
    end

    assert %{skills: [%{name: "valid"}], diagnostics: [%{message: "name is required"}]} =
             Skills.list_dir(skills_root, :repository)
  end

  @tag :tmp_dir
  test "does not fall back to the skill directory when name is missing", %{tmp_dir: tmp_dir} do
    skill_dir = Path.join([tmp_dir, ".agents", "skills", "directory-name"])
    File.mkdir_p!(skill_dir)
    File.write!(Path.join(skill_dir, "SKILL.md"), "---\ndescription: Missing name\n---\nBody")

    assert %{skills: [], diagnostics: [%{message: "name is required"}]} =
             Skills.list_dir(Path.dirname(skill_dir), :repository)
  end

  @tag :tmp_dir
  test "parses folded block scalars (> and >-) in skill description", %{tmp_dir: tmp_dir} do
    skills_root = Path.join([tmp_dir, ".agents", "skills"])
    agent_note_dir = Path.join(skills_root, "agent-note")
    caveman_dir = Path.join(skills_root, "caveman")
    File.mkdir_p!(agent_note_dir)
    File.mkdir_p!(caveman_dir)

    File.write!(
      Path.join(agent_note_dir, "SKILL.md"),
      """
      ---
      name: agent-note
      description: >-
        Configure Agent Note in a project's AGENTS.md when setup is requested, and recall
        or maintain project-scoped knowledge through Agent Note MCP.
      compatibility: Note workflows require Agent Note MCP.
      ---
      # Agent Note
      """
    )

    File.write!(
      Path.join(caveman_dir, "SKILL.md"),
      """
      ---
      name: caveman
      description: >
        Ultra-compressed communication mode. Cuts token usage ~75% by dropping
        filler, articles, and pleasantries while keeping full technical accuracy.
      ---
      # Caveman
      """
    )

    assert %{skills: skills, diagnostics: []} = Skills.list_dir(skills_root, :global)
    skills_by_name = Map.new(skills, &{&1.name, &1})

    assert skills_by_name["agent-note"].description ==
             "Configure Agent Note in a project's AGENTS.md when setup is requested, and recall or maintain project-scoped knowledge through Agent Note MCP."

    assert skills_by_name["caveman"].description ==
             "Ultra-compressed communication mode. Cuts token usage ~75% by dropping filler, articles, and pleasantries while keeping full technical accuracy."
  end

  @tag :tmp_dir
  test "parses YAML comments, nested metadata, and argument hints", %{tmp_dir: tmp_dir} do
    skill_dir = Path.join([tmp_dir, ".agents", "skills", "yaml-skill"])
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: yaml-skill # inline comment
      description: "Use YAML safely"
      argument-hint: "file path"
      metadata:
        owner: sigma
        tags: [safe, bounded]
      ---
      Body
      """
    )

    assert %{skills: [skill], diagnostics: []} =
             Skills.list_dir(Path.join([tmp_dir, ".agents", "skills"]), :repository)

    assert skill.argument_hint == "file path"
    assert skill.metadata["metadata"]["owner"] == "sigma"
    assert skill.metadata["metadata"]["tags"] == ["safe", "bounded"]
  end

  @tag :tmp_dir
  test "rejects invalid policy field types", %{tmp_dir: tmp_dir} do
    skill_dir = Path.join([tmp_dir, ".agents", "skills", "invalid-policy"])
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      "---\nname: invalid-policy\ndescription: Invalid\ndisable-model-invocation: \"true\"\n---\nBody"
    )

    assert %{skills: [], diagnostics: [%{message: "invocation flag is invalid"}]} =
             Skills.list_dir(Path.join([tmp_dir, ".agents", "skills"]), :repository)
  end

  @tag :tmp_dir
  test "rejects duplicate YAML keys", %{tmp_dir: tmp_dir} do
    skill_dir = Path.join([tmp_dir, ".agents", "skills", "duplicate-key"])
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      "---\nname: duplicate-key\ndescription: first\ndescription: second\n---\nBody"
    )

    assert %{skills: [], diagnostics: [%{message: "Skill metadata is invalid"}]} =
             Skills.list_dir(Path.join([tmp_dir, ".agents", "skills"]), :repository)
  end

  @tag :tmp_dir
  test "catalog resolves repository skills before global skills", %{tmp_dir: tmp_dir} do
    repository_root = Path.join([tmp_dir, ".agents", "skills", "shared"])
    global_root = Path.join([tmp_dir, "global", "shared"])
    File.mkdir_p!(repository_root)
    File.mkdir_p!(global_root)

    for path <- [Path.join(repository_root, "SKILL.md"), Path.join(global_root, "SKILL.md")] do
      File.write!(path, "---\nname: shared\ndescription: Shared skill\n---\nBody")
    end

    Application.put_env(:sigma_session, :global_skills_dir, Path.join(tmp_dir, "global"))

    on_exit(fn -> Application.delete_env(:sigma_session, :global_skills_dir) end)

    catalog = Catalog.build(tmp_dir)
    assert {:ok, skill} = Catalog.resolve(catalog, "shared")
    assert skill.source == :repository
    assert {:ok, global_skill} = Catalog.resolve(catalog, "global:shared")
    assert global_skill.source == :global
    assert catalog.revision != ""
  end

  @tag :tmp_dir
  test "catalog preserves package ambiguity within the winning source", %{tmp_dir: tmp_dir} do
    for directory <- ["one", "two"] do
      path = Path.join([tmp_dir, ".agents", "skills", directory, "SKILL.md"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "---\nname: shared\ndescription: Shared\n---\nBody")
    end

    assert {:error, :ambiguous_skill} = Catalog.resolve(Catalog.build(tmp_dir), "shared")
  end

  @tag :tmp_dir
  test "disabled repository winner does not fall through to the global skill", %{
    tmp_dir: tmp_dir
  } do
    with_agent_dir(tmp_dir, fn ->
      for path <- [
            Path.join([tmp_dir, ".agents", "skills", "shared", "SKILL.md"]),
            Path.join([tmp_dir, "global", "shared", "SKILL.md"])
          ] do
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, "---\nname: shared\ndescription: Shared\n---\nBody")
      end

      Application.put_env(:sigma_session, :global_skills_dir, Path.join(tmp_dir, "global"))
      on_exit(fn -> Application.delete_env(:sigma_session, :global_skills_dir) end)
      RepoManager.add_repo(tmp_dir)
      RepoManager.set_disabled_skills(tmp_dir, ["shared"])

      assert {:error, :skill_disabled} = Catalog.resolve(Catalog.build(tmp_dir), "shared")
      assert {:error, :skill_disabled} = Catalog.resolve(Catalog.build(tmp_dir), "global:shared")
    end)
  end

  @tag :tmp_dir
  test "manual-only skills are excluded from automatic selection but allow explicit selection", %{
    tmp_dir: tmp_dir
  } do
    Application.put_env(:sigma_session, :global_skills_dir, Path.join(tmp_dir, "global"))
    on_exit(fn -> Application.delete_env(:sigma_session, :global_skills_dir) end)

    path = Path.join([tmp_dir, ".agents", "skills", "manual", "SKILL.md"])
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      "---\nname: manual\ndescription: Manual\ndisable-model-invocation: true\n---\nBody"
    )

    catalog = Catalog.build(tmp_dir)
    assert [] = Catalog.automatic(catalog)
    assert {:ok, %{name: "manual"}} = Catalog.resolve(catalog, "repo:manual")
  end

  @tag :tmp_dir
  test "user-invocable false allows automatic resolution but denies explicit resolution", %{
    tmp_dir: tmp_dir
  } do
    Application.put_env(:sigma_session, :global_skills_dir, Path.join(tmp_dir, "global"))
    on_exit(fn -> Application.delete_env(:sigma_session, :global_skills_dir) end)

    path = Path.join([tmp_dir, ".agents", "skills", "model-only", "SKILL.md"])
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      "---\nname: model-only\ndescription: Model only\nuser-invocable: false\n---\nBody"
    )

    catalog = Catalog.build(tmp_dir)

    assert [%{name: "model-only"}] = Catalog.automatic(catalog)
    assert {:ok, %{name: "model-only"}} = Catalog.resolve(catalog, "repo:model-only", :automatic)
    assert {:error, :unsupported_skill_kind} = Catalog.resolve(catalog, "repo:model-only")
    assert [] = Catalog.explicit(catalog)
  end

  @tag :tmp_dir
  test "prepares a package-backed snapshot through the compatibility facade", %{tmp_dir: tmp_dir} do
    skill_dir = Path.join([tmp_dir, ".agents", "skills", "snapshot-skill"])
    File.mkdir_p!(Path.join(skill_dir, "references"))
    entry_path = Path.join(skill_dir, "SKILL.md")

    File.write!(
      entry_path,
      "---\nname: snapshot-skill\ndescription: Snapshot\n---\nBody"
    )

    File.write!(Path.join([skill_dir, "references", "guide.md"]), "Guide")

    assert %{skills: [skill]} =
             Skills.list_dir(Path.join([tmp_dir, ".agents", "skills"]), :repository)

    assert {:ok, snapshot} = Snapshot.prepare(skill)
    assert snapshot.digest =~ ~r/^sha256:[0-9a-f]{64}$/
    assert Enum.map(snapshot.manifest.files, & &1.path) == ["SKILL.md", "references/guide.md"]
    assert snapshot.entry_body == "Body"

    assert {:ok, same_snapshot} = Snapshot.prepare(skill)
    assert same_snapshot.digest == snapshot.digest
    assert :ok = Snapshot.release(snapshot)
    assert :ok = Snapshot.release(same_snapshot)
  end

  @tag :tmp_dir
  test "rejects symlinked snapshot resources", %{tmp_dir: tmp_dir} do
    skill_dir = Path.join([tmp_dir, ".agents", "skills", "unsafe"])
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      "---\nname: unsafe\ndescription: Unsafe\n---\nBody"
    )

    outside = Path.join(tmp_dir, "outside.txt")
    File.write!(outside, "secret")
    File.ln_s!(outside, Path.join(skill_dir, "secret.txt"))

    assert %{skills: [skill]} =
             Skills.list_dir(Path.join([tmp_dir, ".agents", "skills"]), :repository)

    assert {:error, :unsafe_archive} = Snapshot.prepare(skill)
  end

  @tag :tmp_dir
  test "fails a root closed when a linked path escapes it", %{tmp_dir: tmp_dir} do
    skills_root = Path.join([tmp_dir, ".agents", "skills"])
    valid_dir = Path.join(skills_root, "valid")
    outside_dir = Path.join(tmp_dir, "outside")
    File.mkdir_p!(valid_dir)
    File.mkdir_p!(outside_dir)

    File.write!(
      Path.join(valid_dir, "SKILL.md"),
      "---\nname: valid\ndescription: Valid\n---\nBody"
    )

    File.ln_s!(outside_dir, Path.join(skills_root, "escaping"))

    assert %{skills: [], diagnostics: [diagnostic]} =
             Skills.list_dir(skills_root, :repository)

    assert diagnostic.path == "."
    assert diagnostic.message == "local skill root is invalid"
  end

  @tag :tmp_dir
  test "fails a root closed when the package scan budget is exceeded", %{tmp_dir: tmp_dir} do
    skills_root = Path.join([tmp_dir, ".agents", "skills"])
    valid_dir = Path.join(skills_root, "000-valid")
    File.mkdir_p!(valid_dir)

    File.write!(
      Path.join(valid_dir, "SKILL.md"),
      "---\nname: valid\ndescription: Valid\n---\nBody"
    )

    for index <- 0..2_000 do
      File.write!(Path.join(skills_root, "filler-#{index}"), "")
    end

    assert %{skills: [], diagnostics: [%{path: ".", message: "local skill scan limit exceeded"}]} =
             Skills.list_dir(skills_root, :repository)
  end

  # --- project-level disabled skills ---

  @tag :tmp_dir
  test "list_repository marks project-disabled repository skills", %{tmp_dir: tmp_dir} do
    with_agent_dir(tmp_dir, fn ->
      skill_dir = Path.join([tmp_dir, ".agents", "skills", "turn-off"])
      File.mkdir_p!(skill_dir)

      File.write!(
        Path.join(skill_dir, "SKILL.md"),
        "---\nname: turn-off\ndescription: Off\n---\nBody"
      )

      keep_dir = Path.join([tmp_dir, ".agents", "skills", "keep-on"])
      File.mkdir_p!(keep_dir)

      File.write!(
        Path.join(keep_dir, "SKILL.md"),
        "---\nname: keep-on\ndescription: On\n---\nBody"
      )

      RepoManager.add_repo(tmp_dir)
      RepoManager.set_disabled_skills(tmp_dir, ["turn-off"])

      assert %{skills: skills} = Skills.list_repository(tmp_dir)
      assert Enum.map(skills, &{&1.name, &1.enabled?}) == [{"keep-on", true}, {"turn-off", false}]
    end)
  end

  @tag :tmp_dir
  test "list_global_for_repository applies global setting and project disables", %{
    tmp_dir: tmp_dir
  } do
    with_agent_dir(tmp_dir, fn ->
      for name <- ["global-a", "global-b", "global-c"] do
        dir = Path.join([tmp_dir, "global", name])
        File.mkdir_p!(dir)

        File.write!(
          Path.join(dir, "SKILL.md"),
          "---\nname: #{name}\ndescription: #{name}\n---\nBody"
        )
      end

      File.mkdir_p!(Path.join(tmp_dir, "agent"))
      settings_path = Path.join([tmp_dir, "agent", "settings.json"])

      File.write!(
        settings_path,
        Jason.encode!(%{"disabledSkills" => %{"global" => ["global-a"]}})
      )

      Application.put_env(:sigma_session, :global_skills_dir, Path.join(tmp_dir, "global"))
      on_exit(fn -> Application.delete_env(:sigma_session, :global_skills_dir) end)
      RepoManager.add_repo(tmp_dir)
      RepoManager.set_disabled_skills(tmp_dir, ["global-c"])

      assert %{skills: skills} = Skills.list_global_for_repository(tmp_dir)

      assert Enum.map(skills, &{&1.name, &1.enabled?}) == [
               {"global-a", false},
               {"global-b", true},
               {"global-c", false}
             ]

      # Catalog.build reflects the same enabled flags
      catalog = Catalog.build(tmp_dir)
      automatic = catalog |> Catalog.automatic() |> Enum.map(& &1.name)
      assert "global-a" not in automatic
      assert "global-b" in automatic
      assert "global-c" not in automatic

      assert {:error, :skill_disabled} = Catalog.resolve(catalog, "global:global-a")
      assert {:error, :skill_disabled} = Catalog.resolve(catalog, "global:global-c")
      assert {:ok, _} = Catalog.resolve(catalog, "global:global-b")
    end)
  end

  defp with_agent_dir(tmp_dir, fun) do
    previous = Application.get_env(:sigma_session, :agent_dir)
    Application.put_env(:sigma_session, :agent_dir, Path.join(tmp_dir, "agent"))

    try do
      fun.()
    after
      if previous do
        Application.put_env(:sigma_session, :agent_dir, previous)
      else
        Application.delete_env(:sigma_session, :agent_dir)
      end
    end
  end
end
