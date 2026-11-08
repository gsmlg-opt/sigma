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
             "subagents.v1",
             "subscription.cursor.v1",
             "subscription.resync.v1",
             "questions.v1",
             "async_interactions.v1",
             "async_interactions.pages.v1",
             "async_interactions.uploads.v1",
             "provider_hosted.v1",
             "provider_hosted.pages.v1",
             "plugins.install.v1"
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

  test "hosted result page commands round trip and reject source or range injection" do
    revision = String.duplicate("a", 64)

    for {type, payload} <- [
          {"provider_hosted.list",
           %{"expectedRevision" => revision, "offset" => 0, "limit" => 50}},
          {"provider_hosted.read",
           %{
             "expectedRevision" => revision,
             "entryId" => "entry",
             "messageId" => "message",
             "byteOffset" => 12_288
           }}
        ] do
      payload = Map.put(payload, "requiredCapabilities", ["provider_hosted.pages.v1"])
      assert {:ok, command} = Envelope.command(type, "session", payload)
      assert {:ok, encoded} = Codec.encode(command)
      assert {:ok, ^command} = Codec.decode(encoded)

      invalid_ranges =
        if type == "provider_hosted.list",
          do: [Map.put(payload, "offset", -1), Map.put(payload, "limit", 51)],
          else: [Map.put(payload, "byteOffset", 0.5), Map.put(payload, "messageId", "")]

      for invalid <-
            [
              Map.put(payload, "filePath", "/private"),
              Map.put(payload, "expectedRevision", "stale")
            ] ++ invalid_ranges do
        assert {:error, :invalid_provider_hosted_page} =
                 Codec.encode(%{command | payload: invalid})

        document = encoded |> Jason.decode!() |> Map.put("payload", invalid) |> Jason.encode!()
        assert {:error, :invalid_provider_hosted_page} = Codec.decode(document)
      end
    end

    for type <- ~w(provider_hosted.changed provider_hosted.page provider_hosted.chunk) do
      assert {:ok, event} = Envelope.event(type, "session", %{})
      assert {:ok, encoded} = Codec.encode(event)
      assert {:ok, ^event} = Codec.decode(encoded)
    end
  end

  test "nested native arguments remain subject to a finite depth limit" do
    payload = Enum.reduce(1..17, "value", fn _, value -> %{"nested" => value} end)
    assert {:ok, event} = Envelope.event("message.completed", "session", payload)
    assert {:error, :payload_too_deep} = Codec.encode(event)
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

  test "async interaction commands round trip exact user answers and reject identity injection" do
    payload = %{
      "itemId" => "item",
      "expectedLeafId" => "leaf",
      "reply" => %{
        "replyId" => "reply",
        "answers" => [%{"questionIndex" => 0, "answer" => "  原文\n"}]
      },
      "requiredCapabilities" => ["async_interactions.v1"]
    }

    assert {:ok, command} = Envelope.command("async_interaction.reply", "session", payload)
    assert {:ok, json} = Codec.encode(command)
    assert {:ok, ^command} = Codec.decode(json)

    for invalid <- [
          Map.put(payload, "turnId", "chosen-turn"),
          Map.delete(payload, "expectedLeafId"),
          put_in(payload, ["reply", "message_id"], "chosen-message"),
          put_in(payload, ["reply", "answers"], [%{"questionIndex" => 1, "answer" => "A"}]),
          put_in(payload, ["reply", "answers"], [%{"questionIndex" => 0, "answer" => " "}])
        ] do
      assert {:ok, invalid_command} =
               Envelope.command("async_interaction.reply", "session", invalid)

      assert {:error, :invalid_async_interaction_command} = Codec.encode(invalid_command)
      document = Jason.decode!(json) |> Map.put("payload", invalid)
      assert {:error, :invalid_async_interaction_command} = Codec.decode(Jason.encode!(document))
    end

    assert {:ok, dismiss} =
             Envelope.command(
               "async_interaction.dismiss",
               "session",
               Map.drop(payload, ["reply"])
             )

    assert {:ok, json} = Codec.encode(dismiss)
    assert {:ok, ^dismiss} = Codec.decode(json)

    assert {:ok, notice_reply} =
             Envelope.command("async_interaction.reply", "session", %{
               payload
               | "reply" => %{"replyId" => "optional", "text" => "Continue"}
             })

    assert {:ok, _} = Codec.encode(notice_reply)

    assert {:ok, event} =
             Envelope.event("async_interactions.updated", "session", %{
               "items" => [],
               "leafId" => nil
             })

    assert {:ok, json} = Codec.encode(event)
    assert {:ok, ^event} = Codec.decode(json)
  end

  test "subagents v1 event round trips and snapshot DTO strips arbitrary fields" do
    row = %{
      agent_id: "child",
      run_id: "run",
      incarnation: 1,
      status: :completed,
      revision: 1,
      event_id: "event",
      observer_incarnation: "owner",
      credentials: "secret",
      pid: self(),
      reference: make_ref(),
      callback: fn -> :secret end
    }

    roster = %{
      revision: 1,
      agents: [row],
      counts: %{created: 1, executing: 0, pending: 0, stopped: 1, unknown: 0},
      secret: "hidden"
    }

    assert {:ok, safe} = Sigma.Protocol.Subagents.snapshot(roster)
    refute inspect(safe) =~ "secret"
    refute inspect(safe) =~ "#PID"

    assert {:ok, event} =
             Envelope.event("subagents.changed", "root", Sigma.Protocol.Subagents.to_map(safe))

    assert {:ok, encoded} = Codec.encode(event)
    assert {:ok, ^event} = Codec.decode(encoded)

    assert {:error, _} =
             Sigma.Protocol.Subagents.snapshot(
               put_in(roster, [:agents], [%{row | agent_id: self()}])
             )

    assert {:error, _} =
             Sigma.Protocol.Subagents.snapshot(put_in(roster, [:counts, :stopped], self()))
  end
end
