defmodule PiCoding.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_pi_coding,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {PiCoding, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ex_pi_ai, in_umbrella: true},
      {:anubis_mcp, "~> 1.6"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"}
    ]
  end
end
