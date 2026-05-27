defmodule PiCoding.Hooks.PayloadTest do
  use ExUnit.Case, async: true

  alias PiCoding.Hooks.Payload

  @base_ctx %{
    session_id: "sess_1",
    cwd: "/home/user/project",
    transcript_path: "/home/user/.pi/sessions/--home-user-project--/sess_1.jsonl",
    permission_mode: "default",
    model: "claude-opus-4-7"
  }

  describe "common fields (FR-P1)" do
    test "all events include base fields" do
      payload =
        Payload.build(:pre_tool_use, @base_ctx, %{
          tool_name: "bash",
          tool_use_id: "id1",
          tool_input: %{}
        })

      assert payload["session_id"] == "sess_1"
      assert payload["cwd"] == "/home/user/project"
      assert payload["transcript_path"] =~ "sess_1.jsonl"
      assert payload["permission_mode"] == "default"
      assert payload["hook_event_name"] == "PreToolUse"
    end

    test "turn_id is included when present in ctx" do
      ctx = Map.put(@base_ctx, :turn_id, "turn_42")

      payload =
        Payload.build(:pre_tool_use, ctx, %{
          tool_name: "bash",
          tool_use_id: "id1",
          tool_input: %{}
        })

      assert payload["turn_id"] == "turn_42"
    end

    test "turn_id is omitted when nil" do
      payload =
        Payload.build(:stop, @base_ctx, %{stop_hook_active: false, last_assistant_message: ""})

      refute Map.has_key?(payload, "turn_id")
    end
  end

  describe "SessionStart (FR-P2)" do
    test "includes source and model" do
      payload = Payload.build(:session_start, @base_ctx, %{source: :startup})

      assert payload["hook_event_name"] == "SessionStart"
      assert payload["source"] == "startup"
      assert payload["model"] == "claude-opus-4-7"
    end

    test "source defaults to startup" do
      payload = Payload.build(:session_start, @base_ctx, %{})
      assert payload["source"] == "startup"
    end
  end

  describe "UserPromptSubmit (FR-P2)" do
    test "includes prompt" do
      payload = Payload.build(:user_prompt_submit, @base_ctx, %{prompt: "help me"})

      assert payload["hook_event_name"] == "UserPromptSubmit"
      assert payload["prompt"] == "help me"
    end
  end

  describe "PreToolUse (FR-P2)" do
    test "includes external tool_name, tool_use_id, tool_input" do
      payload =
        Payload.build(:pre_tool_use, @base_ctx, %{
          tool_name: "bash",
          tool_use_id: "tu_1",
          tool_input: %{"command" => "ls"}
        })

      assert payload["hook_event_name"] == "PreToolUse"
      assert payload["tool_name"] == "Bash"
      assert payload["tool_use_id"] == "tu_1"
      assert payload["tool_input"] == %{"command" => "ls"}
    end

    test "url_fetch maps to WebFetch" do
      payload =
        Payload.build(:pre_tool_use, @base_ctx, %{
          tool_name: "url_fetch",
          tool_use_id: "tu_2",
          tool_input: %{"url" => "https://example.com"}
        })

      assert payload["tool_name"] == "WebFetch"
    end

    test "MCP tool name is unchanged" do
      payload =
        Payload.build(:pre_tool_use, @base_ctx, %{
          tool_name: "mcp__server__my_tool",
          tool_use_id: "tu_3",
          tool_input: %{}
        })

      assert payload["tool_name"] == "mcp__server__my_tool"
    end
  end

  describe "PermissionRequest (FR-P2)" do
    test "includes external tool_name and tool_input" do
      payload =
        Payload.build(:permission_request, @base_ctx, %{
          tool_name: "edit",
          tool_use_id: "tu_4",
          tool_input: %{"file_path" => "/etc/hosts"}
        })

      assert payload["hook_event_name"] == "PermissionRequest"
      assert payload["tool_name"] == "Edit"
      assert payload["tool_input"] == %{"file_path" => "/etc/hosts"}
    end
  end

  describe "PostToolUse (FR-P2)" do
    test "includes tool_name, tool_use_id, tool_input, tool_response" do
      payload =
        Payload.build(:post_tool_use, @base_ctx, %{
          tool_name: "write",
          tool_use_id: "tu_5",
          tool_input: %{"file_path" => "a.txt", "content" => "hi"},
          tool_response: "Wrote 2 bytes"
        })

      assert payload["hook_event_name"] == "PostToolUse"
      assert payload["tool_name"] == "Write"
      assert payload["tool_response"] == "Wrote 2 bytes"
    end
  end

  describe "Stop (FR-P2)" do
    test "includes stop_hook_active and last_assistant_message" do
      payload =
        Payload.build(:stop, @base_ctx, %{
          stop_hook_active: true,
          last_assistant_message: "done"
        })

      assert payload["hook_event_name"] == "Stop"
      assert payload["stop_hook_active"] == true
      assert payload["last_assistant_message"] == "done"
    end
  end

  describe "PreCompact (FR-P2)" do
    test "includes trigger and summary" do
      payload = Payload.build(:pre_compact, @base_ctx, %{trigger: :auto, summary: "summary text"})

      assert payload["hook_event_name"] == "PreCompact"
      assert payload["trigger"] == "auto"
      assert payload["summary"] == "summary text"
    end
  end

  describe "JSON-encodability" do
    test "all event payloads are JSON-encodable" do
      events_and_data = [
        {:session_start, %{source: :startup}},
        {:user_prompt_submit, %{prompt: "hello"}},
        {:pre_tool_use, %{tool_name: "bash", tool_use_id: "id", tool_input: %{}}},
        {:permission_request, %{tool_name: "edit", tool_use_id: "id", tool_input: %{}}},
        {:post_tool_use,
         %{tool_name: "write", tool_use_id: "id", tool_input: %{}, tool_response: "ok"}},
        {:stop, %{stop_hook_active: false, last_assistant_message: ""}},
        {:pre_compact, %{trigger: :manual, summary: ""}}
      ]

      for {event, data} <- events_and_data do
        payload = Payload.build(event, @base_ctx, data)
        assert {:ok, _json} = Jason.encode(payload), "#{event} payload not JSON-encodable"
      end
    end
  end
end
