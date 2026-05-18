defmodule ExPiCoding.Tools.LSTest do
  use ExUnit.Case, async: true

  alias ExPiCoding.Tools.LS

  setup do
    dir = System.tmp_dir!() |> Path.join("ls_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join(dir, "mix.exs"), "# mix")
    File.write!(Path.join(dir, "README.md"), "# readme")

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "lists directory contents with type prefix", %{dir: dir} do
    {:ok, result} = LS.execute("id", %{}, cwd: dir)
    text = hd(result.content).text
    assert text =~ "[dir]  lib"
    assert text =~ "[file] mix.exs"
    assert text =~ "[file] README.md"
  end

  test "lists a subdirectory by path", %{dir: dir} do
    File.write!(Path.join(dir, "lib/foo.ex"), "# foo")
    {:ok, result} = LS.execute("id", %{"path" => "lib"}, cwd: dir)
    text = hd(result.content).text
    assert text =~ "foo.ex"
    refute text =~ "mix.exs"
  end

  test "returns error for non-directory path", %{dir: dir} do
    assert {:error, _} = LS.execute("id", %{"path" => "mix.exs"}, cwd: dir)
  end

  test "respects limit", %{dir: dir} do
    {:ok, result} = LS.execute("id", %{"limit" => 1}, cwd: dir)
    text = hd(result.content).text
    assert text =~ "limit"
    assert result.details.count == 1
  end

  test "rejects cwd escape", %{dir: dir} do
    assert {:error, _} = LS.execute("id", %{"path" => "/etc"}, cwd: dir)
  end
end
