defmodule Sigma.Session.MixProject do
  use Mix.Project

  def project do
    [
      app: :sigma_session,
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
      {:sigma_ai, in_umbrella: true},
      {:sigma_protocol, in_umbrella: true},
      {:sigma_agent, in_umbrella: true, only: :test},
      {:backplane_skill_protocol, "~> 1.10.94"},
      {:formata, "~> 0.3.5"},
      {:telemetry, "~> 1.0"}
    ]
  end
end
