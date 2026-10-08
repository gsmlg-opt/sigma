defmodule Sigma.Coding.DispatcherPermissionResultTest do
  use ExUnit.Case, async: true

  alias Sigma.Coding.{Dispatcher, PermissionPolicy, ToolError, ToolResult}

  defmodule RejectedTool do
    @behaviour Sigma.Coding.Tool

    def name, do: "rejected_tool"
    def description, do: "Reports a permission error after execution"
    def schema, do: %{}

    def execute(_id, _arguments, opts) do
      send(opts[:test_pid], :tool_executed)
      {:error, ToolError.new(:permission_denied, "rejected after execution")}
    end
  end

  test "observed permission denials produce error results without executing the tool" do
    for action <- [:deny, :ask] do
      policy = start_supervised!({PermissionPolicy, default: action}, id: action)
      call = %{id: "denied", name: RejectedTool.name(), arguments: %{}}

      assert {:ok, %ToolResult{is_error: true, content: [%{type: :text, text: message}]}} =
               Dispatcher.dispatch(call, [RejectedTool],
                 permission_policy: policy,
                 observed_permission_denials: true,
                 test_pid: self()
               )

      assert message =~ if(action == :deny, do: "Permission denied", else: "Approval required")
      refute_received :tool_executed
    end
  end

  test "permission denials retain the default error contract" do
    for {action, kind} <- [deny: :permission_denied, ask: :approval_required] do
      policy = start_supervised!({PermissionPolicy, default: action}, id: action)
      call = %{id: "denied", name: RejectedTool.name(), arguments: %{}}

      assert {:error, %ToolError{kind: ^kind}} =
               Dispatcher.dispatch(call, [RejectedTool],
                 permission_policy: policy,
                 test_pid: self()
               )

      refute_received :tool_executed
    end
  end

  test "an error after execution remains ambiguous even when its kind is permission_denied" do
    supervisor = start_supervised!(Task.Supervisor)
    call = %{id: "executed", name: RejectedTool.name(), arguments: %{}}

    assert {:error, %ToolError{kind: :permission_denied, message: "rejected after execution"}} =
             Dispatcher.dispatch(call, [RejectedTool],
               observed_permission_denials: true,
               task_supervisor: supervisor,
               test_pid: self()
             )

    assert_received :tool_executed
  end
end
