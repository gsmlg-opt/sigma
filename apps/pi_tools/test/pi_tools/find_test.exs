defmodule PiTools.FindTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  test "find returns matching relative paths", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.write!(Path.join(tmp_dir, "lib/a.ex"), "defmodule A do end")
    File.write!(Path.join(tmp_dir, "lib/a.txt"), "A")

    assert {:ok, result} =
             PiTools.Find.execute("find", %{"paths" => ["lib/**/*.ex"]}, cwd: tmp_dir)

    [%{text: text}] = result.content
    assert text =~ "lib/a.ex"
    refute text =~ "lib/a.txt"
  end
end
