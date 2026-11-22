defmodule Sigma.Agent.MixProject do
  use Mix.Project

  def project do
    [
      app: :sigma_agent,
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
      mod: {Sigma.Agent.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:backplane_agent_runtime, "~> 1.10.90"},
      {:sigma_protocol, in_umbrella: true},
      {:sigma_ai, in_umbrella: true},
      {:sigma_coding, in_umbrella: true},
      {:ex_image_info, "~> 1.0"},
      {:formata, "~> 0.3.5"}
    ]
  end
end
