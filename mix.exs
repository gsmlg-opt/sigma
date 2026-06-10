defmodule Pi.MixProject do
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
    []
  end

  defp aliases do
    [
      setup: ["deps.get", "deps.patch", "assets.setup", "assets.build"],
      "assets.setup": [
        "deps.patch",
        "cmd --app ex_pi_web mix npm.install",
        "duskmoon.bundle"
      ],
      "assets.build": ["volt.build --tailwind"],
      "assets.deploy": [
        "deps.patch",
        "duskmoon.bundle",
        "volt.build --tailwind",
        "phx.digest"
      ]
    ]
  end
end
