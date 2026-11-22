defmodule Sigma.Session.MetricsPrivacyTest do
  use ExUnit.Case, async: true

  alias Sigma.Session.EntryEncoder

  test "journal request metrics exclude credentials, headers, and raw payloads" do
    secret = "sk-journal-secret"

    attrs = %{
      request_id: "request-1",
      revision: 1,
      status: :completed,
      input_tokens_total: 12,
      headers: %{"authorization" => "Bearer #{secret}"},
      api_key: secret,
      raw_payload: %{"messages" => [secret]},
      provenance: %{
        source: :provider,
        input_tokens: :prompt_tokens,
        headers: %{"x-api-key" => secret},
        adapter: secret
      }
    }

    assert {:ok, entry} =
             EntryEncoder.encode({:metrics, :request_finished, attrs}, "leaf-1", true)

    assert entry["data"]["provenance"] == %{
             "source" => "provider",
             "input_tokens" => "prompt_tokens"
           }

    refute Map.has_key?(entry["data"], "headers")
    refute Map.has_key?(entry["data"], "api_key")
    refute Map.has_key?(entry["data"], "raw_payload")

    json = Formata.JSON.encode!(entry)
    refute json =~ secret
    refute json =~ "authorization"
    refute json =~ "raw_payload"
  end
end
