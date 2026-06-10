defmodule PiWeb.AssetsBuildTest do
  use ExUnit.Case, async: false

  @repo_root Path.expand("../../../../", __DIR__)
  @css_path Path.join(@repo_root, "apps/ex_pi_web/priv/static/assets/app.css")

  test "assets build keeps DuskMoon utilities and xterm terminal CSS in app.css" do
    {output, status} =
      System.cmd("mix", ["assets.build"],
        cd: @repo_root,
        env: [{"MIX_ENV", "dev"}],
        stderr_to_stdout: true
      )

    assert status == 0, output

    css = File.read!(@css_path)
    assert css =~ ".bg-surface"
    assert css =~ ".appbar"
    assert css =~ ".xterm"
  end
end
