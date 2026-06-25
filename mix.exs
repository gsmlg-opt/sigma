defmodule Sigma.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  #
  # Run "mix help deps" for examples and options.
  defp deps do
    quickbeam_source_deps()
  end

  defp aliases do
    [
      setup: ["deps.get", "deps.patch", "quickbeam.compile", "assets.setup", "assets.build"],
      "quickbeam.compile": quickbeam_compile_alias(),
      "npm.install": ["cmd --app sigma_web mix npm.install"],
      "assets.setup": [
        "deps.patch",
        "cmd --app sigma_web mix npm.install",
        "duskmoon.bundle"
      ],
      # TODO(upstream): duskmoon-dev/phoenix-duskmoon-ui#48
      "assets.build": ["duskmoon.bundle", "duskmoon_bundler.build --tailwind"],
      "assets.deploy": [
        "deps.patch",
        "duskmoon.bundle",
        "duskmoon_bundler.build --tailwind",
        "phx.digest"
      ]
    ]
  end

  # QuickBEAM (pulled in via :duskmoon_bundler) ships precompiled NIFs only for
  # x86_64-linux-gnu, aarch64-linux-gnu, and aarch64-macos-none. On Intel macOS
  # there is no precompiled artifact, so the NIF must be built from source with
  # Zigler. Zigler 0.15.x requires Zig 0.15.2, which we invoke through mise
  # without disturbing the project's default Zig toolchain.
  defp quickbeam_source_deps do
    if quickbeam_source_build?() do
      [{:zigler, "~> 0.15.2", runtime: false}]
    else
      []
    end
  end

  defp quickbeam_compile_alias do
    if quickbeam_source_build?() do
      # Run at the umbrella root (not via `mix cmd`, which fans out per app).
      [
        &patch_quickbeam_targets/1,
        &compile_zigler_toolchain/1,
        &compile_quickbeam_from_source/1
      ]
    else
      []
    end
  end

  defp patch_quickbeam_targets(_args) do
    Code.eval_file("scripts/patch_quickbeam_targets.exs")
    :ok
  end

  defp compile_zigler_toolchain(_args) do
    run_with_zig("mix deps.compile protoss pegasus zig_get zig_parser zigler")
  end

  defp compile_quickbeam_from_source(_args) do
    run_with_zig("env QUICKBEAM_BUILD=1 mix deps.compile quickbeam --force")
  end

  defp run_with_zig(command) do
    args = ["exec", "zig@0.15.2", "--"] ++ String.split(command, " ")

    {_, status} =
      System.cmd("mise", args, into: IO.stream(:stdio, :line), stderr_to_stdout: true)

    if status != 0, do: Mix.raise("`mise #{Enum.join(args, " ")}` failed with status #{status}")
    :ok
  end

  defp quickbeam_source_build? do
    System.get_env("QUICKBEAM_SOURCE_BUILD") in ["1", "true"] or
      build_host() == {"x86_64", :darwin}
  end

  defp build_host do
    system = :erlang.system_info(:system_architecture) |> to_string()
    arch = system |> String.split("-") |> hd()

    os =
      cond do
        String.contains?(system, "linux") -> :linux
        String.contains?(system, "darwin") -> :darwin
        true -> :unknown
      end

    {arch, os}
  end
end
