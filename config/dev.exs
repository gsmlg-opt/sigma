import Config

config :sigma_web, Sigma.Web.Endpoint,
  http: [port: 4580],
  debug_errors: true,
  code_reloader: true,
  check_origin: false,
  watchers: [
    duskmoon_bundler:
      {Mix.Tasks.DuskmoonBundler.Dev, :run,
       [
         ~w(--tailwind --tailwind-outdir) ++
           [Path.expand("../apps/sigma_web/priv/static/assets/css", __DIR__)]
       ]}
  ]

config :duskmoon_bundler, :server,
  prefix: "/assets",
  watch_dirs: [Path.expand("../apps/sigma_web/lib/", __DIR__)]

config :duskmoon_bundler, sourcemap: :linked
