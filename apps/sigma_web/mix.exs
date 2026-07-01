defmodule Sigma.Web.MixProject do
  use Mix.Project

  def project do
    [
      app: :sigma_web,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  def application do
    [
      mod: {Sigma.Web.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:jason, "~> 1.4"},
      {:plug_cowboy, "~> 2.7"},
      {:gettext, "~> 1.0"},
      # TODO(upstream): duskmoon-dev/phoenix-duskmoon-ui#53
      # TODO(upstream): duskmoon-dev/phoenix-duskmoon-ui#54
      {:duskmoon_bundler, "~> 9.5"},
      {:phoenix_duskmoon, "~> 9.0"},
      {:sigma_agent, in_umbrella: true},
      {:sigma_session, in_umbrella: true},
      {:sigma_logs, in_umbrella: true},
      {:sigma_tools, in_umbrella: true},
      {:floki, ">= 0.30.0"},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end
end
