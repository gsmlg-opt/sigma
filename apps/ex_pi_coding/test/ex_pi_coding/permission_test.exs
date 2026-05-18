defmodule ExPiCoding.PermissionTest do
  use ExUnit.Case, async: true

  alias ExPiCoding.Dispatcher
  alias ExPiCoding.PermissionPolicy

  defmodule MockTool do
    @behaviour ExPiCoding.Tool

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
      assert {:error, reason} = Dispatcher.dispatch(tool_call, [MockTool], opts)
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

      assert {:error, reason} =
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

      assert {:error, reason} =
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
  end
end
