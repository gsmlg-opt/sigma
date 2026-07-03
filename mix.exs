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
  defp deps, do: []

  defp aliases do
    [
      setup: ["deps.get", "deps.patch", "assets.setup", "assets.build"],
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
end
