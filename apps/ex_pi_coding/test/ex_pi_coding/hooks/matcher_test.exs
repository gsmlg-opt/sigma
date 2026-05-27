defmodule PiCoding.Hooks.MatcherTest do
  use ExUnit.Case, async: true

  alias PiCoding.Hooks.Matcher
  alias PiCoding.Hooks.Spec

  defp spec(event, matcher) do
    %Spec{
      event: event,
      matcher: matcher,
      handler: nil,
      origin: {:user, "/home"},
      dialect: :codex
    }
  end

  # ---------------------------------------------------------------------------
  # Tool-name aliasing
  # ---------------------------------------------------------------------------

  describe "to_external_name/1" do
    for {internal, external} <- [
          {"bash", "Bash"},
          {"read", "Read"},
          {"write", "Write"},
          {"edit", "Edit"},
          {"grep", "Grep"},
          {"glob", "Glob"},
          {"ls", "LS"},
          {"url_fetch", "WebFetch"},
          {"ask_user_question", "AskUserQuestion"}
        ] do
      @internal internal
      @external external
      test "#{internal} → #{external}" do
        assert Matcher.to_external_name(@internal) == @external
      end
    end

    test "mcp tool names are returned unchanged" do
      assert Matcher.to_external_name("mcp__server__tool") == "mcp__server__tool"
    end

    test "unknown internal names are passed through unchanged" do
      assert Matcher.to_external_name("SomeTool") == "SomeTool"
    end
  end

  # ---------------------------------------------------------------------------
  # match?/2 — tool events
  # ---------------------------------------------------------------------------

  describe "match?/2 for tool events" do
    for event <- [:pre_tool_use, :post_tool_use, :permission_request] do
      @event event

      test "#{event}: :any matcher matches any tool" do
        assert Matcher.match?(spec(@event, :any), %{tool_name: "bash"})
        assert Matcher.match?(spec(@event, :any), %{tool_name: "edit"})
      end

      test "#{event}: exact matcher matches external name" do
        assert Matcher.match?(spec(@event, "Bash"), %{tool_name: "bash"})
        refute Matcher.match?(spec(@event, "Bash"), %{tool_name: "edit"})
      end

      test "#{event}: pipe-list matcher" do
        assert Matcher.match?(spec(@event, "Edit|Write"), %{tool_name: "edit"})
        assert Matcher.match?(spec(@event, "Edit|Write"), %{tool_name: "write"})
        refute Matcher.match?(spec(@event, "Edit|Write"), %{tool_name: "bash"})
      end

      test "#{event}: regex matcher" do
        re = Regex.compile!("mcp__.*")
        assert Matcher.match?(spec(@event, re), %{tool_name: "mcp__server__tool"})
        refute Matcher.match?(spec(@event, re), %{tool_name: "bash"})
      end

      test "#{event}: UrlFetch alias accepted" do
        assert Matcher.match?(spec(@event, "UrlFetch"), %{tool_name: "url_fetch"})
      end
    end
  end

  # ---------------------------------------------------------------------------
  # match?/2 — SessionStart
  # ---------------------------------------------------------------------------

  describe "match?/2 for SessionStart" do
    test "filters by source" do
      assert Matcher.match?(spec(:session_start, "startup"), %{source: "startup"})
      assert Matcher.match?(spec(:session_start, "resume"), %{source: "resume"})
      refute Matcher.match?(spec(:session_start, "startup"), %{source: "resume"})
    end

    test ":any matches all sources" do
      assert Matcher.match?(spec(:session_start, :any), %{source: "startup"})
      assert Matcher.match?(spec(:session_start, :any), %{source: "compact"})
    end

    test "pipe-list of sources" do
      assert Matcher.match?(spec(:session_start, "startup|resume"), %{source: "startup"})
      assert Matcher.match?(spec(:session_start, "startup|resume"), %{source: "resume"})
      refute Matcher.match?(spec(:session_start, "startup|resume"), %{source: "clear"})
    end
  end

  # ---------------------------------------------------------------------------
  # match?/2 — Stop and UserPromptSubmit always fire
  # ---------------------------------------------------------------------------

  describe "match?/2 for UserPromptSubmit and Stop" do
    test "always returns true regardless of matcher" do
      assert Matcher.match?(spec(:user_prompt_submit, "Bash"), %{})
      assert Matcher.match?(spec(:user_prompt_submit, :any), %{})
      assert Matcher.match?(spec(:stop, "Edit"), %{})
      assert Matcher.match?(spec(:stop, :any), %{})
    end
  end

  # ---------------------------------------------------------------------------
  # match?/2 — PreCompact
  # ---------------------------------------------------------------------------

  describe "match?/2 for PreCompact" do
    test "filters by trigger" do
      assert Matcher.match?(spec(:pre_compact, "manual"), %{trigger: "manual"})
      refute Matcher.match?(spec(:pre_compact, "manual"), %{trigger: "auto"})
    end

    test ":any matches all triggers" do
      assert Matcher.match?(spec(:pre_compact, :any), %{trigger: "auto"})
      assert Matcher.match?(spec(:pre_compact, :any), %{trigger: "manual"})
    end
  end

  # ---------------------------------------------------------------------------
  # AC-1 acceptance check
  # ---------------------------------------------------------------------------

  test "AC-1: Bash matcher hits internal bash tool" do
    s = spec(:pre_tool_use, "Bash")
    assert Matcher.match?(s, %{tool_name: "bash"})
  end

  test "AC-1: Edit|Write matcher hits internal edit and write" do
    s = spec(:pre_tool_use, "Edit|Write")
    assert Matcher.match?(s, %{tool_name: "edit"})
    assert Matcher.match?(s, %{tool_name: "write"})
    refute Matcher.match?(s, %{tool_name: "bash"})
  end
end
