import Config

config :ex_pi_web, PiWeb.Endpoint,
  http: [port: 4580],
  debug_errors: true,
  code_reloader: true,
  check_origin: false,
  watchers: [
    tailwind: {Tailwind, :install_and_run, [:ex_pi_web, ~w(--watch)]},
    bun: {Bun, :install_and_run, [:ex_pi_web, ~w(--sourcemap=inline --watch)]}
  ]
