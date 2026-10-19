defmodule Sigma.Ai.ModelDiscoveryTest do
  use ExUnit.Case, async: true

  alias Sigma.Ai.ModelDiscovery

  defmodule Adapter do
    def run(request), do: Process.get(:discovery_adapter).(request)
  end

  defp request_options(adapter) do
    Process.put(:discovery_adapter, adapter)
    [adapter: Adapter]
  end

  test "OpenAI discovery uses the saved connection and normalizes unique descriptors" do
    config = %{
      "api_type" => "openai-responses",
      "base_url" => "https://models.example/v1/",
      "resolved_key" => "test-key",
      "auth_type" => "custom_header",
      "auth_header_name" => "x-token"
    }

    adapter = fn request ->
      assert URI.to_string(request.url) == "https://models.example/v1/models"
      assert Req.Request.get_header(request, "x-token") == ["test-key"]
      assert Req.Request.get_header(request, "authorization") == []

      {request,
       Req.Response.new(
         status: 200,
         body: %{
           "data" => [
             %{"id" => " alpha ", "name" => "Alpha", "context_window" => 128_000},
             %{"id" => "alpha"},
             %{"id" => "beta"},
             %{"id" => ""},
             %{"bad" => true}
           ]
         }
       )}
    end

    assert {:ok, [alpha, %{"id" => "beta", "name" => "beta"}]} =
             ModelDiscovery.discover(config, request_options(adapter))

    assert alpha == %{"id" => "alpha", "name" => "Alpha", "contextWindow" => 128_000}
  end

  test "Anthropic discovery follows cursors without duplicating /v1" do
    config = %{
      "api_type" => "anthropic",
      "base_url" => "https://models.example/v1/",
      "resolved_key" => "secret"
    }

    adapter = fn request ->
      assert request.url.path == "/v1/models"
      assert Req.Request.get_header(request, "x-api-key") == ["secret"]
      assert Req.Request.get_header(request, "anthropic-version") == ["2023-06-01"]

      body =
        case URI.decode_query(request.url.query || "") do
          %{"after_id" => "a"} ->
            %{"data" => [%{"id" => "b", "display_name" => "Model B"}], "has_more" => false}

          _ ->
            %{"data" => [%{"id" => "a"}], "has_more" => true, "last_id" => "a"}
        end

      {request, Req.Response.new(status: 200, body: body)}
    end

    assert {:ok, [%{"id" => "a", "name" => "a"}, %{"id" => "b", "name" => "Model B"}]} =
             ModelDiscovery.discover(config, request_options(adapter))
  end

  test "keyless connections send no credential header and empty discovery succeeds" do
    adapter = fn request ->
      assert Req.Request.get_header(request, "authorization") == []
      assert Req.Request.get_header(request, "x-api-key") == []
      {request, Req.Response.new(status: 200, body: %{"data" => []})}
    end

    assert {:ok, []} = ModelDiscovery.discover(openai_config(), request_options(adapter))
  end

  test "does not expose credential-bearing error bodies or transport reasons" do
    for {status, error} <- [
          {401, :unauthorized},
          {403, :forbidden},
          {404, :unsupported},
          {503, :unavailable}
        ] do
      adapter = fn request ->
        {request, Req.Response.new(status: status, body: %{"error" => "secret"})}
      end

      assert {:error, ^error} = ModelDiscovery.discover(openai_config(), request_options(adapter))
    end

    adapter = fn request -> {request, %Req.TransportError{reason: :timeout}} end
    assert {:error, :timeout} = ModelDiscovery.discover(openai_config(), request_options(adapter))
  end

  test "invalid payloads and incomplete pagination cannot masquerade as complete discovery" do
    for body <- [%{}, %{"data" => "bad"}, %{"data" => [%{"id" => "a"}], "has_more" => true}] do
      adapter = fn request -> {request, Req.Response.new(status: 200, body: body)} end

      assert {:error, :invalid_response} =
               ModelDiscovery.discover(openai_config(), request_options(adapter))
    end

    adapter = fn request ->
      {request,
       Req.Response.new(
         status: 200,
         body: %{"data" => [%{"id" => "a"}], "has_more" => true, "last_id" => "a"}
       )}
    end

    assert {:error, :invalid_response} =
             ModelDiscovery.discover(openai_config(), request_options(adapter))
  end

  test "invalid connection URLs fail before sending credentials" do
    adapter = fn _ -> flunk("must not make request") end

    for url <- [
          "",
          "file:///tmp/models",
          "https://user:password@example.com",
          "https://example.com/v1?key=secret"
        ] do
      config = Map.put(openai_config(), "base_url", url)
      assert {:error, :invalid_url} = ModelDiscovery.discover(config, request_options(adapter))
    end
  end

  defp openai_config, do: %{"api_type" => "openai", "base_url" => "https://models.example/v1"}
end
