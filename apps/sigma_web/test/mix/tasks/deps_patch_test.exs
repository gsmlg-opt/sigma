defmodule Mix.Tasks.DepsPatchTest do
  use ExUnit.Case, async: false

  @repo_root Path.expand("../../../../..", __DIR__)
  @resolver_path Path.join(@repo_root, "deps/npm/lib/npm/resolver.ex")
  @registry_path Path.join(@repo_root, "deps/npm/lib/npm/registry.ex")
  @tarball_path Path.join(@repo_root, "deps/npm/lib/npm/tarball.ex")
  @proxy_path Path.join(@repo_root, "deps/npm/lib/npm/proxy.ex")

  setup_all do
    Mix.Task.reenable("deps.patch")
    Mix.Task.run("deps.patch", [])
    :ok
  end

  test "npm resolver prefetch tasks do not exit the caller on timeout" do
    source = File.read!(@resolver_path)

    assert source =~ "on_timeout: :kill_task"

    matches =
      Regex.scan(
        ~r/Task\.async_stream\(&fetch_and_cache\/1,\s*max_concurrency: @prefetch_concurrency,\s*timeout: @fetch_timeout,\s*on_timeout: :kill_task/s,
        source
      )

    assert 2 = length(matches)
  end

  test "npm registry requests honor environment proxy settings" do
    source = File.read!(@registry_path)
    proxy_source = File.read!(@proxy_path)

    assert source =~ "connect_options: NPM.Proxy.connect_options(url)"
    assert proxy_source =~ "System.get_env(\"https_proxy\")"
    assert proxy_source =~ "defp proxy_scheme(\"http\"), do: :http"
    assert proxy_source =~ "defp proxy_scheme(\"https\"), do: :https"
  end

  test "npm tarball downloads honor environment proxy settings" do
    source = File.read!(@tarball_path)

    assert source =~ "connect_options: NPM.Proxy.connect_options(tarball_url)"
  end
end
