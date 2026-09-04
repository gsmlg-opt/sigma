defmodule Sigma.Coding.ExtensionRegistryTest do
  use ExUnit.Case, async: false

  alias Sigma.Coding.ExtensionRegistry

  defmodule ValidTool do
    @behaviour Sigma.Coding.Tool

    @impl true
    def name, do: "ext_valid"

    @impl true
    def description, do: "valid extension tool"

    @impl true
    def schema, do: %{}

    @impl true
    def execute(_id, _params, _opts), do: {:ok, %{content: [], details: %{}}}
  end

  defmodule AnotherTool do
    @behaviour Sigma.Coding.Tool

    @impl true
    def name, do: "ext_another"

    @impl true
    def description, do: "another extension tool"

    @impl true
    def schema, do: %{}

    @impl true
    def execute(_id, _params, _opts), do: {:ok, %{content: [], details: %{}}}
  end

  defmodule ReplacementTool do
    @behaviour Sigma.Coding.Tool

    @impl true
    def name, do: "ext_valid"

    @impl true
    def description, do: "replacement"

    @impl true
    def schema, do: %{}

    @impl true
    def execute(_id, _params, _opts), do: {:ok, %{content: [], details: %{}}}
  end

  defmodule IncompleteTool do
    def name, do: "incomplete"
  end

  setup do
    ExtensionRegistry.reset!()
    :ok
  end

  test "register_tool/1 and list_tools/0 keep registration order" do
    assert ExtensionRegistry.list_tools() == []
    assert {:ok, "ext_valid"} = ExtensionRegistry.register_tool(ValidTool)
    assert {:ok, "ext_another"} = ExtensionRegistry.register_tool(AnotherTool)
    assert ExtensionRegistry.list_tools() == [ValidTool, AnotherTool]
  end

  test "duplicate name overwrites module and keeps order slot" do
    assert {:ok, "ext_valid"} = ExtensionRegistry.register_tool(ValidTool)
    assert {:ok, "ext_another"} = ExtensionRegistry.register_tool(AnotherTool)
    assert {:ok, "ext_valid"} = ExtensionRegistry.register_tool(ReplacementTool)
    assert ExtensionRegistry.list_tools() == [ReplacementTool, AnotherTool]
  end

  test "rejects invalid modules" do
    assert {:error, :invalid_tool} = ExtensionRegistry.register_tool(IncompleteTool)
    assert {:error, :invalid_tool} = ExtensionRegistry.register_tool("not_a_module")
    assert ExtensionRegistry.list_tools() == []
  end
end
