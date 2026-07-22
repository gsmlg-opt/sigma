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

  test "materializes rich elements and their transitive dependencies before invoking bun" do
    source = File.read!(@bundle_task_path)

    assert source =~ "WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#102"
    assert source =~ ~S|materialize_package!(Path.join(node_modules_path, "@duskmoon-dev/#{el}"))|
    assert source =~ "ensure_rich_bundle_dependencies!(node_modules_path)"
    assert source =~ "NPM.Registry.get_packument(name)"
    assert source =~ "NPM.Cache.ensure(name, version, info.dist.tarball, info.dist.integrity)"
    assert source =~ "System.cmd(bun, args, cd: Path.dirname(node_modules_path)"
  end
end
