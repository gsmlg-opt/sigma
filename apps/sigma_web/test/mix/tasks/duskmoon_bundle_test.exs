defmodule Mix.Tasks.DuskmoonBundleTest do
  use ExUnit.Case, async: false

  @repo_root Path.expand("../../../../..", __DIR__)
  @bundle_task_path Path.join(@repo_root, "apps/sigma_web/lib/mix/tasks/duskmoon.bundle.ex")

  test "uses umbrella node_modules and build paths from either project directory" do
    source = File.read!(@bundle_task_path)

    assert source =~ ~S|String.ends_with?(cwd, "apps/sigma_web")|
    assert source =~ ~S|{Path.expand("../..", cwd), cwd}|
    assert source =~ ~S|Path.join(cwd, "apps/sigma_web")|
    assert source =~ ~S|node_modules: Path.join(repo_root, "node_modules")|
    assert source =~ ~S|tmp_dir: Path.join(repo_root, "_build/duskmoon_bundle")|
    assert source =~ ~S|File.rm_rf(paths.tmp_dir)|
  end

  @tag :assets
  test "rich elements resolve transitive dependencies from the installed npm tree" do
    tmp_dir =
      Path.join(@repo_root, "_build/test_rich_elements_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    entry = Path.join(tmp_dir, "entry.js")
    output_path = Path.join(tmp_dir, "bundle.js")

    File.write!(entry, """
    import '@duskmoon-dev/el-chat/register';
    import '@duskmoon-dev/el-markdown/register';
    import '@duskmoon-dev/el-markdown-input/register';
    """)

    {output, status} =
      System.cmd(
        "bun",
        [
          "build",
          entry,
          "--bundle",
          "--format=esm",
          "--target=browser",
          "--outfile=#{output_path}"
        ],
        cd: @repo_root,
        stderr_to_stdout: true
      )

    assert status == 0, output
    bundle = File.read!(output_path)
    assert byte_size(bundle) > 0
    refute bundle =~ ~r/from ["']@duskmoon-dev\//
  end

  @tag :assets
  test "generated element bundle is self-contained" do
    bundle = File.read!(Path.join(@repo_root, "apps/sigma_web/assets/js/duskmoon_elements.js"))

    refute bundle =~ ~r/from ["']@duskmoon-dev\//
  end
end
