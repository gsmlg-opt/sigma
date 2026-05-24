defmodule PiSession.SkillsTest do
  use ExUnit.Case, async: true

  alias PiSession.Skills

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
    assert skill.path == Path.join(skill_dir, "SKILL.md")
    assert skill.source == :repository
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

    assert diagnostic.path == Path.join(skill_dir, "SKILL.md")
    assert diagnostic.message == "description is required"
  end
end
