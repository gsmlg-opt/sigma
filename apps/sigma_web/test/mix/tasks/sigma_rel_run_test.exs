defmodule Mix.Tasks.SigmaRelRunTest do
  use ExUnit.Case, async: false

  @repo_root Path.expand("../../../../..", __DIR__)
  @mix_project_path Path.join(@repo_root, "mix.exs")
  @devenv_config_path Path.join(@repo_root, "devenv.nix")
  @dev_config_path Path.join(@repo_root, "config/dev.exs")
  @prod_config_path Path.join(@repo_root, "config/prod.exs")
  @runtime_config_path Path.join(@repo_root, "config/runtime.exs")

  test "builds and starts an overwrite release in the current Mix environment" do
    aliases = Sigma.MixProject.project()[:aliases]
    source = File.read!(@mix_project_path)

    assert ["assets.build", builder] = aliases[:"sigma.rel-build"]
    assert is_function(builder, 1)
    assert ["sigma.rel-build", runner] = aliases[:"sigma.rel-run"]
    assert is_function(runner, 1)
    assert source =~ ~S|release_build_path = Path.join(Mix.Project.build_path(), "sigma_rel")|
    assert source =~ ~S|{"MIX_ENV", Atom.to_string(Mix.env())}|
    assert source =~ ~S|{"MIX_BUILD_PATH", release_build_path}|
    assert source =~ ~S|{"SIGMA_RELEASE", "true"}|
    assert source =~ ~S|["release", "sigma", "--overwrite", "--force"]|
    assert source =~ ~S|Path.join([release_build_path, "rel", "sigma", "bin", "sigma"])|
    assert source =~ ~S|Mix.shell().cmd({executable, ["start"]}, use_stdio: true)|
    assert source =~ ~S|Mix.raise("Sigma release exited with status #{status}")|
  end

  test "devenv owns the release as its foreground process" do
    source = File.read!(@devenv_config_path)

    assert source =~ "mix sigma.rel-build"
    assert source =~ "exec _build/dev/sigma_rel/rel/sigma/bin/sigma start"
    refute source =~ ~S|exec = "mix sigma.rel-run"|
  end

  test "release runtime starts the endpoint without development watchers" do
    dev_source = File.read!(@dev_config_path)
    prod_source = File.read!(@prod_config_path)
    runtime_source = File.read!(@runtime_config_path)

    assert dev_source =~ ~S|if System.get_env("SIGMA_RELEASE") == "true" do|
    assert dev_source =~ "code_reloader: false"
    assert dev_source =~ "watchers: []"
    assert prod_source =~ "code_reloader: false"
    assert prod_source =~ "watchers: []"
    assert runtime_source =~ ~S|if System.get_env("RELEASE_NAME") do|

    assert runtime_source =~
             ~S|server: System.get_env("PHX_SERVER", "true") in ["1", "true", "TRUE"]|

    assert runtime_source =~ ~S'port: String.to_integer(System.get_env("PORT") || "4580")'
    refute runtime_source =~ "code_reloader: false"
    refute runtime_source =~ "watchers: []"
  end
end
