defmodule Sigma.Web.HooksConfigTest do
  use ExUnit.Case, async: true

  alias Sigma.Web.HooksConfig

  test "catalog includes all events with runtime availability and timeout defaults" do
    events = HooksConfig.events()

    assert Enum.map(events, & &1.name) ==
             ~w(PreModelRequest PostModelRequest PreToolUse PermissionRequest PostToolUse PreCompact PostCompact SessionStart SessionEnd UserPromptSubmit SubagentStart SubagentStop Stop Interrupt)

    assert Enum.all?(events, & &1.available?)
    assert Enum.find(events, &(&1.name == "UserPromptSubmit")).default_timeout == 600

    for event <- events do
      bounded? = event.name in ~w(SessionEnd Interrupt)
      assert event.default_timeout == if(bounded?, do: 1, else: 600)
      assert event.max_timeout == if(bounded?, do: 3, else: nil)
    end
  end

  test "Codex command options are editable without losing unrelated fields" do
    json =
      ~s({"hooks":{"Stop":[{"hooks":[{"type":"command","command":"old","async":true,"additionalContextLimit":0}]}]}})

    assert {:ok, updated} =
             HooksConfig.put_command(json, "Stop", {0, 0}, %{
               "command" => "new",
               "statusMessage" => "Checking",
               "async" => "false"
             })

    assert Jason.decode!(updated)["hooks"]["Stop"] == [
             %{
               "hooks" => [
                 %{
                   "type" => "command",
                   "command" => "new",
                   "async" => false,
                   "statusMessage" => "Checking",
                   "additionalContextLimit" => 0
                 }
               ]
             }
           ]
  end

  test "bounded Codex events reject timeouts over three seconds" do
    for event <- ~w(SessionEnd Interrupt) do
      assert {:error, message} =
               HooksConfig.put_command("{}", event, :new, %{
                 "command" => "echo ready",
                 "timeout" => "4"
               })

      assert message == "Timeout cannot exceed 3 seconds for #{event}."

      assert {:ok, _} =
               HooksConfig.put_command("{}", event, :new, %{
                 "command" => "echo ready",
                 "timeout" => "3"
               })
    end
  end

  test "empty configuration does not create commands or hook keys" do
    assert {:ok, %{}} = HooksConfig.decode("{}")
    assert {:ok, %{"hooks" => %{}}} = HooksConfig.decode(~s({"hooks":{}}))
    assert HooksConfig.rows(%{}, "SessionStart") == []
  end

  test "adding a command preserves root data, unknown events and handler fields" do
    original = %{
      "version" => 3,
      "hooks" => %{
        "FutureEvent" => [
          %{"custom" => true, "hooks" => [%{"type" => "prompt", "prompt" => "Check"}]}
        ],
        "PreToolUse" => [%{"hooks" => [%{"type" => "http", "url" => "https://example.test"}]}]
      }
    }

    assert {:ok, json} =
             HooksConfig.put_command(Jason.encode!(original), "PreToolUse", :new, %{
               "command" => "echo ready",
               "matcher" => "Bash|Edit",
               "timeout" => "20"
             })

    edited = Jason.decode!(json)
    assert edited["version"] == 3
    assert edited["hooks"]["FutureEvent"] == original["hooks"]["FutureEvent"]
    assert hd(edited["hooks"]["PreToolUse"]) == hd(original["hooks"]["PreToolUse"])

    assert List.last(edited["hooks"]["PreToolUse"]) == %{
             "matcher" => "Bash|Edit",
             "hooks" => [%{"type" => "command", "command" => "echo ready", "timeout" => 20}]
           }
  end

  test "editing preserves aliases, unknown fields and unsupported sibling handlers" do
    command = %{"cmd" => "old", "timeoutSec" => 12, "statusMessage" => "Busy", "future" => %{}}
    sibling = %{"type" => "agent", "prompt" => "Review"}
    group = %{"matcher" => "Bash", "extra" => 1, "hooks" => [command, sibling]}
    original = %{"hooks" => %{"PreToolUse" => [group]}, "other" => [1, 2]}

    assert {:ok, json} =
             HooksConfig.put_command(Jason.encode!(original), "PreToolUse", {0, 0}, %{
               "command" => "new",
               "matcher" => "Edit",
               "timeout" => "45"
             })

    assert {:ok, data} = HooksConfig.decode(json)
    assert data["other"] == [1, 2]

    assert data["hooks"]["PreToolUse"] == [
             %{
               group
               | "matcher" => "Edit",
                 "hooks" => [%{command | "cmd" => "new", "timeoutSec" => 45}, sibling]
             }
           ]

    assert [command_row, sibling_row] = HooksConfig.rows(data, "PreToolUse")
    assert command_row.group_index == 0
    assert command_row.handler_index == 0
    assert command_row.matcher == "Edit"
    assert sibling_row.handler == sibling
    assert sibling_row.handler_index == 1
  end

  test "blank timeout restores default and removes every explicit timeout alias" do
    handler = %{"command" => "old", "timeout" => 10, "timeoutSec" => 12, "timeout_sec" => 15}
    json = Jason.encode!(%{"hooks" => %{"Stop" => [%{"matcher" => "*", "hooks" => [handler]}]}})

    assert {:ok, updated} =
             HooksConfig.put_command(json, "Stop", {0, 0}, %{"command" => "new", "timeout" => ""})

    assert Jason.decode!(updated)["hooks"]["Stop"] == [%{"hooks" => [%{"command" => "new"}]}]
  end

  test "timeout_sec alias is retained when edited" do
    json = ~s({"hooks":{"Stop":[{"hooks":[{"cmd":"old","timeout_sec":10}]}]}})

    assert {:ok, updated} =
             HooksConfig.put_command(json, "Stop", {0, 0}, %{"command" => "new", "timeout" => 20})

    assert Jason.decode!(updated)["hooks"]["Stop"] == [
             %{"hooks" => [%{"cmd" => "new", "timeout_sec" => 20}]}
           ]
  end

  test "removing a command preserves siblings and removes an empty group" do
    sibling = %{"type" => "http", "url" => "https://example.test", "headers" => %{}}
    group = %{"matcher" => "Bash", "extra" => true, "hooks" => [%{"command" => "first"}, sibling]}
    other_group = %{"hooks" => [%{"command" => "second"}]}
    json = Jason.encode!(%{"hooks" => %{"PreToolUse" => [group, other_group]}, "enabled" => true})

    assert {:ok, updated} = HooksConfig.remove_command(json, "PreToolUse", {0, 0})

    assert Jason.decode!(updated) == %{
             "hooks" => %{"PreToolUse" => [%{group | "hooks" => [sibling]}, other_group]},
             "enabled" => true
           }

    assert {:ok, updated} = HooksConfig.remove_command(updated, "PreToolUse", {1, 0})
    assert Jason.decode!(updated)["hooks"]["PreToolUse"] == [%{group | "hooks" => [sibling]}]
  end

  test "unsupported handlers require advanced JSON for editing and removal" do
    for handler <- [%{"type" => "prompt"}, %{"url" => "https://example.test"}] do
      json = Jason.encode!(%{"hooks" => %{"Stop" => [%{"hooks" => [handler]}]}})

      assert {:error, message} =
               HooksConfig.put_command(json, "Stop", {0, 0}, %{"command" => "new"})

      assert message =~ "advanced JSON"
      assert {:error, ^message} = HooksConfig.remove_command(json, "Stop", {0, 0})
    end
  end

  test "invalid JSON and unsupported shapes stay in advanced JSON" do
    for json <- [
          "[",
          "[]",
          ~s({"hooks":[]}),
          ~s({"hooks":null}),
          ~s({"hooks":{"Stop":{}}}),
          ~s({"hooks":{"Stop":[false]}}),
          ~s({"hooks":{"Stop":[{"hooks":{}}]}}),
          ~s({"hooks":{"Stop":[{"hooks":[null]}]}}),
          ~s({"hooks":{"Stop":[{"matcher":2}]}})
        ] do
      assert {:error, message} = HooksConfig.decode(json)
      assert message =~ "advanced JSON"
    end
  end

  test "runtime-compatible direct handlers and snake case events remain advanced-only" do
    for json <- [
          ~s({"hooks":{"Stop":[{"command":"echo existing"}]}}),
          ~s({"hooks":{"PreToolUse":[{"matcher":"Bash","cmd":"echo existing"}]}}),
          ~s({"hooks":{"pre_tool_use":[{"hooks":[{"command":"echo existing"}]}]}}),
          ~s({"hooks":{"stop":[]}})
        ] do
      assert {:error, message} = HooksConfig.decode(json)
      assert message =~ "advanced JSON"

      assert {:error, ^message} =
               HooksConfig.put_command(json, "Stop", :new, %{"command" => "new"})
    end
  end

  test "invalid commands, timeouts, events and locations return errors" do
    json = ~s({"hooks":{"Stop":[{"hooks":[{"command":"old"}]}]}})

    for command <- ["", "  ", nil, 1] do
      assert {:error, "Command is required."} =
               HooksConfig.put_command(json, "Stop", :new, %{"command" => command})
    end

    for timeout <- [0, -1, "0", "1.5", "bad", true] do
      assert {:error, message} =
               HooksConfig.put_command(json, "Stop", :new, %{
                 "command" => "new",
                 "timeout" => timeout
               })

      assert message =~ "positive integer"
    end

    for location <- [{-1, 0}, {0, -1}, {0, 2}, {3, 0}, "0:0", nil] do
      assert {:error, _} = HooksConfig.put_command(json, "Stop", location, %{"command" => "new"})
      assert {:error, _} = HooksConfig.remove_command(json, "Stop", location)
    end

    assert {:error, _} = HooksConfig.put_command(json, "FutureEvent", :new, %{"command" => "new"})

    assert {:error, "Matcher must be text."} =
             HooksConfig.put_command(json, "Stop", :new, %{"command" => "new", "matcher" => 1})
  end
end
