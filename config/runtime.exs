import Config

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by running: mix phx.gen.secret
      """

  config :ex_pi_web, PiWeb.Endpoint,
    http: [
      port: String.to_integer(System.get_env("PORT") || "4580"),
      transport_options: [socket_opts: [:inet6]]
    ],
    secret_key_base: secret_key_base
end

if System.get_env("MIX_BUN_PATH") do
  config :bun, path: System.get_env("MIX_BUN_PATH")
end

if System.get_env("MIX_TAILWIND_PATH") do
  config :tailwind, path: System.get_env("MIX_TAILWIND_PATH")
end
