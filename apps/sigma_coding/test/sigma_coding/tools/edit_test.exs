defmodule Sigma.Coding.Tools.EditTest do
  use ExUnit.Case, async: true
  alias Sigma.Coding.Tools.Edit

  @cwd File.cwd!()

  setup do
    tmp_dir = Path.join(@cwd, "tmp/test_edit_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    file_path = Path.join(tmp_dir, "test.txt")
    File.write!(file_path, "Original content")

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{tmp_dir: tmp_dir, file_path: file_path}
  end

  test "overwrites file when old_content is nil", %{tmp_dir: tmp_dir, file_path: file_path} do
    params = %{"path" => "test.txt", "content" => "New content"}
    opts = [cwd: tmp_dir]

    assert {:ok, result} = Edit.execute("1", params, opts)
    assert [%{text: text}] = result.content
    assert text =~ "Successfully overwrote"
    assert File.read!(file_path) == "New content"
  end

  test "replaces specific content", %{tmp_dir: tmp_dir, file_path: file_path} do
    File.write!(file_path, "Hello World")
    params = %{
      "path" => "test.txt",
      "content" => "Elixir",
      "old_content" => "World"
    }
    opts = [cwd: tmp_dir]

    assert {:ok, result} = Edit.execute("1", params, opts)
    assert [%{text: text}] = result.content
    assert text =~ "Successfully replaced content"
    assert File.read!(file_path) == "Hello Elixir"
  end

  test "fails if old_content is not found", %{tmp_dir: tmp_dir} do
    params = %{
      "path" => "test.txt",
      "content" => "New",
      "old_content" => "Missing"
    }
    opts = [cwd: tmp_dir]

    assert {:error, reason} = Edit.execute("1", params, opts)
    assert reason =~ "not found"
  end

  test "fails if old_content matches multiple locations", %{tmp_dir: tmp_dir, file_path: file_path} do
    File.write!(file_path, "A B A")
    params = %{
      "path" => "test.txt",
      "content" => "C",
      "old_content" => "A"
    }
    opts = [cwd: tmp_dir]

    assert {:error, reason} = Edit.execute("1", params, opts)
    assert reason =~ "matches 2 locations"
  end

  test "fails for path outside cwd", %{tmp_dir: tmp_dir} do
    params = %{"path" => "/etc/passwd", "content" => "Evil"}
    opts = [cwd: tmp_dir]

    assert {:error, reason} = Edit.execute("1", params, opts)
    assert reason =~ "outside of the current working directory"
  end
end
