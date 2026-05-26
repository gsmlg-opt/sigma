defmodule PiSession.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_pi_session,
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
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ex_pi_agent, in_umbrella: true},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"}
    ]
  end
end
