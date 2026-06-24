defmodule Sigma.Tools.HashlineEditTest do
  use ExUnit.Case, async: true

  @tag :tmp_dir
  test "read records a hashline tag that edit uses to replace a line", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "a.txt"), "one\ntwo\nthree\n")
    store = Sigma.Tools.Store.new()

    assert {:ok, read_result} =
             Sigma.Tools.Read.execute("read", %{"path" => "a.txt"}, cwd: tmp_dir, tool_state: store)

    [%{text: read_text}] = read_result.content
    assert ["[a.txt#" <> tag_and_suffix | _] = String.split(read_text, "\n")
    assert <<tag::binary-size(4), "]">> = tag_and_suffix
    assert read_text =~ "2:two"

    input = "[a.txt##{tag}]\nreplace 2..2:\n+TWO"

    assert {:ok, edit_result} =
             Sigma.Tools.Edit.execute("edit", %{"input" => input}, cwd: tmp_dir, tool_state: store)

    assert File.read!(Path.join(tmp_dir, "a.txt")) == "one\nTWO\nthree\n"
    [%{text: edit_text}] = edit_result.content
    assert edit_text =~ ~r/^\[a\.txt#[0-9A-F]{4}\]/m
    assert edit_text =~ "-two"
    assert edit_text =~ "+TWO"
  end

  @tag :tmp_dir
  test "edit rejects a stale tag without modifying the file", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "a.txt")
    File.write!(path, "one\ntwo\n")
    store = Sigma.Tools.Store.new()

    assert {:ok, read_result} =
             Sigma.Tools.Read.execute("read", %{"path" => "a.txt"}, cwd: tmp_dir, tool_state: store)

    [%{text: read_text}] = read_result.content
    ["[a.txt#" <> tag_and_suffix | _] = String.split(read_text, "\n")
    <<tag::binary-size(4), "]">> = tag_and_suffix

    File.write!(path, "one\ndrifted\n")

    assert {:error, reason} =
             Sigma.Tools.Edit.execute(
               "edit",
               %{"input" => "[a.txt##{tag}]\nreplace 2..2:\n+TWO"},
               cwd: tmp_dir,
               tool_state: store
             )

    assert reason =~ "file changed between read and edit"
    assert File.read!(path) == "one\ndrifted\n"
  end

  @tag :tmp_dir
  test "edit is input only and rejects legacy content replacement params", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "a.txt"), "one\n")

    assert {:error, reason} =
             Sigma.Tools.Edit.execute(
               "edit",
               %{"path" => "a.txt", "old_content" => "one", "content" => "two"},
               cwd: tmp_dir,
               tool_state: Sigma.Tools.Store.new()
             )

    assert reason =~ "requires an input hashline patch"
    assert File.read!(Path.join(tmp_dir, "a.txt")) == "one\n"
  end
end
