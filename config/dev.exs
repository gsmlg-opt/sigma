import Config

config :ex_pi_web, PiWeb.Endpoint,
  http: [port: 4580],
  debug_errors: true,
  code_reloader: true,
  check_origin: false,
  watchers: [
    volt:
      {Mix.Tasks.Volt.Dev, :run,
       [
         ~w(--tailwind --tailwind-outdir) ++
           [Path.expand("../apps/ex_pi_web/priv/static/assets/css", __DIR__)]
       ]}
  ]

config :volt, :server,
  prefix: "/assets",
  watch_dirs: [Path.expand("../apps/ex_pi_web/lib/", __DIR__)]

config :volt, sourcemap: :linked
