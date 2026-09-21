import Config

if engine = System.get_env("SIGMA_AGENT_ENGINE") do
  execution_engine =
    case engine do
      "sigma" -> :sigma
      "backplane" -> :backplane
      _ -> raise "SIGMA_AGENT_ENGINE must be sigma or backplane"
    end

  config :sigma_agent, execution_engine: execution_engine
end

if value = System.get_env("SIGMA_SESSION_TERMINALS_ENABLED") do
  config :sigma_web,
    session_terminals_enabled: String.downcase(value) in ["1", "true", "yes", "on"]
end

if System.get_env("RELEASE_NAME") do
  config :sigma_web, Sigma.Web.Endpoint,
    server: System.get_env("PHX_SERVER", "true") in ["1", "true", "TRUE"],
    http: [
      port: String.to_integer(System.get_env("PORT") || "4580"),
      transport_options: [socket_opts: [:inet6]]
    ]
end

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
