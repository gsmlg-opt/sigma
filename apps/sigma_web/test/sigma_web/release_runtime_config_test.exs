defmodule Sigma.Web.ReleaseRuntimeConfigTest do
  use ExUnit.Case, async: false

  @config_dir Path.expand("../../../../config", __DIR__)

  setup do
    previous = Map.new(["RELEASE_NAME", "SECRET_KEY_BASE"], &{&1, System.get_env(&1)})
    System.delete_env("RELEASE_NAME")
    System.put_env("SECRET_KEY_BASE", String.duplicate("s", 64))

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  for environment <- [:dev, :prod] do
    test "#{environment} release uses an application-relative asset directory" do
      System.put_env("RELEASE_NAME", "sigma")
      runtime = read_config("runtime.exs", unquote(environment))
      overrides = Keyword.fetch!(runtime, :duskmoon_bundler_runtime)
      assert overrides[:outdir] == "priv/static/assets"
    end

    test "#{environment} source build retains its build output directory" do
      runtime = read_config("runtime.exs", unquote(environment))
      refute Keyword.has_key?(runtime, :duskmoon_bundler_runtime)
      build = read_config("config.exs", unquote(environment))

      assert build[:duskmoon_bundler][:outdir] ==
               Path.join(Path.dirname(@config_dir), "apps/sigma_web/priv/static/assets")
    end
  end

  defp read_config(file, environment) do
    Config.Reader.read!(Path.join(@config_dir, file), env: environment, target: :host)
  end
end
