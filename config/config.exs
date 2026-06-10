import Config

config :ex_pi_web, PiWeb.Endpoint,
  url: [host: "localhost"],
  secret_key_base: "uR8T8QyHkZfTjG+lS0fWf6eQ+V8S8QyHkZfTjG+lS0fWf6eQ+V8S8QyHkZfTjG+l",
  render_errors: [
    formats: [html: PiWeb.ErrorHTML, json: PiWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: PiWeb.PubSub,
  live_view: [signing_salt: "v8Lh+K6p"]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

config :volt,
  entry: Path.expand("../apps/ex_pi_web/assets/js/app.js", __DIR__),
  root: Path.expand("../apps/ex_pi_web/assets", __DIR__),
  outdir: Path.expand("../apps/ex_pi_web/priv/static/assets", __DIR__),
  resolve_dirs: [Path.expand("../deps", __DIR__), Path.expand("../node_modules", __DIR__)],
  target: :es2022,
  tailwind: [css: Path.expand("../apps/ex_pi_web/assets/css/app.css", __DIR__)]

config :ex_pi_logs, pubsub: PiWeb.PubSub

import_config "#{config_env()}.exs"
