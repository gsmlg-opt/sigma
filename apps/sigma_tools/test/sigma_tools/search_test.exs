defmodule Sigma.Tools.SearchTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  test "search groups matches under hashline headers", %{tmp_dir: tmp_dir} do
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
    assert text =~ ~r/^\[a\.txt#[0-9A-F]{4}\]/m
    assert text =~ "2:world"
  end
end
