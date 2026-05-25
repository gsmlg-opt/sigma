defmodule PiWeb.SlashCommandsTest do
  use ExUnit.Case, async: true

  alias PiWeb.SlashCommands

  test "leaves regular prompts unchanged" do
    assert SlashCommands.expand("hello") == :not_command
  end

  test "expands init into an AGENTS.md instruction prompt" do
    assert {:ok, prompt} = SlashCommands.expand("/init")

    assert prompt =~ "Create or update `AGENTS.md`"
    assert prompt =~ "Inspect the current repository before editing"
    assert prompt =~ "update it in place"
  end

  test "preserves init command arguments" do
    assert {:ok, prompt} = SlashCommands.expand("/init update")

    assert prompt =~ "Command arguments: update"
  end

  test "rejects unknown slash commands" do
    assert SlashCommands.expand("/compact") == {:error, "Unknown slash command: /compact"}
  end
end
