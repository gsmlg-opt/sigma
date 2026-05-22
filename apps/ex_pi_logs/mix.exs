defmodule PiLogs.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_pi_logs,
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
      mod: {PiLogs.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:telemetry, "~> 1.0"},
      {:phoenix_pubsub, "~> 2.1"}
    ]
  end
end
