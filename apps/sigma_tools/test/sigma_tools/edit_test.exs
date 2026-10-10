defmodule Sigma.Tools.EditTest do
  use ExUnit.Case, async: true

  alias Sigma.Tools.Edit

  @tag :tmp_dir
  test "edit applies a context patch without a prior read or snapshot", %{tmp_dir: cwd} do
    path = Path.join(cwd, "a.txt")
    File.write!(path, "one\ntwo\nthree\n")

    input = """
    *** Begin Patch
    *** Update File: a.txt
    @@
     one
    -two
    +TWO
     three
    *** End Patch
    """

    assert {:ok, %{content: [%{text: text}], details: %{files: [file]}}} =
             Edit.execute("edit", %{"input" => input}, cwd: cwd)

    assert File.read!(path) == "one\nTWO\nthree\n"
    assert %{path: ^path, action: :updated} = file
    assert text =~ "M a.txt"
  end

  @tag :tmp_dir
  test "edit adds, moves with edits, and deletes files in one patch", %{tmp_dir: cwd} do
    File.write!(Path.join(cwd, "old.txt"), "old\n")
    File.write!(Path.join(cwd, "deleted.txt"), "delete me\n")

    input = """
    *** Begin Patch
    *** Add File: nested/new.txt
    +created
    *** Update File: old.txt
    *** Move to: nested/renamed.txt
    @@
    -old
    +new
    *** Delete File: deleted.txt
    *** End Patch
    """

    assert {:ok, %{content: [%{text: text}], details: %{files: files}}} =
             Edit.execute("edit", %{"input" => input}, cwd: cwd)

    assert [%{action: :added}, %{action: :moved}, %{action: :deleted}] = files
    assert File.read!(Path.join(cwd, "nested/new.txt")) == "created\n"
    assert File.read!(Path.join(cwd, "nested/renamed.txt")) == "new\n"
    refute File.exists?(Path.join(cwd, "old.txt"))
    refute File.exists?(Path.join(cwd, "deleted.txt"))
    assert text =~ "R old.txt -> nested/renamed.txt"
  end

  @tag :tmp_dir
  test "edit matches ordered anchored hunks and the end of file", %{tmp_dir: cwd} do
    path = Path.join(cwd, "a.txt")
    File.write!(path, "section one\nold\nsection two\nold\ntail\n")

    input = """
    *** Begin Patch
    *** Update File: a.txt
    @@ section one
    -old
    +first
    +inserted
    @@ section two
    -old
    +second
     tail
    *** End of File
    *** End Patch
    """

    assert {:ok, _} = Edit.execute("edit", %{"input" => input}, cwd: cwd)
    assert File.read!(path) == "section one\nfirst\ninserted\nsection two\nsecond\ntail\n"
  end

  @tag :tmp_dir
  test "a context mismatch leaves the file untouched", %{tmp_dir: cwd} do
    path = Path.join(cwd, "a.txt")
    File.write!(path, "changed elsewhere\n")
    input = "*** Begin Patch\n*** Update File: a.txt\n@@\n-old\n+new\n*** End Patch\n"

    assert {:error, %Sigma.Coding.ToolError{kind: :resource_conflict, message: message}} =
             Edit.execute("edit", %{"input" => input}, cwd: cwd)

    assert message =~ "context did not match"
    assert File.read!(path) == "changed elsewhere\n"
  end

  @tag :tmp_dir
  test "malformed patches are rejected before any file changes", %{tmp_dir: cwd} do
    input = """
    *** Begin Patch
    *** Add File: new.txt
    +created
    *** Update File: a.txt
    @@
    invalid body
    *** End Patch
    """

    assert {:error, %Sigma.Coding.ToolError{kind: :validation}} =
             Edit.execute("edit", %{"input" => input}, cwd: cwd)

    refute File.exists?(Path.join(cwd, "new.txt"))
  end

  @tag :tmp_dir
  test "later failures report changes already applied", %{tmp_dir: cwd} do
    path = Path.join(cwd, "new.txt")

    input = """
    *** Begin Patch
    *** Add File: new.txt
    +created
    *** Update File: missing.txt
    @@
    -old
    +new
    *** End Patch
    """

    assert {:error,
            %Sigma.Coding.ToolError{
              kind: :resource_conflict,
              message: message,
              details: %{files: [%{path: ^path, action: :added}]}
            }} = Edit.execute("edit", %{"input" => input}, cwd: cwd)

    assert message =~ "Already applied changes:\nA new.txt"
    assert File.read!(path) == "created\n"
  end

  @tag :tmp_dir
  test "failed writes retain uncertain file evidence in the error", %{tmp_dir: cwd} do
    path = Path.join(cwd, "directory")
    File.mkdir_p!(path)
    input = "*** Begin Patch\n*** Add File: directory\n+new\n*** End Patch\n"

    assert {:error,
            %Sigma.Coding.ToolError{
              kind: :unknown_outcome,
              message: message,
              details: %{uncertain_files: [^path]}
            }} = Edit.execute("edit", %{"input" => input}, cwd: cwd)

    assert message =~ "Files with uncertain contents:\ndirectory"
  end

  @tag :tmp_dir
  test "patches cannot modify paths outside the workspace or through symlinks", %{
    tmp_dir: tmp_dir
  } do
    cwd = Path.join(tmp_dir, "workspace")
    outside = Path.join(tmp_dir, "outside")
    File.mkdir_p!(cwd)
    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(cwd, "link"))

    for path <- ["../outside/escape.txt", Path.join(outside, "escape.txt"), "link/escape.txt"] do
      input = "*** Begin Patch\n*** Add File: #{path}\n+escape\n*** End Patch\n"

      assert {:error, %Sigma.Coding.ToolError{kind: :forbidden}} =
               Edit.execute("edit", %{"input" => input}, cwd: cwd)
    end

    File.write!(Path.join(cwd, "a.txt"), "old\n")

    input =
      "*** Begin Patch\n*** Update File: a.txt\n*** Move to: link/escape.txt\n@@\n-old\n+new\n*** End Patch\n"

    assert {:error, %Sigma.Coding.ToolError{kind: :forbidden}} =
             Edit.execute("edit", %{"input" => input}, cwd: cwd)

    assert File.read!(Path.join(cwd, "a.txt")) == "old\n"
    assert [] = File.ls!(outside)
  end

  @tag :tmp_dir
  test "edit rejects legacy input and requires a patch string", %{tmp_dir: cwd} do
    for params <- [
          %{"path" => "a.txt", "content" => "new"},
          %{"input" => "[a.txt#FFFF]\nreplace 1..1:\n+new"}
        ] do
      assert {:error, %Sigma.Coding.ToolError{kind: :validation}} =
               Edit.execute("edit", params, cwd: cwd)
    end
  end

  @tag :tmp_dir
  test "patch file operations are included in scheduling resource keys", %{tmp_dir: cwd} do
    input = """
    *** Begin Patch
    *** Add File: new.txt
    +new
    *** Update File: old.txt
    *** Move to: renamed.txt
    @@
    -old
    +new
    *** Delete File: deleted.txt
    *** End Patch
    """

    metadata = Sigma.Coding.Tool.metadata(Edit, %{arguments: %{"input" => input}}, cwd: cwd)

    assert metadata.effect == :write
    assert metadata.concurrency == :sequential

    assert metadata.resource_keys ==
             Enum.map(
               ["new.txt", "old.txt", "renamed.txt", "deleted.txt"],
               &("path:" <> Path.join(cwd, &1))
             )
  end
end
