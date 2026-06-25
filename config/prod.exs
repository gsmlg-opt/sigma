import Config

config :sigma_web, Sigma.Web.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  check_origin: false

config :logger, level: :info
