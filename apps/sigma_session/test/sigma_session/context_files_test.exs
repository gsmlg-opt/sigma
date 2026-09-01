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

  describe "discover/3" do
    test "expands imports deterministically and preserves source provenance", %{tmp_dir: tmp_dir} do
      child = Path.join(tmp_dir, "child")
      rules = Path.join(tmp_dir, "rules")
      File.mkdir_p!(child)
      File.mkdir_p!(rules)

      imported = Path.join(rules, "common.md")
      root_agents = Path.join(tmp_dir, "AGENTS.md")
      child_agents = Path.join(child, "AGENTS.md")
      File.write!(imported, "imported rules")

      File.write!(
        root_agents,
        "root rules\n<!-- sigma:import rules/common.md -->"
      )

      File.write!(child_agents, "child rules")

      result =
        ContextFiles.discover("global rules", child,
          stop_at: tmp_dir,
          target_path: Path.join(child, "lib/example.ex")
        )

      assert Enum.map(result.sections, & &1.source) == [
               "global_prompt",
               root_agents,
               imported,
               child_agents
             ]

      assert Enum.at(result.sections, 2).imported_from == root_agents
      assert Enum.at(result.sections, 2).depth == 1
      assert result.diagnostics == []

      assert result.content ==
               Enum.join(
                 [
                   "global rules",
                   "# Context: #{root_agents}\n\nroot rules",
                   "# Context: #{imported}\n\nimported rules",
                   "# Context: #{child_agents}\n\nchild rules"
                 ],
                 "\n\n"
               )
    end

    test "reports missing, disabled, cyclic, and depth-limited imports without blocking valid rules", %{
      tmp_dir: tmp_dir
    } do
      rules = Path.join(tmp_dir, "rules")
      nested = Path.join(rules, "nested")
      File.mkdir_p!(nested)

      root_agents = Path.join(tmp_dir, "AGENTS.md")
      disabled = Path.join(rules, "disabled.md")
      cycle = Path.join(rules, "cycle.md")
      deep = Path.join(rules, "deep.md")
      nested_deep = Path.join(nested, "deeper.md")

      File.write!(
        root_agents,
        """
        root rules
        <!-- sigma:import rules/missing.md -->
        <!-- sigma:import rules/disabled.md -->
        <!-- sigma:import rules/cycle.md -->
        <!-- sigma:import rules/deep.md -->
        """
      )

      File.write!(disabled, "<!-- sigma:disabled -->\nignored")
      File.write!(cycle, "cycle rules\n<!-- sigma:import cycle.md -->")
      File.write!(deep, "deep rules\n<!-- sigma:import nested/deeper.md -->")
      File.write!(nested_deep, "too deep")

      result =
        ContextFiles.discover(nil, tmp_dir,
          stop_at: tmp_dir,
          max_import_depth: 1
        )

      kinds = Enum.map(result.diagnostics, & &1.kind)
      assert :missing_import in kinds
      assert :disabled_source in kinds
      assert :cyclic_import in kinds
      assert :import_depth_exceeded in kinds
      assert result.content =~ "root rules"
      assert result.content =~ "cycle rules"
      assert result.content =~ "deep rules"
      refute result.content =~ "ignored"
      refute result.content =~ "too deep"
    end

    test "applies path scopes deterministically and sticky rules override a mismatch", %{
      tmp_dir: tmp_dir
    } do
      agents = Path.join(tmp_dir, "AGENTS.md")

      File.write!(
        agents,
        "<!-- sigma:paths lib/**/*.ex -->\nElixir-only rules"
      )

      matching =
        ContextFiles.preview(nil, tmp_dir,
          stop_at: tmp_dir,
          target_path: Path.join(tmp_dir, "lib/core/example.ex")
        )

      assert matching.content =~ "Elixir-only rules"
      assert [%{applied?: true, paths: ["lib/**/*.ex"]}] = matching.sections

      skipped =
        ContextFiles.preview(nil, tmp_dir,
          stop_at: tmp_dir,
          target_path: Path.join(tmp_dir, "docs/readme.md")
        )

      assert skipped.content == ""
      assert [%{applied?: false}] = skipped.sections
      assert [%{action: :skip, reason: :path_scope_mismatch}] = skipped.trace

      File.write!(
        agents,
        "<!-- sigma:paths lib/**/*.ex -->\n<!-- sigma:sticky -->\nSticky rules"
      )

      sticky =
        ContextFiles.preview(nil, tmp_dir,
          stop_at: tmp_dir,
          target_path: Path.join(tmp_dir, "docs/readme.md")
        )

      assert sticky.content =~ "Sticky rules"
      assert [%{applied?: true, sticky?: true}] = sticky.sections
    end

    test "bounds individual source reads and reports diagnostics", %{tmp_dir: tmp_dir} do
      agents = Path.join(tmp_dir, "AGENTS.md")
      File.write!(agents, String.duplicate("x", 128))

      result =
        ContextFiles.discover("global", tmp_dir,
          stop_at: tmp_dir,
          max_file_bytes: 64
        )

      assert result.content == "global"
      assert [%{kind: :source_too_large, source: ^agents}] = result.diagnostics
    end

    test "rejects an import whose symlink escapes the importing directory", %{tmp_dir: tmp_dir} do
      rules = Path.join(tmp_dir, "rules")
      outside = Path.join(Path.dirname(tmp_dir), "outside-#{System.unique_integer([:positive])}.md")
      File.mkdir_p!(rules)
      File.write!(outside, "secret outside rules")
      on_exit(fn -> File.rm(outside) end)

      File.ln_s!(outside, Path.join(rules, "escape.md"))
      File.write!(Path.join(tmp_dir, "AGENTS.md"), "safe rules\n<!-- sigma:import rules/escape.md -->")

      result = ContextFiles.discover(nil, tmp_dir, stop_at: tmp_dir)

      assert result.content =~ "safe rules"
      refute result.content =~ "secret outside rules"
      assert [%{kind: :import_outside_source}] = result.diagnostics
    end
  end
end
