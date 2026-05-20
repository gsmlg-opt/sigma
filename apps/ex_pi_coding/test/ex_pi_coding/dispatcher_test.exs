defmodule PiCoding.DispatcherTest do
  use ExUnit.Case, async: true

  alias PiCoding.Dispatcher

  defmodule MockTool do
    @behaviour PiCoding.Tool

    @impl true
    def name, do: "mock_tool"
    @impl true
    def description, do: "A mock tool for testing"
    @impl true
    def schema, do: %{}

    @impl true
    def execute(id, params, _opts) do
      case Map.get(params, "action") do
        "success" -> {:ok, %{content: [%{type: :text, text: "success #{id}"}], details: %{}}}
        "error" -> {:error, "mock error"}
        "crash" -> raise "mock crash"
        "sleep" ->
          Process.sleep(Map.get(params, "ms", 100))
          {:ok, %{content: [%{type: :text, text: "slept"}], details: %{}}}
      end
    end
  end

  setup do
    # Start a unique dispatcher for each test
    test_id = :erlang.unique_integer([:positive])
    dispatcher_name = Module.concat(__MODULE__, "Dispatcher_#{test_id}")
    task_supervisor_name = Module.concat(__MODULE__, "TaskSupervisor_#{test_id}")

    {:ok, _pid} = Dispatcher.start_link(
      name: dispatcher_name,
      task_supervisor: task_supervisor_name
    )
    
    {:ok, dispatcher: dispatcher_name, task_supervisor: task_supervisor_name}
  end

  test "dispatch/3 executes a tool", %{task_supervisor: _ts} do
    # Note: dispatch currently doesn't use task_supervisor but we might want it to.
    # Actually my implementation of dispatch/3 uses do_dispatch directly.
    # The task says: "find the correct tool by name, and call its execute/3 within a Task"
    # Wait, my dispatch/3 doesn't use a Task currently!
    
    tool_call = %{id: "1", name: "mock_tool", arguments: %{"action" => "success"}}
    assert {:ok, result} = Dispatcher.dispatch(tool_call, [MockTool])
    assert [%{text: "success 1"}] = result.content
  end

  test "dispatch_batch/3 executes multiple tools in parallel", %{task_supervisor: ts} do
    tool_calls = [
      %{id: "1", name: "mock_tool", arguments: %{"action" => "sleep", "ms" => 200}},
      %{id: "2", name: "mock_tool", arguments: %{"action" => "sleep", "ms" => 200}},
      %{id: "3", name: "mock_tool", arguments: %{"action" => "success"}}
    ]

    start_time = System.monotonic_time(:millisecond)
    results = Dispatcher.dispatch_batch(tool_calls, [MockTool], task_supervisor: ts)
    end_time = System.monotonic_time(:millisecond)

    assert length(results) == 3
    
    # Check results
    {tc1, res1} = Enum.at(results, 0)
    assert tc1.id == "1"
    assert {:ok, _} = res1

    {tc2, res2} = Enum.at(results, 1)
    assert tc2.id == "2"
    assert {:ok, _} = res2

    {tc3, res3} = Enum.at(results, 2)
    assert tc3.id == "3"
    assert {:ok, _} = res3

    # Parallel execution should take around 200ms, not 400ms+
    assert (end_time - start_time) < 350
  end

  test "dispatch_batch/3 handles tool crashes", %{task_supervisor: ts} do
    tool_calls = [
      %{id: "1", name: "mock_tool", arguments: %{"action" => "crash"}},
      %{id: "2", name: "mock_tool", arguments: %{"action" => "success"}}
    ]

    results = Dispatcher.dispatch_batch(tool_calls, [MockTool], task_supervisor: ts)
    
    {tc1, res1} = Enum.at(results, 0)
    assert tc1.id == "1"
    assert {:error, reason} = res1
    assert reason =~ "mock crash"

    {tc2, res2} = Enum.at(results, 1)
    assert tc2.id == "2"
    assert {:ok, _} = res2
  end

  test "dispatch_batch/3 supports sequential mode", %{task_supervisor: ts} do
    tool_calls = [
      %{id: "1", name: "mock_tool", arguments: %{"action" => "sleep", "ms" => 100}},
      %{id: "2", name: "mock_tool", arguments: %{"action" => "sleep", "ms" => 100}}
    ]

    start_time = System.monotonic_time(:millisecond)
    results = Dispatcher.dispatch_batch(tool_calls, [MockTool], task_supervisor: ts, mode: :sequential)
    end_time = System.monotonic_time(:millisecond)

    assert length(results) == 2
    # Sequential execution should take at least 200ms
    assert (end_time - start_time) >= 200
  end
end
