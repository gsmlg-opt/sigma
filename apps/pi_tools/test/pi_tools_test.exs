defmodule PiToolsTest do
  use ExUnit.Case, async: true

  test "default tools expose oh-my-pi canonical names only" do
    assert Enum.map(PiTools.default_tools(), &PiCoding.Tool.name/1) == [
             "ask",
             "read",
             "write",
             "bash",
             "edit",
             "search",
             "find"
           ]
  end

  test "catalog includes planned tools without exposing them" do
    planned_names = PiTools.Catalog.planned() |> Enum.map(& &1.name)

    assert "job" in planned_names
    assert "todo" in planned_names
    assert "task" in planned_names
    assert "lsp" in planned_names
    assert "ast_grep" in planned_names
    assert "ast_edit" in planned_names
    assert "web_search" in planned_names
    assert "github" in planned_names

    exposed_names = PiTools.default_tools() |> Enum.map(&PiCoding.Tool.name/1)

    refute "job" in exposed_names
    refute "lsp" in exposed_names
    refute "ast_grep" in exposed_names
  end

  test "edit tool schema steers models to hashline operations" do
    definition = PiCoding.Tool.ai_definition(PiTools.Edit)
    input_schema = definition.parameters["properties"]["input"]

    assert definition.description =~ "[path#TAG]"
    assert definition.description =~ "replace N..M:"
    assert input_schema["description"] =~ "Do not send unified diff"
    assert input_schema["description"] =~ "replace N..M:"
  end
end
