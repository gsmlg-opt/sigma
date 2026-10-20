import Config

config :sigma_web, Sigma.Web.Endpoint,
  http: [port: 4002],
  server: false

config :logger, level: :warning

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
