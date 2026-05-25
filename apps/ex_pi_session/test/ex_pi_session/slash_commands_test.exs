defmodule PiSession.SlashCommandsTest do
  use ExUnit.Case, async: true

  alias PiSession.SlashCommands

  test "leaves regular prompts unchanged" do
    assert SlashCommands.expand("hello") == :not_command
  end

  test "expands init into an AGENTS.md instruction prompt" do
    assert {:ok, prompt} = SlashCommands.expand("/init")

    assert prompt =~ "Set up a minimal AGENTS.md"
    assert prompt =~ "Project AGENTS.md gives Pi Agent persistent, team-shared instructions"
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
end
