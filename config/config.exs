import Config

repo_root = Path.expand("..", __DIR__)

[version] =
  Regex.run(~r/^\s+version: "([^"]+)"/m, File.read!(Path.join(repo_root, "mix.exs")),
    capture: :all_but_first
  )

git_value = fn args ->
  if git = System.find_executable("git") do
    case System.cmd(git, args, cd: repo_root, stderr_to_stdout: true) do
      {value, 0} -> String.trim(value)
      _ -> nil
    end
  end
end

config :sigma_web, :build_info, %{
  version: version,
  environment: config_env(),
  git_ref: System.get_env("SIGMA_GIT_REF") || git_value.(["rev-parse", "--abbrev-ref", "HEAD"]),
  git_sha: System.get_env("SIGMA_GIT_SHA") || git_value.(["rev-parse", "HEAD"]),
  released_at: System.get_env("SIGMA_RELEASE_TIME")
}

config :sigma_web, Sigma.Web.Endpoint,
  url: [host: "localhost"],
  secret_key_base: "uR8T8QyHkZfTjG+lS0fWf6eQ+V8S8QyHkZfTjG+lS0fWf6eQ+V8S8QyHkZfTjG+l",
  render_errors: [
    formats: [html: Sigma.Web.ErrorHTML, json: Sigma.Web.ErrorJSON],
    layout: false
  ],
  pubsub_server: Sigma.Web.PubSub,
  live_view: [signing_salt: "v8Lh+K6p"]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

config :duskmoon_bundler,
  entry: Path.expand("../apps/sigma_web/assets/js/app.js", __DIR__),
  root: Path.expand("../apps/sigma_web/assets", __DIR__),
  outdir: Path.expand("../apps/sigma_web/priv/static/assets", __DIR__),
  resolve_dirs: [Path.expand("../deps", __DIR__), Path.expand("../node_modules", __DIR__)],
  target: :es2022,
  tailwind: [
    css: Path.expand("../apps/sigma_web/assets/css/app.css", __DIR__),
    sources: [
      %{base: Path.expand("../apps/sigma_web/lib", __DIR__), pattern: "**/*.{ex,heex}"},
      %{base: Path.expand("../apps/sigma_web/assets", __DIR__), pattern: "**/*.{js,ts,jsx,tsx}"},
      %{base: Path.expand("../deps/phoenix_duskmoon", __DIR__), pattern: "**/*.{ex,heex}"}
    ]
  ]

config :sigma_logs, pubsub: Sigma.Web.PubSub

config :sigma_web, session_terminals_enabled: true

import_config "#{config_env()}.exs"
