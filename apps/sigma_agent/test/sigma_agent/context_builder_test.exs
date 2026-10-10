defmodule Sigma.Agent.ContextBuilderTest do
  use ExUnit.Case, async: true

  alias Sigma.Agent.ContextBuilder
  alias Sigma.Agent.Message, as: AgentMessage
  alias Sigma.Agent.SessionContext

  describe "build_messages/2 tool result completion" do
    test "completes an unresolved tool call before the next user prompt" do
      messages = [assistant_calls(["call-1"]), AgentMessage.user("continue", "继续")]

      assert [assistant, result, user] =
               ContextBuilder.build_messages(messages, SessionContext.new())

      assert assistant.content |> Enum.map(& &1.id) == ["call-1"]
      assert_missing_result(result, "call-1")
      assert user.role == :user
      assert user.content == "继续"
    end

    test "completes an unresolved tool call at the end of context" do
      assert [assistant, result] =
               ContextBuilder.build_messages([assistant_calls(["call-1"])], SessionContext.new())

      assert assistant.role == :assistant
      assert_missing_result(result, "call-1")
    end

    test "preserves real results and their order in a partially completed batch" do
      third =
        AgentMessage.tool_result("third-result", %{
          tool_call_id: "call-3",
          tool_name: "read_file",
          content: "third output",
          is_error: true,
          timestamp: 1_003
        })

      first =
        AgentMessage.tool_result("first-result", %{
          tool_call_id: "call-1",
          tool_name: "read_file",
          content: "first output",
          is_error: false,
          timestamp: 1_001
        })

      messages = [
        assistant_calls(["call-1", "call-2", "call-3"]),
        third,
        first,
        AgentMessage.user("continue", "continue")
      ]

      assert [_assistant, third_result, first_result, missing, user] =
               ContextBuilder.build_messages(messages, SessionContext.new())

      assert third_result.tool_call_id == "call-3"
      assert third_result.content == [%{type: :text, text: "third output"}]
      assert third_result.is_error
      assert third_result.timestamp == 1_003
      assert first_result.tool_call_id == "call-1"
      assert first_result.content == [%{type: :text, text: "first output"}]
      refute first_result.is_error
      assert first_result.timestamp == 1_001
      assert_missing_result(missing, "call-2")
      assert user.role == :user
    end

    test "leaves a completed tool batch unchanged" do
      messages = [
        assistant_calls(["call-1"]),
        AgentMessage.tool_result("result", %{
          tool_call_id: "call-1",
          tool_name: "read_file",
          content: "recorded output",
          is_error: false
        }),
        AgentMessage.user("continue", "continue")
      ]

      assert ContextBuilder.build_messages(messages, SessionContext.new()) ==
               Sigma.Agent.MessageTransformer.convert_to_llm(messages)
    end

    test "completes each batch before a subsequent assistant boundary" do
      messages = [assistant_calls(["call-1"]), assistant_calls(["call-2"])]

      assert [first, first_result, second, second_result] =
               ContextBuilder.build_messages(messages, SessionContext.new())

      assert first.role == :assistant
      assert_missing_result(first_result, "call-1")
      assert second.role == :assistant
      assert_missing_result(second_result, "call-2")
    end

    test "completes a call whose recorded result is redacted from provider context" do
      result = %{
        AgentMessage.tool_result("result", %{
          tool_call_id: "call-1",
          tool_name: "read_file",
          content: "hidden output"
        })
        | redacted: true
      }

      assert [_assistant, missing] =
               ContextBuilder.build_messages(
                 [assistant_calls(["call-1"]), result],
                 SessionContext.new()
               )

      assert_missing_result(missing, "call-1")
    end
  end

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

      assert identity == "You are Sigma, an Elixir-based AI coding agent."
      assert policy =~ "You are an interactive agent"
      assert policy =~ "# Laws"
      assert policy =~ "# Memory"
      assert policy =~ "# Environment"
      assert policy =~ "# MCP Server Instructions"
      assert policy =~ "gitStatus:"
      assert policy =~ " - Model: mock-model (mock-provider)"
      assert system_prompt =~ identity
      assert system_prompt =~ policy

      assert skills_reminder =~
               "The following skills provide specialized instructions for specific tasks"

      assert skills_reminder =~ "Use the read tool to load a skill's file"
      refute skills_reminder =~ "Skill tool"
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
    git!(tmp_dir, ["config", "user.name", "Sigma Test"])

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

  test "renders default system prompt template with runtime placeholders" do
    prompt = ContextBuilder.system_prompt_template()

    assert prompt =~ "You are Sigma, an Elixir-based AI coding agent."
    assert prompt =~ "# Laws"
    assert prompt =~ "# Memory"
    assert prompt =~ "# Environment"
    assert prompt =~ "{{inject_memory}}"
    assert prompt =~ "{{inject_mcp_context}}"
    assert prompt =~ "{{inject_git_context}}"
    assert prompt =~ "Primary working directory: {{inject_cwd}}"
  end

  defp assistant_calls(ids) do
    AgentMessage.assistant("assistant", %{
      content:
        Enum.map(ids, fn id ->
          %{type: :tool_call, id: id, name: "read_file", arguments: %{"path" => "file.ex"}}
        end),
      stop_reason: :tool_use,
      timestamp: 1_000
    })
  end

  defp assert_missing_result(result, id) do
    assert result.role == :tool_result
    assert result.tool_call_id == id
    assert result.tool_name == "read_file"
    assert result.is_error

    assert result.content == [
             %{
               type: :text,
               text: "No tool result was recorded; execution outcome is unknown."
             }
           ]
  end

  defp git!(cwd, args) do
    {output, status} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    assert status == 0, output
    output
  end
end
