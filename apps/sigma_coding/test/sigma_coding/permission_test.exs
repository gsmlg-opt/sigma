defmodule Sigma.Coding.PermissionTest do
  use ExUnit.Case, async: true

  alias Sigma.Coding.Dispatcher
  alias Sigma.Coding.PermissionPolicy
  alias Sigma.Coding.Hooks.Spec
  alias Sigma.Coding.Hooks.Spec.Command

  defmodule MockTool do
    @behaviour Sigma.Coding.Tool

    @impl true
    def name, do: "mock_tool"
    @impl true
    def description, do: "A mock tool for testing"
    @impl true
    def schema, do: %{}

    @impl true
    def execute(id, _params, _opts) do
      {:ok, %{content: [%{type: :text, text: "success #{id}"}], details: %{}}}
    end
  end

  setup do
    test_id = :erlang.unique_integer([:positive])
    dispatcher_name = Module.concat(__MODULE__, "Dispatcher_#{test_id}")
    task_supervisor_name = Module.concat(__MODULE__, "TaskSupervisor_#{test_id}")

    {:ok, _pid} =
      Dispatcher.start_link(
        name: dispatcher_name,
        task_supervisor: task_supervisor_name
      )

    {:ok, dispatcher: dispatcher_name, task_supervisor: task_supervisor_name}
  end

  describe "PermissionInterceptor with simple opts" do
    test "allows tool when :allow_tool matches", %{dispatcher: _d} do
      tool_call = %{id: "1", name: "mock_tool", arguments: %{}}
      opts = [allow_tool: "mock_tool"]
      assert {:ok, _} = Dispatcher.dispatch(tool_call, [MockTool], opts)
    end

    test "denies tool when :allow_tool does not match", %{dispatcher: _d} do
      tool_call = %{id: "1", name: "mock_tool", arguments: %{}}
      opts = [allow_tool: "other_tool"]
      assert {:error, %Sigma.Coding.ToolError{kind: :permission_denied, message: reason}} =
               Dispatcher.dispatch(tool_call, [MockTool], opts)

      assert reason =~ "Permission denied"
    end
  end

  describe "PermissionPolicy GenServer" do
    test "allows tool when default is :allow" do
      {:ok, policy} = PermissionPolicy.start_link(name: nil, default: :allow)
      tool_call = %{id: "1", name: "mock_tool", arguments: %{}}
      assert {:ok, _} = Dispatcher.dispatch(tool_call, [MockTool], permission_policy: policy)
    end

    test "denies tool when default is :deny" do
      {:ok, policy} = PermissionPolicy.start_link(name: nil, default: :deny)
      tool_call = %{id: "1", name: "mock_tool", arguments: %{}}

      assert {:error, %Sigma.Coding.ToolError{kind: :permission_denied, message: reason}} =
               Dispatcher.dispatch(tool_call, [MockTool], permission_policy: policy)

      assert reason =~ "Permission denied by policy"
    end

    test "allows specific tool in denied policy" do
      {:ok, policy} = PermissionPolicy.start_link(name: nil, default: :deny)
      PermissionPolicy.allow_tool(policy, "mock_tool")

      tool_call = %{id: "1", name: "mock_tool", arguments: %{}}
      assert {:ok, _} = Dispatcher.dispatch(tool_call, [MockTool], permission_policy: policy)
    end

    test "denies specific tool in allowed policy" do
      {:ok, policy} = PermissionPolicy.start_link(name: nil, default: :allow)
      PermissionPolicy.deny_tool(policy, "mock_tool")

      tool_call = %{id: "1", name: "mock_tool", arguments: %{}}

      assert {:error, %Sigma.Coding.ToolError{kind: :permission_denied, message: reason}} =
               Dispatcher.dispatch(tool_call, [MockTool], permission_policy: policy)

      assert reason =~ "Permission denied by policy"
    end

    test "toggles all permissions" do
      {:ok, policy} = PermissionPolicy.start_link(name: nil, default: :allow)
      tool_call = %{id: "1", name: "mock_tool", arguments: %{}}

      PermissionPolicy.deny_all(policy)
      assert {:error, _} = Dispatcher.dispatch(tool_call, [MockTool], permission_policy: policy)

      PermissionPolicy.allow_all(policy)
      assert {:ok, _} = Dispatcher.dispatch(tool_call, [MockTool], permission_policy: policy)
    end

    test "explicit ask without a resolver fails with typed approval_required" do
      {:ok, policy} = PermissionPolicy.start_link(name: nil, default: :allow)
      PermissionPolicy.ask_tool(policy, "mock_tool")

      tool_call = %{id: "1", name: "mock_tool", arguments: %{}}

      assert {:error, %Sigma.Coding.ToolError{kind: :approval_required}} =
               Dispatcher.dispatch(tool_call, [MockTool], permission_policy: policy)
    end

    test "explicit ask executes exactly once after allow-once approval" do
      {:ok, policy} = PermissionPolicy.start_link(name: nil, default: :allow)
      PermissionPolicy.ask_tool(policy, "mock_tool")
      test_pid = self()
      tool_call = %{id: "1", name: "mock_tool", arguments: %{}}

      request_fn = fn received ->
        send(test_pid, {:permission_requested, received})
        :allow
      end

      assert {:ok, %{content: [%{text: "success 1"}]}} =
               Dispatcher.dispatch(tool_call, [MockTool],
                 permission_policy: policy,
                 permission_request_fn: request_fn
               )

      assert_receive {:permission_requested, ^tool_call}
      refute_receive {:permission_requested, _other}
    end

    test "unknown tools inherit the allow-all default" do
      {:ok, policy} = PermissionPolicy.start_link(name: nil)
      assert :allow = PermissionPolicy.check(policy, "mcp__new_server__new_tool")
    end

    @tag :tmp_dir
    test "explicit ask runs PermissionRequest, approval, then PreToolUse", %{tmp_dir: tmp_dir} do
      {:ok, policy} = PermissionPolicy.start_link(name: nil, default: :allow)
      PermissionPolicy.ask_tool(policy, "mock_tool")
      order_path = Path.join(tmp_dir, "order")

      permission_hook = %Spec{
        event: :permission_request,
        matcher: :any,
        handler: %Command{
          cmd: "printf 'permission\\n' >> #{inspect(order_path)}; printf '{}'",
          timeout_ms: 1_000
        },
        origin: {:user, "test"},
        dialect: :claude,
        trusted?: true
      }

      pre_tool_hook = %Spec{
        event: :pre_tool_use,
        matcher: :any,
        handler: %Command{
          cmd: "printf 'pre_tool\\n' >> #{inspect(order_path)}; printf '{}'",
          timeout_ms: 1_000
        },
        origin: {:user, "test"},
        dialect: :claude,
        trusted?: true
      }

      request_fn = fn _tool_call ->
        File.write!(order_path, "approval\n", [:append])
        :allow
      end

      assert {:ok, _result} =
               Dispatcher.dispatch(
                 %{id: "1", name: "mock_tool", arguments: %{}},
                 [MockTool],
                 permission_policy: policy,
                 permission_request_fn: request_fn,
                 hook_specs: [permission_hook, pre_tool_hook],
                 cwd: tmp_dir
               )

      assert File.read!(order_path) == "permission\napproval\npre_tool\n"
    end
  end
end
