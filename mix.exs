defmodule Sigma.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.1",
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
      setup: ["deps.get", "deps.patch", "assets.setup", "assets.build"],
      "sigma.run": ["phx.server"],
      "assets.setup": [
        "deps.patch",
        "npm.install",
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
end
