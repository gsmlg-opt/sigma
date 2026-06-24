defmodule Sigma.Web.AssetsBuildTest do
  use ExUnit.Case, async: false

  @repo_root Path.expand("../../../../", __DIR__)

  test "assets build keeps DuskMoon utilities and xterm terminal CSS in app.css" do
    temp_outdir = Path.join(@repo_root, "_build/test_assets_build")
    File.rm_rf!(temp_outdir)

    # Reenable task in case it was already run in this VM instance
    Mix.Task.reenable("volt.build")

    # Run the volt.build Mix task directly in-process
    Mix.Task.run("volt.build", ["--tailwind", "--outdir", temp_outdir])

    css_files = Path.wildcard(Path.join(temp_outdir, "css/app*.css"))
    assert length(css_files) > 0, "No CSS files found in #{temp_outdir}/css/"
    css = File.read!(List.first(css_files))
    assert css =~ ".bg-surface"
    assert css =~ ".appbar"
    assert css =~ ".xterm"
  end
end
