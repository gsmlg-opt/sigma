import Config

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by running: mix phx.gen.secret
      """

  config :sigma_web, Sigma.Web.Endpoint,
    server: System.get_env("PHX_SERVER", "true") in ["1", "true", "TRUE"],
    http: [
      port: String.to_integer(System.get_env("PORT") || "4580"),
      transport_options: [socket_opts: [:inet6]]
    ],
    secret_key_base: secret_key_base
end
