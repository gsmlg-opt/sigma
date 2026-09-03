defmodule Sigma.Web.AssetsBuildTest do
  use ExUnit.Case, async: false

  @repo_root Path.expand("../../../../", __DIR__)

  # Requires node_modules / Bun from `mix assets.setup`. Excluded from the core
  # ExUnit job (see BuildContractTest); exercised by the CI assets job.
  @tag :assets
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

  test "auto appearance resolves the OS preference to an explicit theme" do
    app_js = File.read!(Path.join(@repo_root, "apps/sigma_web/assets/js/app.js"))

    assert app_js =~ ~s|return darkQuery.matches ? "moonlight" : "sunshine"|

    assert app_js =~
             ~r/!theme \|\| theme === "default"\s*\?\s*resolveAutoTheme\(\)\s*:\s*theme/

    assert app_js =~ ~s|document.documentElement.setAttribute("data-theme", resolved)|
    refute app_js =~ ~s|removeAttribute("data-theme")|
  end

  test "web shell terminal can shrink within its viewport panel" do
    css = File.read!(Path.join(@repo_root, "apps/sigma_web/assets/css/app.css"))

    assert css =~
             ~r/\.web-shell-terminal\s*\{[^}]*flex:\s*1 1 auto;[^}]*height:\s*auto;[^}]*min-height:\s*0;/s

    refute css =~ ~r/\.web-shell-terminal\s*\{[^}]*min-height:\s*16rem;/s
  end
end
