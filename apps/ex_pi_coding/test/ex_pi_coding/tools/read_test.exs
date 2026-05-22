defmodule PiCoding.Tools.ReadTest do
  use ExUnit.Case, async: true
  alias PiCoding.Tools.Read

  @cwd File.cwd!()

  setup do
    tmp_dir = Path.join(@cwd, "tmp/test_read_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    file_path = Path.join(tmp_dir, "test.txt")
    File.write!(file_path, "Line 1\nLine 2\nLine 3\nLine 4\nLine 5")

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{tmp_dir: tmp_dir, file_path: file_path}
  end

  test "reads entire file", %{tmp_dir: tmp_dir} do
    params = %{"path" => "test.txt"}
    opts = [cwd: tmp_dir]

    assert {:ok, result} = Read.execute("1", params, opts)
    assert [%{text: text}] = result.content
    assert text == "Line 1\nLine 2\nLine 3\nLine 4\nLine 5"
  end

  test "reads with offset", %{tmp_dir: tmp_dir} do
    params = %{"path" => "test.txt", "offset" => 3}
    opts = [cwd: tmp_dir]

    assert {:ok, result} = Read.execute("1", params, opts)
    assert [%{text: text}] = result.content
    assert text =~ "Line 3\nLine 4\nLine 5"
    assert text =~ "[Showing lines 3-5 of 5.]"
  end

  test "reads with offset and limit", %{tmp_dir: tmp_dir} do
    params = %{"path" => "test.txt", "offset" => 2, "limit" => 2}
    opts = [cwd: tmp_dir]

    assert {:ok, result} = Read.execute("1", params, opts)
    assert [%{text: text}] = result.content
    assert text =~ "Line 2\nLine 3"
    assert text =~ "[Showing lines 2-3 of 5. Use offset=4 to continue.]"
  end

  test "preserves utf-8 content containing NEL continuation bytes", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "unicode.md"), "# 项目\n\n其他数据")

    assert {:ok, result} = Read.execute("1", %{"path" => "unicode.md"}, cwd: tmp_dir)
    assert [%{text: text}] = result.content
    assert String.valid?(text)
    assert text == "# 项目\n\n其他数据"
    assert {:ok, _json} = Jason.encode(%{text: text})
  end

  test "fails for path outside cwd", %{tmp_dir: tmp_dir} do
    params = %{"path" => "/etc/passwd"}
    opts = [cwd: tmp_dir]

    assert {:error, reason} = Read.execute("1", params, opts)
    assert reason =~ "outside of the current working directory"
  end
end
