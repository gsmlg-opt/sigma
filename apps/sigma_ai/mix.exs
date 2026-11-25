defmodule Sigma.Ai.MixProject do
  use Mix.Project

  def project do
    [
      app: :sigma_ai,
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
      mod: {Sigma.Ai.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:backplane_ai_protocol, "~> 1.10.98"},
      {:http_fetch, "~> 1.0.0-rc.12"},
      {:formata, "~> 0.3.5"},
      {:telemetry, "~> 1.0"}
    ]
  end
end
