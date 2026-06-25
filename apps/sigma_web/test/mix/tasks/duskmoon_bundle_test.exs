defmodule Mix.Tasks.DuskmoonBundleTest do
  use ExUnit.Case, async: false

  @repo_root Path.expand("../../../../..", __DIR__)
  @bundle_task_path Path.join(@repo_root, "apps/sigma_web/lib/mix/tasks/duskmoon.bundle.ex")

  test "uses sigma_web node_modules and build paths when run at the umbrella root" do
    source = File.read!(@bundle_task_path)

    assert source =~ ~S|String.ends_with?(cwd, "apps/sigma_web")|
    assert source =~ ~S|Path.join(cwd, "apps/sigma_web")|
    assert source =~ ~S|node_modules: Path.join(web_root, "node_modules")|
    assert source =~ ~S|tmp_dir: Path.join(web_root, "_build/duskmoon_bundle")|
    assert source =~ ~S|File.rm_rf(paths.tmp_dir)|
  end
end
