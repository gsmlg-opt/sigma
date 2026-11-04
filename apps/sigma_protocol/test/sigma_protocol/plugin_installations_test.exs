defmodule Sigma.Protocol.PluginInstallationsTest do
  use ExUnit.Case, async: true

  alias Sigma.Protocol.{Codec, Envelope, PluginInstallations}

  test "request and installation commands preserve their explicit DTO through the codec" do
    for {type, payload} <- [
          {"plugins.requests", %{}},
          {"plugins.requests",
           %{"offset" => 20, "expectedRevision" => "revision", "limit" => 10}},
          {"plugins.install", %{"requestId" => "plugin-request-example"}}
        ] do
      payload = Map.put(payload, "requiredCapabilities", ["plugins.install.v1"])
      assert {:ok, command} = Envelope.command(type, "session", payload)
      assert {:ok, encoded} = Codec.encode(command)
      assert {:ok, ^command} = Codec.decode(encoded)
    end

    assert "plugins.install.v1" in Envelope.capabilities()
  end

  test "continuation pages require a revision and supported positive page size" do
    for payload <- [
          %{"offset" => 1},
          %{"limit" => 0},
          %{"limit" => 51},
          %{"offset" => -1},
          %{"expectedRevision" => ""}
        ] do
      assert {:ok, command} = Envelope.command("plugins.requests", "session", payload)
      assert {:error, :invalid_plugin_request_page} = Codec.encode(command)
    end

    assert {:ok, command} = Envelope.command("plugins.install", "session", %{})
    assert {:error, :invalid_plugin_installation_request} = Codec.encode(command)
  end

  test "large pages return complete summaries and a cursor for the remaining rows" do
    items = for index <- 1..10, do: summary("request-#{index}", String.duplicate("中", 3000))

    page = %{
      "configured" => true,
      "registryUrl" => "http://registry.example",
      "revision" => "revision",
      "offset" => 0,
      "nextOffset" => nil,
      "total" => length(items),
      "items" => items
    }

    assert {:ok, event} = PluginInstallations.page("session", page)
    assert event.type == "plugins.requests.page"
    assert length(event.payload["items"]) in 1..9
    assert event.payload["items"] == Enum.take(items, length(event.payload["items"]))
    assert event.payload["nextOffset"] == length(event.payload["items"])
    assert {:ok, encoded} = Codec.encode(event)
    assert {:ok, ^event} = Codec.decode(encoded)
  end

  test "installation acknowledgement retains committed success when a full receipt exceeds V1" do
    receipt =
      summary("plugin-request-example", "example")
      |> Map.merge(%{"status" => "installed", "releaseId" => String.duplicate("r", 40_000)})

    assert {:ok, event} = PluginInstallations.installed("session", receipt)

    assert event.payload == %{
             "installation" => %{"requestId" => "plugin-request-example", "status" => "installed"},
             "receiptOmitted" => true,
             "receiptError" => "payload_too_large"
           }

    assert {:ok, encoded} = Codec.encode(event)
    assert {:ok, ^event} = Codec.decode(encoded)

    receipt = Map.put(receipt, "releaseId", "release-example")
    assert {:ok, complete} = PluginInstallations.installed("session", receipt)
    assert complete.payload == %{"installation" => receipt}
  end

  defp summary(id, plugin) do
    %{
      "requestId" => id,
      "pluginId" => plugin,
      "registryUrl" => "http://registry.example",
      "requestStatus" => "requested",
      "status" => "requested",
      "requestedAt" => 1
    }
  end
end
