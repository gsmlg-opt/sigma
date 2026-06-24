defmodule Sigma.Session.ContextFilesTest do
  use ExUnit.Case, async: true

  alias Sigma.Session.ContextFiles

  @moduletag :tmp_dir

  # All tests use `stop_at: tmp_dir` so the walk is bounded to the per-test
  # temp directory and is not affected by AGENTS.md files in the test
  # process's actual working directory.

  describe "walk_files/2" do
    test "returns empty list when no context files exist under stop_at", %{tmp_dir: tmp_dir} do
      cwd = Path.join(tmp_dir, "project")
      File.mkdir_p!(cwd)

      assert ContextFiles.walk_files(cwd, stop_at: tmp_dir) == []
    end

    test "picks AGENTS.md when present", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "AGENTS.md"), "agent rules")

      assert [path] = ContextFiles.walk_files(tmp_dir, stop_at: tmp_dir)
      assert path == Path.join(tmp_dir, "AGENTS.md")
    end

    test "falls back to CLAUDE.md when AGENTS.md absent", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "CLAUDE.md"), "claude rules")

      assert [path] = ContextFiles.walk_files(tmp_dir, stop_at: tmp_dir)
      assert path == Path.join(tmp_dir, "CLAUDE.md")
    end

    test "prefers AGENTS.md when both exist in same directory", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "AGENTS.md"), "agents")
      File.write!(Path.join(tmp_dir, "CLAUDE.md"), "claude")

      assert [path] = ContextFiles.walk_files(tmp_dir, stop_at: tmp_dir)
      assert path == Path.join(tmp_dir, "AGENTS.md")
    end

    test "walks ancestors in oldest-first order", %{tmp_dir: tmp_dir} do
      parent = Path.join(tmp_dir, "parent")
      child = Path.join(parent, "child")
      File.mkdir_p!(child)
      File.write!(Path.join(parent, "AGENTS.md"), "parent rules")
      File.write!(Path.join(child, "AGENTS.md"), "child rules")

      assert [first, second] = ContextFiles.walk_files(child, stop_at: tmp_dir)
      assert first == Path.join(parent, "AGENTS.md")
      assert second == Path.join(child, "AGENTS.md")
    end
  end

  describe "assemble/3" do
    test "returns just the global prompt when no context files exist", %{tmp_dir: tmp_dir} do
      cwd = Path.join(tmp_dir, "project")
      File.mkdir_p!(cwd)

      assert ContextFiles.assemble("you are helpful", cwd, stop_at: tmp_dir) ==
               "you are helpful"
    end

    test "returns empty string when global is nil and no files exist", %{tmp_dir: tmp_dir} do
      cwd = Path.join(tmp_dir, "project")
      File.mkdir_p!(cwd)

      assert ContextFiles.assemble(nil, cwd, stop_at: tmp_dir) == ""
    end

    test "concatenates global then context files, each with a header", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "AGENTS.md"), "project rules")

      result = ContextFiles.assemble("global rules", tmp_dir, stop_at: tmp_dir)
      header = "# Context: #{Path.join(tmp_dir, "AGENTS.md")}"
      expected = "global rules\n\n#{header}\n\nproject rules"

      assert result == expected
    end

    test "treats empty global prompt the same as nil", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "AGENTS.md"), "only this")

      result = ContextFiles.assemble("", tmp_dir, stop_at: tmp_dir)
      header = "# Context: #{Path.join(tmp_dir, "AGENTS.md")}"

      assert result == "#{header}\n\nonly this"
    end
  end
end
