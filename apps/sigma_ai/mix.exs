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
      {:backplane_ai_protocol, "~> 1.10.68"},
      # TODO(upstream): gsmlg-dev/http_fetch#158 - provider streaming moves to
      # http_fetch once ExSSL streams stop ending in econnreset/losing data.
      {:req, "~> 0.7.5"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.0"}
    ]
  end
end
