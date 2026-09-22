defmodule Sigma.Session.SlashCommandsTest do
  use ExUnit.Case, async: true

  alias Sigma.Session.SlashCommands

  test "leaves regular prompts unchanged" do
    assert SlashCommands.expand("hello") == :not_command
  end

  test "expands init into an AGENTS.md instruction prompt" do
    assert {:ok, prompt} = SlashCommands.expand("/init")

    assert prompt =~ "Set up a minimal AGENTS.md"
    assert prompt =~ "Project AGENTS.md gives Sigma Agent persistent, team-shared instructions"
    assert prompt =~ "`~/.pi/agent/AGENTS.md`"
    assert prompt =~ "Create project skills at `.agents/skills/<skill-name>/SKILL.md`"
    refute prompt =~ "CLAUDE.md"
    refute prompt =~ "Claude Code"
    refute prompt =~ ".claude/skills"
  end

  test "preserves init command arguments" do
    assert {:ok, prompt} = SlashCommands.expand("/init update")

    assert prompt =~ "Command arguments: update"
  end

  test "rejects unknown slash commands" do
    assert SlashCommands.expand("/compact") == {:error, "Unknown slash command: /compact"}
  end

  @tag :tmp_dir
  test "invokes a local skill and expands arguments once", %{tmp_dir: tmp_dir} do
    skill_dir = Path.join([tmp_dir, ".agents", "skills", "example"])
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      "---\nname: example\ndescription: Example skill\n---\nDo $ARGUMENTS once."
    )

    assert {:ok, first} =
             SlashCommands.expand("/skill example inspect this", cwd: tmp_dir)

    assert first.content == "Do inspect this once."
    assert first.skill.digest =~ ~r/^sha256:[0-9a-f]{64}$/
    assert [%{root: root, release: release}] = first.prepared_resources
    assert File.dir?(root)

    File.write!(Path.join(skill_dir, "SKILL.md"), "changed mutable source")
    assert first.content == "Do inspect this once."
    assert :ok = release.()
    refute File.exists?(root)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      "---\nname: example\ndescription: Example skill\n---\nDo $ARGUMENTS once."
    )

    assert {:ok, second} =
             SlashCommands.expand("/example inspect this", cwd: tmp_dir)

    assert second.content == first.content
    assert second.skill.digest =~ ~r/^sha256:[0-9a-f]{64}$/
    assert [%{release: release_second}] = second.prepared_resources
    assert :ok = release_second.()
  end

  @tag :tmp_dir
  test "denies explicit invocation when the package document opts out", %{tmp_dir: tmp_dir} do
    skill_dir = Path.join([tmp_dir, ".agents", "skills", "private"])
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      "---\nname: private\ndescription: Private skill\nuser-invocable: false\n---\nBody"
    )

    assert {:error, "Skill is not supported: private"} =
             SlashCommands.expand("/skill private", cwd: tmp_dir)
  end
end
