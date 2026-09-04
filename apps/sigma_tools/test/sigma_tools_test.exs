defmodule Sigma.ToolsTest do
  use ExUnit.Case, async: true

  defmodule ExtProbe do
    @behaviour Sigma.Coding.Tool

    @impl true
    def name, do: "ext_probe"

    @impl true
    def description, do: "probe"

    @impl true
    def schema, do: %{}

    @impl true
    def execute(_id, _params, _opts), do: {:ok, %{content: [], details: %{}}}
  end

  test "default tools expose oh-my-pi canonical names only" do
    assert Enum.map(Sigma.Tools.default_tools(), &Sigma.Coding.Tool.name/1) == [
             "ask",
             "read",
             "write",
             "bash",
             "edit",
             "search",
             "find",
             "todo"
           ]
  end

  test "extension registry does not alter default_tools/0" do
    before = Enum.map(Sigma.Tools.default_tools(), &Sigma.Coding.Tool.name/1)
    assert {:ok, "ext_probe"} = Sigma.Coding.ExtensionRegistry.register_tool(ExtProbe)
    assert Enum.map(Sigma.Tools.default_tools(), &Sigma.Coding.Tool.name/1) == before
    refute "ext_probe" in before
  after
    Sigma.Coding.ExtensionRegistry.reset!()
  end

  test "catalog includes planned tools without exposing them" do
    planned_names = Sigma.Tools.Catalog.planned() |> Enum.map(& &1.name)
    implemented_names = Sigma.Tools.Catalog.implemented() |> Enum.map(& &1.name)

    assert "job" in planned_names
    assert "todo" in implemented_names
    refute "todo" in planned_names
    assert "task" in planned_names
    assert "lsp" in planned_names
    assert "ast_grep" in planned_names
    assert "ast_edit" in planned_names
    assert "web_search" in planned_names
    assert "github" in planned_names

    exposed_names = Sigma.Tools.default_tools() |> Enum.map(&Sigma.Coding.Tool.name/1)

    assert "todo" in exposed_names
    refute "job" in exposed_names
    refute "lsp" in exposed_names
    refute "ast_grep" in exposed_names
  end

  test "edit tool schema steers models to hashline operations" do
    definition = Sigma.Coding.Tool.ai_definition(Sigma.Tools.Edit)
    input_schema = definition.parameters["properties"]["input"]

    assert definition.description =~ "[path#TAG]"
    assert definition.description =~ "replace N..M:"
    assert input_schema["description"] =~ "Do not send unified diff"
    assert input_schema["description"] =~ "replace N..M:"
  end
end
