defmodule ExPiCoding.Tools.GlobTest do
  use ExUnit.Case, async: true

  alias ExPiCoding.Tools.Glob

  setup do
    dir = System.tmp_dir!() |> Path.join("glob_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "mix.exs"), "# mix")
    File.write!(Path.join(dir, "lib/foo.ex"), "# foo")
    File.write!(Path.join(dir, "lib/bar.ex"), "# bar")
    File.mkdir_p!(Path.join(dir, "lib/sub"))
    File.write!(Path.join(dir, "lib/sub/baz.ex"), "# baz")

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "matches files in root with *.exs pattern", %{dir: dir} do
    {:ok, result} = Glob.execute("id", %{"pattern" => "*.exs"}, cwd: dir)
    text = hd(result.content).text
    assert text =~ "mix.exs"
    refute text =~ "foo.ex"
  end

  test "matches files recursively with ** pattern", %{dir: dir} do
    {:ok, result} = Glob.execute("id", %{"pattern" => "**/*.ex"}, cwd: dir)
    text = hd(result.content).text
    assert text =~ "lib/foo.ex"
    assert text =~ "lib/bar.ex"
    assert text =~ "lib/sub/baz.ex"
  end

  test "returns relative paths", %{dir: dir} do
    {:ok, result} = Glob.execute("id", %{"pattern" => "**/*.ex"}, cwd: dir)
    text = hd(result.content).text
    refute text =~ dir
  end

  test "returns message when no files match", %{dir: dir} do
    {:ok, result} = Glob.execute("id", %{"pattern" => "**/*.ts"}, cwd: dir)
    assert hd(result.content).text =~ "No files matched"
  end

  test "respects limit", %{dir: dir} do
    {:ok, result} = Glob.execute("id", %{"pattern" => "**/*.ex", "limit" => 2}, cwd: dir)
    text = hd(result.content).text
    assert text =~ "limit"
    assert result.details.count == 2
  end

  test "rejects cwd escape", %{dir: dir} do
    assert {:error, _} = Glob.execute("id", %{"pattern" => "*.ex", "path" => "/etc"}, cwd: dir)
  end
end
