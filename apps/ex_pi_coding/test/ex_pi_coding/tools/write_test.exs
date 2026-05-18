defmodule ExPiCoding.Tools.WriteTest do
  use ExUnit.Case, async: true
  alias ExPiCoding.Tools.Write

  @cwd File.cwd!()

  setup do
    tmp_dir = Path.join(@cwd, "tmp/test_write_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  test "creates a new file", %{tmp_dir: tmp_dir} do
    params = %{"path" => "new_file.txt", "content" => "Hello!"}

    assert {:ok, result} = Write.execute("1", params, cwd: tmp_dir)
    assert [%{text: text}] = result.content
    assert text =~ "Created"
    assert File.read!(Path.join(tmp_dir, "new_file.txt")) == "Hello!"
  end

  test "creates parent directories", %{tmp_dir: tmp_dir} do
    params = %{"path" => "a/b/c.txt", "content" => "nested"}

    assert {:ok, _} = Write.execute("1", params, cwd: tmp_dir)
    assert File.read!(Path.join(tmp_dir, "a/b/c.txt")) == "nested"
  end

  test "fails if file already exists", %{tmp_dir: tmp_dir} do
    file = Path.join(tmp_dir, "existing.txt")
    File.write!(file, "original")

    params = %{"path" => "existing.txt", "content" => "overwrite attempt"}

    assert {:error, reason} = Write.execute("1", params, cwd: tmp_dir)
    assert reason =~ "already exists"
    assert File.read!(file) == "original"
  end

  test "rejects paths outside cwd", %{tmp_dir: tmp_dir} do
    params = %{"path" => "../../etc/passwd", "content" => "evil"}

    assert {:error, _} = Write.execute("1", params, cwd: tmp_dir)
  end
end
