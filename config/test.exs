import Config

config :sigma_web, Sigma.Web.Endpoint,
  http: [port: 4002],
  server: false

config :logger, level: :warning

# Hosts without util-linux setsid (macOS) run hooks through the packaged helper;
# isolated sigma_coding tests cannot resolve it from :sigma_agent's priv dir.
packaged_setsid = Path.expand("../apps/sigma_agent/priv/native/sigma-setsid", __DIR__)

if File.regular?(packaged_setsid) do
  config :sigma_coding, setsid_path: packaged_setsid
end

config :phoenix_live_view, :test_warnings, missing_form_id: :raise

config :sigma_web,
  test_provider_config: %{
    "id" => "test",
    "name" => "Test",
    "api_type" => "mock",
    "model" => "mock-model",
    "resolved_key" => "",
    "base_url" => ""
  },
  mock_provider_module: Sigma.Web.MockProvider
