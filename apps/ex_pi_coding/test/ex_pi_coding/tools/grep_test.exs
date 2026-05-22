defmodule PiCoding.Tools.GrepTest do
  use ExUnit.Case, async: true

  alias PiCoding.Tools.Grep

  setup do
    dir = System.tmp_dir!() |> Path.join("grep_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "hello.ex"), "defmodule Hello do\n  def world, do: :ok\nend\n")
    File.write!(Path.join(dir, "other.ex"), "defmodule Other do\n  # no match here\nend\n")
    File.write!(Path.join(dir, "notes.txt"), "hello world\nHELLO AGAIN\n")

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "finds matching lines with file:line: format", %{dir: dir} do
    {:ok, result} = Grep.execute("id", %{"pattern" => "defmodule"}, cwd: dir)
    text = hd(result.content).text
    assert text =~ "hello.ex:1:"
    assert text =~ "defmodule Hello"
  end

  test "searches multiple files", %{dir: dir} do
    {:ok, result} = Grep.execute("id", %{"pattern" => "defmodule"}, cwd: dir)
    text = hd(result.content).text
    assert text =~ "hello.ex"
    assert text =~ "other.ex"
  end

  test "case-insensitive search", %{dir: dir} do
    {:ok, result} = Grep.execute("id", %{"pattern" => "hello", "ignore_case" => true}, cwd: dir)
    text = hd(result.content).text
    assert text =~ "hello"
    assert text =~ "HELLO"
  end

  test "filters by glob", %{dir: dir} do
    {:ok, result} = Grep.execute("id", %{"pattern" => "defmodule", "glob" => "*.ex"}, cwd: dir)
    text = hd(result.content).text
    assert text =~ "hello.ex"
    refute text =~ "notes.txt"
  end

  test "returns no matches message", %{dir: dir} do
    {:ok, result} = Grep.execute("id", %{"pattern" => "xyznonexistent"}, cwd: dir)
    assert hd(result.content).text =~ "No matches found"
  end

  test "reports invalid regex", %{dir: dir} do
    assert {:error, msg} = Grep.execute("id", %{"pattern" => "["}, cwd: dir)
    assert msg =~ "Invalid regex"
  end

  test "context lines show surrounding lines", %{dir: dir} do
    {:ok, result} =
      Grep.execute("id", %{"pattern" => "def world", "context" => 1}, cwd: dir)

    text = hd(result.content).text
    assert text =~ "defmodule Hello"
    assert text =~ "def world"
  end

  test "preserves utf-8 content containing NEL continuation bytes", %{dir: dir} do
    File.write!(Path.join(dir, "unicode.md"), "# 项目\n\n其他数据")

    assert {:ok, result} = Grep.execute("id", %{"pattern" => "其他"}, cwd: dir)
    text = hd(result.content).text

    assert String.valid?(text)
    assert text =~ "unicode.md:3: 其他数据"
    assert {:ok, _json} = Jason.encode(%{text: text})
  end

  test "rejects cwd escape", %{dir: dir} do
    assert {:error, _} = Grep.execute("id", %{"pattern" => "root", "path" => "/etc"}, cwd: dir)
  end
end
