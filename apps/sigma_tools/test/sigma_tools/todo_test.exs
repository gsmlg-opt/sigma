defmodule Sigma.Tools.TodoTest do
  use ExUnit.Case, async: true

  alias Sigma.Coding.Tool
  alias Sigma.Tools.{Store, Todo}

  setup do
    store = Store.new()
    %{store: store, opts: [tool_state: store]}
  end

  test "metadata is write/sequential/standard" do
    meta = Tool.metadata(Todo, %{id: "tc", name: "todo", arguments: %{"action" => "list"}})

    assert meta.effect == :write
    assert meta.concurrency == :sequential
    assert meta.interruptible
    assert meta.approval_tier == :standard
  end

  test "list on empty store", %{opts: opts} do
    assert {:ok, result} = Todo.execute("tc", %{"action" => "list"}, opts)
    [%{text: text}] = result.content
    assert text == "No todos"
    assert result.details.todos == []
    assert result.details.next_id == 1
  end

  test "add/list/update/complete/remove/clear main path", %{opts: opts, store: store} do
    assert {:ok, add1} =
             Todo.execute("tc", %{"action" => "add", "content" => "Ship WO-2"}, opts)

    assert add1.details.item.id == "1"
    assert add1.details.item.status == "pending"

    assert {:ok, add2} =
             Todo.execute(
               "tc",
               %{"action" => "add", "content" => "Write docs", "status" => "in_progress"},
               opts
             )

    assert add2.details.item.id == "2"
    assert add2.details.item.status == "in_progress"

    assert {:ok, listed} = Todo.execute("tc", %{"action" => "list"}, opts)
    [%{text: list_text}] = listed.content
    assert list_text =~ "[ ] #1: Ship WO-2 (pending)"
    assert list_text =~ "[~] #2: Write docs (in_progress)"

    assert {:ok, updated} =
             Todo.execute(
               "tc",
               %{
                 "action" => "update",
                 "id" => "1",
                 "content" => "Ship todo tool",
                 "status" => "in_progress"
               },
               opts
             )

    assert updated.details.item.content == "Ship todo tool"
    assert updated.details.item.status == "in_progress"

    assert {:ok, completed} = Todo.execute("tc", %{"action" => "complete", "id" => "1"}, opts)
    assert completed.details.item.status == "completed"
    [%{text: complete_text}] = completed.content
    assert complete_text =~ "Completed todo #1"

    assert {:ok, removed} = Todo.execute("tc", %{"action" => "remove", "id" => "2"}, opts)
    assert Enum.map(removed.details.todos, & &1.id) == ["1"]

    assert {:ok, cleared} = Todo.execute("tc", %{"action" => "clear"}, opts)
    assert cleared.details.todos == []
    assert cleared.details.next_id == 1
    assert Store.get_todo_state(store) == %{items: [], next_id: 1}
  end

  test "fails without tool_state" do
    assert {:error, "todo requires session tool_state"} =
             Todo.execute("tc", %{"action" => "list"}, [])
  end

  test "fails on unknown action", %{opts: opts} do
    assert {:error, reason} = Todo.execute("tc", %{"action" => "toggle"}, opts)
    assert reason =~ "Unknown action"
  end

  test "add requires content", %{opts: opts} do
    assert {:error, "content is required for add"} =
             Todo.execute("tc", %{"action" => "add"}, opts)
  end

  test "update/complete/remove require id and reject missing ids", %{opts: opts} do
    assert {:ok, _} = Todo.execute("tc", %{"action" => "add", "content" => "one"}, opts)

    assert {:error, "id is required"} =
             Todo.execute("tc", %{"action" => "complete"}, opts)

    assert {:error, "Todo #99 not found"} =
             Todo.execute("tc", %{"action" => "remove", "id" => "99"}, opts)

    assert {:error, "Todo #missing not found"} =
             Todo.execute(
               "tc",
               %{"action" => "update", "id" => "missing", "content" => "x"},
               opts
             )
  end

  test "rejects invalid status", %{opts: opts} do
    assert {:error, reason} =
             Todo.execute(
               "tc",
               %{"action" => "add", "content" => "x", "status" => "blocked"},
               opts
             )

    assert reason =~ "Invalid status"
  end

  test "state is scoped to the Store table", %{store: store, opts: opts} do
    assert {:ok, _} = Todo.execute("tc", %{"action" => "add", "content" => "persist"}, opts)
    assert [%{id: "1", content: "persist"}] = Store.get_todo_state(store).items

    other = Store.new()
    assert Store.get_todo_state(other) == %{items: [], next_id: 1}

    assert {:ok, listed} = Todo.execute("tc", %{"action" => "list"}, tool_state: other)
    [%{text: text}] = listed.content
    assert text == "No todos"
  end
end
