defmodule Mix.Tasks.DepsPatchTest do
  use ExUnit.Case, async: false

  @repo_root Path.expand("../../../../..", __DIR__)
  @npm_dep_path (if File.dir?(Path.join(@repo_root, "deps/duskmoon_npm")) do
                   Path.join(@repo_root, "deps/duskmoon_npm")
                 else
                   Path.join(@repo_root, "deps/npm")
                 end)
  @resolver_path Path.join(@npm_dep_path, "lib/npm/resolver.ex")
  @registry_path Path.join(@npm_dep_path, "lib/npm/registry.ex")
  @tarball_path Path.join(@npm_dep_path, "lib/npm/tarball.ex")
  @proxy_path Path.join(@npm_dep_path, "lib/npm/proxy.ex")

  setup_all do
    Mix.Task.reenable("deps.patch")
    Mix.Task.run("deps.patch", [])
    :ok
  end

  test "npm resolver prefetch tasks do not exit the caller on timeout" do
    source = File.read!(@resolver_path)

    assert source =~ "on_timeout: :kill_task"

    assert [_ | _] =
             Regex.scan(
               ~r/Task\.async_stream\(.+?timeout: .+?,.+?on_timeout: :kill_task/s,
               source
             )
  end

  test "npm registry requests honor environment proxy settings" do
    source = File.read!(@registry_path)
    proxy_source = File.read!(@proxy_path)

    assert source =~ "request_options(url)"
    assert source =~ "defp request_options(url)"
    assert source =~ "NPM.Proxy.with_connect_options(url)"
    assert proxy_source =~ "System.get_env(\"https_proxy\")"
    assert proxy_source =~ "def with_connect_options(options, url)"
    assert proxy_source =~ "Keyword.merge(connect_options, proxy_options)"
    assert proxy_source =~ "Keyword.update!(finch_options, :conn_opts"
    assert proxy_source =~ "defp proxy_scheme(\"http\"), do: :http"
    assert proxy_source =~ "defp proxy_scheme(\"https\"), do: :https"
  end

  test "npm tarball downloads honor environment proxy settings" do
    source = File.read!(@tarball_path)

    assert source =~ "request_options(tarball_url)"
    assert source =~ "defp request_options(tarball_url)"
    assert source =~ "NPM.Proxy.with_connect_options(tarball_url)"
  end

  @tag :tmp_dir
  test "dependency recompilation failures fail the patch task", %{tmp_dir: tmp_dir} do
    fake_mix = Path.join(tmp_dir, "mix")
    original_path = System.fetch_env!("PATH")
    original_proxy_source = File.read!(@proxy_path)

    on_exit(fn ->
      System.put_env("PATH", original_path)
      File.write!(@proxy_path, original_proxy_source)
    end)

    File.write!(fake_mix, "#!/bin/sh\nexit 17\n")
    File.chmod!(fake_mix, 0o755)
    File.write!(@proxy_path, "defmodule NPM.Proxy do\nend\n")
    System.put_env("PATH", tmp_dir <> ":" <> original_path)
    Mix.Task.reenable("deps.patch")

    assert_raise Mix.Error, ~r/duskmoon_npm.*status 17/, fn ->
      Mix.Task.run("deps.patch", [])
    end
  end
end
