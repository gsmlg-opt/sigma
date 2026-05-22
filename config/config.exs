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

config :bun,
  version: "1.3.4",
  ex_pi_web: [
    args:
      ~w(build assets/js/app.js --outdir=priv/static/assets --external /fonts/* --external /images/*),
    cd: Path.expand("../apps/ex_pi_web", __DIR__)
  ]

config :tailwind,
  version: "4.1.11",
  ex_pi_web: [
    args: ~w(--input=assets/css/app.css --output=priv/static/assets/app.css),
    cd: Path.expand("../apps/ex_pi_web", __DIR__)
  ]

config :ex_pi_logs, pubsub: PiWeb.PubSub

import_config "#{config_env()}.exs"
