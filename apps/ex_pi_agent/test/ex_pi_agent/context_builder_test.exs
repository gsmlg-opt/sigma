defmodule PiAgent.ContextBuilderTest do
  use ExUnit.Case, async: true

  alias PiAgent.ContextBuilder
  alias PiAgent.Message, as: AgentMessage
  alias PiAgent.SessionContext

  describe "build/1" do
    test "builds stable system blocks and injects session reminders into the first user message" do
      session_context =
        SessionContext.new(
          skills: [%{name: "repo-skill", description: "Repository scoped skill"}],
          agents_context: ["global rules"],
          current_date: ~D[2026-05-25]
        )

      assert %{
               system: [
                 %{
                   type: :text,
                   text: identity,
                   cache_control: %{type: :ephemeral, ttl: "1h"}
                 },
                 %{
                   type: :text,
                   text: policy,
                   cache_control: %{type: :ephemeral, ttl: "1h"}
                 }
               ],
               system_prompt: system_prompt,
               messages: [
                 %{
                   role: :user,
                   content: [
                     %{type: :text, text: skills_reminder},
                     %{type: :text, text: agents_reminder},
                     %{type: :text, text: "Hi"}
                   ]
                 }
               ],
               tools: [%{name: "read"}]
             } =
               ContextBuilder.build(
                 messages: [AgentMessage.user("1", "Hi")],
                 session_context: session_context,
                 tools: [%{name: "read"}],
                 model: %{id: "mock-model", provider: "mock-provider"}
               )

      assert identity == "You are Pi, an Elixir-based AI coding agent."
      assert policy =~ "You are an interactive agent"
      assert policy =~ "# Laws"
      assert policy =~ "# Memory"
      assert policy =~ "# Environment"
      assert policy =~ "# MCP Server Instructions"
      assert policy =~ "gitStatus:"
      assert policy =~ " - Model: mock-model (mock-provider)"
      assert system_prompt =~ identity
      assert system_prompt =~ policy
      assert skills_reminder =~ "The following skills are available for use with the Skill tool"
      assert agents_reminder =~ "# agentsContext"
      assert agents_reminder =~ "global rules"
      assert agents_reminder =~ "# currentDate\nToday's date is 2026-05-25."
      refute skills_reminder =~ "# Tools"
      refute agents_reminder =~ "# Tools"
    end
  end

  @tag :tmp_dir
  test "includes git status and recent commits in the default system prompt", %{tmp_dir: tmp_dir} do
    git!(tmp_dir, ["init"])
    git!(tmp_dir, ["checkout", "-b", "main"])
    git!(tmp_dir, ["config", "user.email", "pi@example.test"])
    git!(tmp_dir, ["config", "user.name", "Pi Test"])

    path = Path.join(tmp_dir, "README.md")
    File.write!(path, "initial\n")
    git!(tmp_dir, ["add", "README.md"])
    git!(tmp_dir, ["commit", "-m", "initial commit"])
    File.write!(path, "changed\n")

    assert %{system: [_identity, %{text: policy}]} =
             ContextBuilder.build(messages: [AgentMessage.user("1", "Hi")], cwd: tmp_dir)

    assert policy =~ "Primary working directory: #{tmp_dir}"
    assert policy =~ "Is a git repository: true"
    assert policy =~ "Current branch: main"
    assert policy =~ "Main branch (you will usually use this for PRs): main"
    assert policy =~ "Status:\n M README.md"
    assert policy =~ "Recent commits:"
    assert policy =~ "initial commit"
  end

  describe "system_blocks/1" do
    test "keeps explicit custom system prompts backwards compatible" do
      assert [
               %{
                 type: :text,
                 text: "custom system",
                 cache_control: %{type: :ephemeral, ttl: "1h"}
               }
             ] = ContextBuilder.system_blocks("custom system")
    end

    test "normalizes prebuilt text blocks" do
      assert [
               %{
                 type: :text,
                 text: "prebuilt",
                 cache_control: %{type: :ephemeral, ttl: "1h"}
               }
             ] =
               ContextBuilder.system_blocks([
                 %{
                   "type" => "text",
                   "text" => "prebuilt",
                   "cache_control" => %{type: :ephemeral, ttl: "1h"}
                 }
               ])
    end
  end

  defp git!(cwd, args) do
    {output, status} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    assert status == 0, output
    output
  end
end
