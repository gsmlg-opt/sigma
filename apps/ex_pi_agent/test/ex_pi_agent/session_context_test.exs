defmodule PiAgent.SessionContextTest do
  use ExUnit.Case, async: true

  alias PiAgent.Message, as: AgentMessage
  alias PiAgent.SessionContext

  describe "new/1" do
    test "builds ordered context injections from known sources" do
      context =
        SessionContext.new(
          global_agents: "global rules",
          skills: [%{name: "repo-skill", description: "Helps with repository work"}],
          worktree: "worktree rules",
          repo_agents: "# Context: /repo/AGENTS.md\n\nrepo rules",
          hooks: ["hook one", {"Commit Hook", "hook two"}],
          current_date: ~D[2026-05-25]
        )

      text = SessionContext.to_text(context)

      assert text =~ "# Skills\n\n- repo-skill: Helps with repository work"
      assert text =~ "# Hooks\n\nhook one"
      assert text =~ "# Commit Hook\n\nhook two"
      assert text =~ "# agentsContext\n\nCodebase and user instructions are shown below."
      assert text =~ "global rules"
      assert text =~ "worktree rules"
      assert text =~ "# Context: /repo/AGENTS.md\n\nrepo rules"
      assert text =~ "# currentDate\nToday's date is 2026-05-25."

      assert [
               %{type: :hooks},
               %{type: :hooks},
               %{type: :skills},
               %{type: :agents_context}
             ] = context.injections
    end

    test "drops blank sources" do
      assert SessionContext.new(global_agents: "", repo_agents: nil) |> SessionContext.empty?()
    end
  end

  describe "skills_context/1" do
    test "renders skills as a markdown list and skips disabled model invocation" do
      assert SessionContext.skills_context([
               %{name: "global-skill", description: "Global skill description"},
               %{
                 name: "manual-skill",
                 description: "Manual only",
                 disable_model_invocation?: true
               },
               %{"name" => "repo-skill", "description" => "Repository scoped skill"}
             ]) ==
               "- global-skill: Global skill description\n- repo-skill: Repository scoped skill"
    end
  end

  describe "to_blocks/1" do
    test "renders each injection as a separate system reminder block" do
      context =
        SessionContext.new(
          hooks: "SessionStart:startup hook success: Success",
          skills: [%{name: "repo-skill", description: "Repository scoped skill"}],
          agents_context: ["# Context: /repo/AGENTS.md\n\nrules"],
          current_date: ~D[2026-05-25]
        )

      assert [
               %{type: :text, text: hook_reminder},
               %{type: :text, text: skills_reminder},
               %{type: :text, text: agents_reminder}
             ] = SessionContext.to_blocks(context)

      assert hook_reminder =~ "<system-reminder>"
      assert hook_reminder =~ "# Hooks\n\nSessionStart:startup hook success: Success"

      assert skills_reminder =~
               "<system-reminder>\nThe following skills are available for use with the Skill tool:\n\n"

      assert skills_reminder =~ "- repo-skill: Repository scoped skill"
      refute skills_reminder =~ "# Skills"
      assert agents_reminder =~ "# agentsContext"
      assert agents_reminder =~ "# Context: /repo/AGENTS.md\n\nrules"
      assert agents_reminder =~ "# currentDate\nToday's date is 2026-05-25."
    end
  end

  describe "inject_messages/2" do
    test "prepends session context to the first user message" do
      context =
        SessionContext.new(
          hooks: "SessionStart:startup hook success: Success",
          repo_agents: "# Context: /repo/AGENTS.md\n\nrules",
          current_date: ~D[2026-05-25]
        )

      messages = [
        AgentMessage.user("1", "hello"),
        AgentMessage.assistant("2", %{
          content: "hi",
          api: "anthropic",
          provider: "anthropic",
          model: "claude-3"
        })
      ]

      assert [
               %AgentMessage{
                 role: :user,
                 content: [
                   %{type: :text, text: hook_reminder},
                   %{type: :text, text: agents_reminder},
                   %{type: :text, text: "hello"}
                 ]
               },
               %AgentMessage{role: :assistant}
             ] = SessionContext.inject_messages(messages, context)

      assert hook_reminder =~ "<system-reminder>\nAs you answer the user's questions"
      assert hook_reminder =~ "# Hooks\n\nSessionStart:startup hook success: Success"
      assert agents_reminder =~ "# agentsContext"
      assert agents_reminder =~ "# Context: /repo/AGENTS.md\n\nrules"
      assert agents_reminder =~ "# currentDate\nToday's date is 2026-05-25."
      assert agents_reminder =~ "</system-reminder>"
    end

    test "keeps messages unchanged when context is empty" do
      messages = [AgentMessage.user("1", "hello")]
      assert SessionContext.inject_messages(messages, SessionContext.new()) == messages
    end
  end
end
