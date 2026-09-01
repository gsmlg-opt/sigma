defmodule Sigma.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.5",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      releases: [sigma: [applications: [sigma_web: :permanent]]],
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  #
  # Run "mix help deps" for examples and options.
  defp deps, do: []

  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "sigma.run": ["phx.server"],
      "sigma.rel-build": ["assets.build", &build_release/1],
      "sigma.rel-run": ["sigma.rel-build", &run_release/1],
      "assets.setup": [
        "npm.install",
        "duskmoon.bundle"
      ],
      # TODO(upstream): duskmoon-dev/phoenix-duskmoon-ui#48
      "assets.build": ["duskmoon.bundle", "duskmoon_bundler.build --tailwind"],
      "assets.deploy": [
        "duskmoon.bundle",
        "duskmoon_bundler.build --tailwind",
        "phx.digest"
      ]
    ]
  end

  defp build_release([]) do
    mix = System.find_executable("mix") || Mix.raise("mix executable not found")
    release_build_path = Path.join(Mix.Project.build_path(), "sigma_rel")

    env = [
      {"MIX_ENV", Atom.to_string(Mix.env())},
      {"MIX_BUILD_PATH", release_build_path},
      {"SIGMA_RELEASE", "true"}
    ]

    case Mix.shell().cmd({mix, ["release", "sigma", "--overwrite", "--force"]},
           env: env,
           use_stdio: true
         ) do
      0 -> :ok
      status -> Mix.raise("Failed to build Sigma release (status #{status})")
    end
  end

  defp build_release(_args) do
    Mix.raise("mix sigma.rel-build does not accept arguments")
  end

  defp run_release([]) do
    release_build_path = Path.join(Mix.Project.build_path(), "sigma_rel")

    executable = Path.join([release_build_path, "rel", "sigma", "bin", "sigma"])

    case Mix.shell().cmd({executable, ["start"]}, use_stdio: true) do
      0 -> :ok
      status -> Mix.raise("Sigma release exited with status #{status}")
    end
  end

  defp run_release(_args) do
    Mix.raise("mix sigma.rel-run does not accept arguments")
  end
end
