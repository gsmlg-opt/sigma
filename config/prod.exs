import Config

config :sigma_web, Sigma.Web.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  check_origin: false,
  code_reloader: false,
  watchers: []

config :logger, level: :info
