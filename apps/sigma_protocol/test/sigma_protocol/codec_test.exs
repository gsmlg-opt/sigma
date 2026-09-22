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

    unknown_name = "future.command.#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_name) end

    unknown_type =
      unknown_version
      |> String.replace("999", "1")
      |> String.replace("prompt.submit", unknown_name)

    assert {:error, {:unknown_type, ^unknown_name}} = Codec.decode(unknown_type)
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_name) end
  end

  test "publishes the closed protocol capability set" do
    assert Envelope.capabilities() == [
             "metrics.v1",
             "skills.v1",
             "subscription.cursor.v1",
             "subscription.resync.v1"
           ]
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

  test "round trips the additive skills.v1 command and event" do
    assert {:ok, command} =
             Envelope.command("skill.invoke", "session-1", %{
               "repositoryId" => "repo-1",
               "reference" => "global:review",
               "arguments" => "check"
             })

    assert {:ok, encoded} = Codec.encode(command)
    assert {:ok, ^command} = Codec.decode(encoded)

    assert {:ok, event} =
             Envelope.event("skill.invocation.updated", "session-1", %{"state" => "queued"})

    assert {:ok, encoded} = Codec.encode(event)
    assert {:ok, ^event} = Codec.decode(encoded)
  end
end
