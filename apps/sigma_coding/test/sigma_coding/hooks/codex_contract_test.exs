defmodule Sigma.Coding.Hooks.CodexContractTest do
  use ExUnit.Case, async: true

  alias Sigma.Coding.Hooks.{Catalog, CodexOutput, Discovery, Matcher, Outcome, Payload}
  alias Sigma.Coding.Hooks.Spec.{Command, McpTool}
  alias Sigma.Coding.Hooks.Spec

  @ctx %{
    session_id: "s",
    turn_id: "t",
    cwd: "/repo",
    transcript_path: nil,
    model: "model",
    permission_mode: "default"
  }
  @names ~w(PreModelRequest PostModelRequest PreToolUse PermissionRequest PostToolUse PreCompact PostCompact SessionStart SessionEnd UserPromptSubmit SubagentStart SubagentStop Stop Interrupt)

  test "catalog follows the pinned Codex declaration order and timeout policy" do
    assert Catalog.reference_commit() == "7a152fbcf9ecd32d9fb4b45edf80127ee4c8499e"
    assert Enum.map(Catalog.events(), & &1.name) == @names
    assert Enum.all?(Catalog.events(), & &1.available?)

    for event <- Catalog.events() do
      if event.name in ["SessionEnd", "Interrupt"] do
        assert event.default_timeout == 1
        assert event.max_timeout == 3
      else
        assert event.default_timeout == 600
        assert event.max_timeout == nil
      end
    end
  end

  test "discovery recognizes all events and applies defaults and shutdown timeout caps" do
    hooks =
      Map.new(@names, &{&1, [%{"hooks" => [%{"type" => "command", "command" => "echo ok"}]}]})

    assert {:ok, specs} = Discovery.parse(Jason.encode!(%{"hooks" => hooks}), :pi)
    assert length(specs) == 14

    for spec <- specs do
      expected = if spec.event in [:session_end, :interrupt], do: 1_000, else: 600_000
      assert spec.handler.timeout_ms == expected
    end

    for name <- ["SessionEnd", "Interrupt"] do
      assert {:ok, [spec]} =
               parse(name, %{
                 "type" => "command",
                 "command" => "true",
                 "timeout" => 90,
                 "async" => true
               })

      assert spec.handler.timeout_ms == 3_000
      assert spec.handler.async == (name != "SessionEnd")
    end
  end

  test "unknown types are never inferred as commands and async remains explicit" do
    assert {:ok, [spec]} = parse("Stop", %{"type" => "future", "command" => "must not execute"})
    refute match?(%Command{}, spec.handler)
    assert spec.unsupported_reason

    assert {:ok, [spec]} =
             parse("Stop", %{"type" => "command", "command" => "true", "async" => true})

    assert spec.handler.async

    assert {:ok, [spec]} =
             parse("Stop", %{"type" => "command", "command" => "true", "async" => "yes"})

    assert spec.unsupported_reason
  end

  test "MCP is executable except on SessionEnd; prompt and agent remain declarations only" do
    handler = %{
      "type" => "mcp_tool",
      "server" => "server",
      "tool" => "tool",
      "input" => %{"a" => 1}
    }

    assert {:ok, [%Spec{handler: %McpTool{input: %{"a" => 1}}, unsupported_reason: nil}]} =
             parse("Stop", handler)

    assert {:ok, [spec]} = parse("SessionEnd", handler)
    assert spec.unsupported_reason

    for type <- ["http", "prompt", "agent"] do
      assert {:ok, [spec]} = parse("Stop", %{"type" => type, "command" => "must not execute"})
      assert spec.unsupported_reason
    end
  end

  test "invalid regex does not become match-all; ignored event matchers remain ignored" do
    json =
      Jason.encode!(%{
        "hooks" => %{"PreToolUse" => [%{"matcher" => "[", "hooks" => [%{"command" => "true"}]}]}
      })

    assert {:ok, []} = Discovery.parse(json, :pi)

    for event <- [:pre_model_request, :post_model_request, :user_prompt_submit, :stop, :interrupt] do
      assert Matcher.match?(spec(event, "never"), %{})
    end

    assert Matcher.match?(spec(:session_start, "fork"), %{source: :fork})
    assert Matcher.match?(spec(:session_end, "other"), %{reason: "user_close"})
    assert Matcher.match?(spec(:subagent_start, "worker"), %{agent_type: "worker"})
    assert Matcher.match?(spec(:subagent_stop, "explorer"), %{agent_type: "explorer"})
    assert Matcher.match?(spec(:post_compact, "manual"), %{trigger: :manual})
  end

  test "tool aliases select canonical apply_patch and spawn_agent without renaming payloads" do
    assert Matcher.match?(spec(:pre_tool_use, "Write|Edit"), %{tool_name: "apply_patch"})
    assert Matcher.match?(spec(:pre_tool_use, "Agent"), %{tool_name: "spawn_agent"})
    assert Matcher.match?(spec(:pre_tool_use, "Bash"), %{tool_name: "exec_command"})

    for tool <- ["apply_patch", "spawn_agent", "mcp__server__tool", "read"] do
      assert Payload.build(:pre_tool_use, @ctx, %{tool_name: tool})["tool_name"] == tool
    end
  end

  test "model request payloads are observer envelopes with nullable usage and no permission field" do
    pre = Payload.build(:pre_model_request, @ctx)

    assert pre == %{
             "session_id" => "s",
             "turn_id" => "t",
             "cwd" => "/repo",
             "transcript_path" => nil,
             "model" => "model",
             "hook_event_name" => "PreModelRequest"
           }

    post = Payload.build(:post_model_request, @ctx, %{status: :cancelled})

    assert post ==
             Map.merge(pre, %{
               "hook_event_name" => "PostModelRequest",
               "status" => "cancelled",
               "error" => nil,
               "token_usage" => nil
             })
  end

  test "event payload differences match Codex schemas" do
    ending = Payload.build(:session_end, @ctx, %{reason: "user_close"})

    assert ending == %{
             "session_id" => "s",
             "cwd" => "/repo",
             "transcript_path" => nil,
             "hook_event_name" => "SessionEnd",
             "reason" => "other"
           }

    refute Map.has_key?(Payload.build(:session_start, @ctx), "turn_id")
    refute Map.has_key?(Payload.build(:permission_request, @ctx), "tool_use_id")
    compact = Payload.build(:pre_compact, @ctx, %{summary: "not on wire"})
    refute Map.has_key?(compact, "summary")
    refute Map.has_key?(compact, "permission_mode")

    subagent =
      Payload.build(:subagent_stop, Map.merge(@ctx, %{agent_id: "a", agent_type: "worker"}), %{
        last_assistant_message: "done"
      })

    assert subagent["agent_id"] == "a"
    assert subagent["agent_type"] == "worker"
    assert subagent["agent_transcript_path"] == nil
    assert subagent["last_assistant_message"] == "done"
  end

  test "nonzero exit status takes precedence over stdout directives" do
    raw = %{exit: 2, stdout: ~s({"continue":false}), stderr: "real reason"}
    assert Outcome.decode(:stop, raw, :pi) == {:block, "real reason"}
    assert {:proceed, [_]} = Outcome.evaluate(:pre_tool_use, %{raw | stderr: ""}, :codex)
    assert :proceed = Outcome.decode(:stop, %{raw | exit: 1}, :codex)
  end

  test "observers and SessionEnd cannot steer regardless of output or exit code" do
    for event <- [:pre_model_request, :post_model_request, :session_end, :interrupt] do
      assert Outcome.decode(
               event,
               raw(%{"continue" => false, "decision" => "block", "reason" => "deny"}),
               :pi
             ) == :proceed

      assert Outcome.decode(event, %{exit: 2, stdout: "", stderr: "deny"}, :pi) == :proceed
    end
  end

  test "PermissionRequest has real allow and deny decisions" do
    for {behavior, expected} <- [{"allow", :allow}, {"deny", {:block, "denied"}}] do
      output = %{
        "hookSpecificOutput" => %{
          "hookEventName" => "PermissionRequest",
          "decision" => %{"behavior" => behavior, "message" => "denied"}
        }
      }

      assert Outcome.decode(:permission_request, raw(output), :pi) == expected
    end

    output = %{
      "hookSpecificOutput" => %{
        "hookEventName" => "PermissionRequest",
        "decision" => %{"behavior" => "allow", "updatedInput" => %{}}
      }
    }

    assert {:proceed, [_]} = Outcome.evaluate(:permission_request, raw(output), :pi)
  end

  test "input replacement retains context and later complete replacement wins" do
    output = %{
      "hookSpecificOutput" => %{
        "hookEventName" => "PreToolUse",
        "permissionDecision" => "allow",
        "updatedInput" => %{"new" => 1},
        "additionalContext" => "context"
      }
    }

    outcome = Outcome.decode(:pre_tool_use, raw(output), :pi)
    assert Outcome.control(outcome) == {:replace_input, %{"new" => 1}}
    assert Outcome.context(outcome) == "context"
    folded = Outcome.fold([outcome, {:replace_input, %{"last" => 2}}])
    assert Outcome.control(folded) == {:replace_input, %{"last" => 2}}
    assert Outcome.context(folded) == "context"
  end

  test "nullable reserved permission fields are absent and non-object tool input is diagnosed" do
    output = %{
      "hookSpecificOutput" => %{
        "hookEventName" => "PermissionRequest",
        "decision" => %{
          "behavior" => "allow",
          "updatedInput" => nil,
          "updatedPermissions" => nil
        }
      }
    }

    assert {:allow, []} = Outcome.evaluate(:permission_request, raw(output), :pi)

    output = %{
      "hookSpecificOutput" => %{
        "hookEventName" => "PreToolUse",
        "permissionDecision" => "deny",
        "permissionDecisionReason" => "denied",
        "updatedInput" => nil
      }
    }

    assert {{:block, "denied"}, []} = Outcome.evaluate(:pre_tool_use, raw(output), :pi)

    output = put_in(output, ["hookSpecificOutput", "permissionDecision"], "allow")
    output = put_in(output, ["hookSpecificOutput", "updatedInput"], [1, 2])
    assert {:proceed, [warning]} = Outcome.evaluate(:pre_tool_use, raw(output), :pi)
    assert warning =~ "Sigma tools require"
  end

  test "post tool reason without decision fails unless stopping execution" do
    assert {:proceed, [warning]} =
             Outcome.evaluate(:post_tool_use, raw(%{"reason" => "why"}), :pi)

    assert warning =~ "reason without decision"

    assert {{:halt, nil}, []} =
             Outcome.evaluate(:post_tool_use, raw(%{"continue" => false, "reason" => "why"}), :pi)
  end

  test "async outputs retain context while ignoring unsupported controls" do
    for {event, name, controls} <- [
          {:pre_tool_use, "PreToolUse", %{"continue" => false}},
          {:post_tool_use, "PostToolUse", %{"suppressOutput" => true}},
          {:user_prompt_submit, "UserPromptSubmit", %{"decision" => "block"}}
        ] do
      output =
        Map.merge(controls, %{
          "hookSpecificOutput" => %{"hookEventName" => name, "additionalContext" => "context"}
        })

      assert {{:context, "context"}, []} = CodexOutput.evaluate_async(event, raw(output))
    end

    assert {:proceed, [_]} =
             CodexOutput.evaluate_async(:pre_tool_use, %{exit: 2, stdout: "", stderr: "failure"})
  end

  test "async output still validates schema before extracting context" do
    for invalid <- [false, 4, "future", %{}] do
      output = %{
        "continue" => false,
        "decision" => invalid,
        "hookSpecificOutput" => %{
          "hookEventName" => "PostToolUse",
          "additionalContext" => "invalid"
        }
      }

      assert {:proceed, [_]} = CodexOutput.evaluate_async(:post_tool_use, raw(output))
    end

    output = %{
      "hookSpecificOutput" => %{
        "hookEventName" => "PreToolUse",
        "permissionDecision" => "unknown",
        "additionalContext" => "invalid"
      }
    }

    assert {:proceed, [_]} = CodexOutput.evaluate_async(:pre_tool_use, raw(output))
  end

  test "unsupported steering fields and malformed output fail diagnostically" do
    outputs = [
      %{"continue" => false},
      %{"decision" => "approve"},
      %{"hookSpecificOutput" => %{"permissionDecision" => "deny"}},
      %{
        "hookSpecificOutput" => %{"hookEventName" => "PreToolUse", "permissionDecision" => "ask"}
      },
      %{"hookSpecificOutput" => false},
      %{"future" => true}
    ]

    for output <- outputs do
      assert {:proceed, [_ | _]} = Outcome.evaluate(:pre_tool_use, raw(output), :pi)
    end
  end

  test "plain stdout only adds context on session start, subagent start and prompt submit" do
    for event <- [:session_start, :subagent_start, :user_prompt_submit] do
      assert Outcome.decode(event, %{exit: 0, stdout: "context", stderr: ""}, :pi) ==
               {:context, "context"}
    end

    assert Outcome.decode(:pre_tool_use, %{exit: 0, stdout: "diagnostic", stderr: ""}, :pi) ==
             :proceed

    assert {:proceed, [_]} =
             Outcome.evaluate(:post_tool_use, %{exit: 0, stdout: "diagnostic", stderr: ""}, :pi)
  end

  defp raw(output), do: %{exit: 0, stdout: Jason.encode!(output), stderr: ""}

  defp spec(event, matcher),
    do: %Spec{event: event, matcher: matcher, handler: nil, origin: nil, dialect: :pi}

  defp parse(name, handler),
    do: Discovery.parse(Jason.encode!(%{"hooks" => %{name => [%{"hooks" => [handler]}]}}), :pi)
end
