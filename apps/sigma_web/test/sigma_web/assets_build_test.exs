defmodule Sigma.Web.AssetsBuildTest do
  use ExUnit.Case, async: false

  @repo_root Path.expand("../../../../", __DIR__)

  test "assets build keeps DuskMoon utilities and xterm terminal CSS in app.css" do
    temp_outdir = Path.join(@repo_root, "_build/test_assets_build")
    File.rm_rf!(temp_outdir)

    # Reenable task in case it was already run in this VM instance
    Mix.Task.reenable("duskmoon_bundler.build")

    # Run the duskmoon_bundler.build Mix task directly in-process
    Mix.Task.run("duskmoon_bundler.build", ["--tailwind", "--outdir", temp_outdir])

    css_files = Path.wildcard(Path.join(temp_outdir, "css/app*.css"))
    assert length(css_files) > 0, "No CSS files found in #{temp_outdir}/css/"
    css = File.read!(List.first(css_files))
    assert css =~ ".bg-surface"
    assert css =~ ".appbar"
    assert css =~ ".xterm"
  end

  test "web shell terminal preserves raw pty line endings" do
    app_js = File.read!(Path.join(@repo_root, "apps/sigma_web/assets/js/app.js"))

    assert app_js =~ "convertEol: false"
  end
end
