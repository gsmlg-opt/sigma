defmodule Sigma.Coding.DispatcherHooksTest do
  use ExUnit.Case, async: true

  alias Sigma.Coding.{Dispatcher, PermissionPolicy, ToolResult}
  alias Sigma.Coding.Hooks.Discovery

  @moduletag :tmp_dir

  defmodule EchoTool do
    @behaviour Sigma.Coding.Tool
    def name, do: "echo_tool"
    def description, do: "Echo arguments"
    def schema, do: %{}

    def execute(_id, arguments, opts) do
      send(opts[:test_pid], {:executed, arguments})
      {:ok, %ToolResult{content: [%{type: :text, text: "original result"}]}}
    end
  end

  test "PreToolUse input changes and additional context both reach the next request", %{
    tmp_dir: cwd
  } do
    output = %{
      "hookSpecificOutput" => %{
        "hookEventName" => "PreToolUse",
        "permissionDecision" => "allow",
        "updatedInput" => %{"text" => "updated"},
        "additionalContext" => "remember the hook context"
      }
    }

    specs = hooks("PreToolUse", json_command(output), "echo_tool")

    call = %{
      id: "pre",
      name: "echo_tool",
      arguments: %{"text" => "old", "remove_old_field" => true}
    }

    assert {:ok, %ToolResult{content: content}} =
             Dispatcher.dispatch(call, [EchoTool], hook_specs: specs, cwd: cwd, test_pid: self())

    assert_received {:executed, %{"text" => "updated"}}
    assert Enum.any?(content, &(&1.text =~ "remember the hook context"))
  end

  test "PermissionRequest allow skips the approval callback", %{tmp_dir: cwd} do
    policy = start_supervised!({PermissionPolicy, name: nil, default: :ask})

    specs =
      hooks(
        "PermissionRequest",
        json_command(%{
          "hookSpecificOutput" => %{
            "hookEventName" => "PermissionRequest",
            "decision" => %{"behavior" => "allow"}
          }
        }),
        "echo_tool"
      )

    assert {:ok, %ToolResult{}} =
             Dispatcher.dispatch(
               %{id: "permission", name: "echo_tool", arguments: %{}},
               [EchoTool],
               hook_specs: specs,
               cwd: cwd,
               test_pid: self(),
               permission_policy: policy,
               permission_request_fn: fn _ -> flunk("hook already granted permission") end
             )

    assert_received {:executed, %{}}
  end

  test "PostToolUse exit two replaces the result with stderr feedback", %{tmp_dir: cwd} do
    specs = hooks("PostToolUse", "printf 'post hook feedback' >&2; exit 2", "echo_tool")

    assert {:ok, %ToolResult{content: [%{text: "post hook feedback"}]}} =
             Dispatcher.dispatch(%{id: "post", name: "echo_tool", arguments: %{}}, [EchoTool],
               hook_specs: specs,
               cwd: cwd,
               test_pid: self()
             )

    assert_received {:executed, %{}}
  end

  defp hooks(event, command, matcher) do
    {:ok, specs} =
      Discovery.parse(
        Jason.encode!(%{
          "hooks" => %{
            event => [
              %{
                "matcher" => matcher,
                "hooks" => [%{"type" => "command", "command" => command, "timeout" => 2}]
              }
            ]
          }
        }),
        :codex
      )

    Enum.map(specs, &%{&1 | origin: {:user, "test"}, trusted?: true})
  end

  defp json_command(value) do
    "printf '%s' '" <> String.replace(Jason.encode!(value), "'", "'\\''") <> "'"
  end
end
