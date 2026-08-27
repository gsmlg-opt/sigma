import Config

config :sigma_web, Sigma.Web.Endpoint,
  http: [port: 4580],
  debug_errors: true,
  check_origin: false

if System.get_env("SIGMA_RELEASE") == "true" do
  config :sigma_web, Sigma.Web.Endpoint,
    code_reloader: false,
    watchers: []
else
  config :sigma_web, Sigma.Web.Endpoint,
    code_reloader: true,
    watchers: [
      duskmoon_bundler:
        {Mix.Tasks.DuskmoonBundler.Dev, :run,
         [
           ~w(--tailwind --tailwind-outdir) ++
             [Path.expand("../apps/sigma_web/priv/static/assets/css", __DIR__)]
         ]}
    ]
end

config :duskmoon_bundler, :server,
  prefix: "/assets",
  watch_dirs: [Path.expand("../apps/sigma_web/lib/", __DIR__)]

config :duskmoon_bundler, sourcemap: :linked
