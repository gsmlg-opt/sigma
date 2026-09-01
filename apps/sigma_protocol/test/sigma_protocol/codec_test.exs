defmodule Sigma.Protocol.CodecTest do
  use ExUnit.Case, async: true

  alias Sigma.Protocol.{Codec, Envelope, Error}

  test "commands and events round trip through Protocol V1 JSON" do
    assert {:ok, command} =
             Envelope.command("prompt.submit", "session-1", %{"content" => "hello"},
               id: "request-1",
               turn_id: "turn-1",
               timestamp: 1_788_000_000_000
             )

    assert {:ok, encoded} = Codec.encode(command)
    assert {:ok, ^command} = Codec.decode(encoded)

    error = Error.new("provider_timeout", "Provider timed out", %{"retryable" => true})

    assert {:ok, event} =
             Envelope.event("turn.failed", "session-1", %{"terminal" => true},
               id: "event-1",
               turn_id: "turn-1",
               timestamp: 1_788_000_000_001,
               error: error
             )

    assert {:ok, encoded} = Codec.encode(event)
    assert {:ok, ^event} = Codec.decode(encoded)
  end

  test "rejects unknown versions and types without creating atoms" do
    unknown_version =
      Jason.encode!(%{
        "version" => 999,
        "id" => "request-1",
        "sessionId" => "session-1",
        "turnId" => nil,
        "timestamp" => 1,
        "kind" => "command",
        "type" => "prompt.submit",
        "payload" => %{},
        "error" => nil
      })

    assert {:error, {:unsupported_version, 999}} = Codec.decode(unknown_version)

    unknown_type = String.replace(unknown_version, "999", "1") |> String.replace("prompt.submit", "future.command")
    assert {:error, {:unknown_type, "future.command"}} = Codec.decode(unknown_type)
  end

  test "refuses internal process terms and oversized event payloads" do
    assert {:ok, event} =
             Envelope.event("session.snapshot", "session-1", %{"owner" => self()})

    assert {:error, :unsafe_payload} = Codec.encode(event)

    assert {:ok, event} =
             Envelope.event("message.delta", "session-1", %{
               "delta" => String.duplicate("x", 40_000)
             })

    assert {:error, :payload_too_large} = Codec.encode(event)
  end
end
