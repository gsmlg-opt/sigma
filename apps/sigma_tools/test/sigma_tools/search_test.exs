defmodule Sigma.Tools.SearchTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  test "search groups numbered matches under paths without snapshot tags", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "a.txt"), "hello\nworld\n")
    store = Sigma.Tools.Store.new()

    assert {:ok, result} =
             Sigma.Tools.Search.execute(
               "search",
               %{"pattern" => "world", "paths" => "a.txt"},
               cwd: tmp_dir,
               tool_state: store
             )

    [%{text: text}] = result.content
    assert text =~ "[a.txt]\n2:world"
    assert text =~ "2:world"
    assert [] = :ets.tab2list(store)
  end
end
