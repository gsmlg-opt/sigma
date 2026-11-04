defmodule Sigma.Agent.ProtocolHostedTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.{Message, PublicRuntime, Runtime}
  alias Sigma.Protocol.{Codec, Envelope}
  alias Sigma.Session.Writer

  @moduletag :tmp_dir
  @capability "provider_hosted.v1"
  @session "hosted-protocol"

  setup %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    sessions = Path.join(dir, "sessions")
    File.mkdir_p!(repo)
    File.mkdir_p!(sessions)

    context = %{
      repo_path: repo,
      sessions_dir: sessions,
      session_opts: [
        model: %{id: "mock", api: "mock", provider: "mock"},
        provider: Sigma.Ai.Providers.Anthropic
      ]
    }

    assert {:ok, _} = execute(context, "session.create", %{"cwd" => repo})
    agent = Runtime.lookup(repo, @session, :agent)
    writer = Runtime.lookup(repo, @session, :writer)

    on_exit(fn ->
      if supervisor = Runtime.lookup(repo, :supervisor),
        do: DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, supervisor)
    end)

    %{context: context, agent: agent, writer: writer}
  end

  test "opted-in snapshots preserve exact native metadata and withhold unrelated metadata", ctx do
    envelope =
      native_metadata()
      |> put_in(
        ["items", Access.at(0), "item", "action", "queries"],
        Enum.map(1..110, &"query #{&1}")
      )
      |> put_in(
        [
          "items",
          Access.at(1),
          "item",
          "content",
          Access.at(0),
          "annotations",
          Access.at(0),
          "title"
        ],
        String.duplicate("源", 6_000)
      )

    message = message(envelope)
    assert {:ok, _} = Writer.append(ctx.writer, {:message_end, message})
    assert @capability in Envelope.capabilities()
    assert {:ok, legacy} = execute(ctx.context, "session.status")
    refute Map.has_key?(hd(legacy.payload["messages"]), "metadata")

    assert {:ok, capable} = execute(ctx.context, "session.status", opted())
    assert hd(capable.payload["messages"])["metadata"] == %{"openai_responses_hosted" => envelope}
    assert {:ok, encoded} = Codec.encode(capable)
    assert {:ok, decoded} = Codec.decode(encoded)
    assert hd(decoded.payload["messages"])["metadata"] == %{"openai_responses_hosted" => envelope}
    refute encoded =~ "private-host-value"
  end

  test "legacy and capable live subscribers receive isolated message and raw observation projections",
       ctx do
    assert {:ok, capable} = execute(ctx.context, "subscription.attach", opted())
    assert {:ok, legacy} = execute(ctx.context, "subscription.attach")
    capable_id = capable.payload["subscriptionId"]
    legacy_id = legacy.payload["subscriptionId"]
    frame = search_frame()
    message = message(native_metadata())

    for id <- [capable_id, legacy_id] do
      send(relay(id), {:provider_hosted_event, "web_search", frame})
      send(relay(id), {:message_start, message})
      send(relay(id), {:message_end, message})
    end

    hosted = receive_type(capable_id, "provider.hosted")

    assert Map.drop(hosted.payload, ["cursor"]) == %{
             "capability" => "web_search",
             "event" => frame
           }

    assert hosted.payload["cursor"] > 0

    for type <- ["message.started", "message.completed"] do
      assert receive_type(capable_id, type).payload["message"]["metadata"] == %{
               "openai_responses_hosted" => native_metadata()
             }

      refute Map.has_key?(receive_type(legacy_id, type).payload["message"], "metadata")
    end

    refute_receive {:sigma_protocol, ^legacy_id, %{type: "provider.hosted"}}, 30
  end

  for {name, code} <- [
        {"single string", "provider_hosted_payload_too_large"},
        {"aggregate bytes", "provider_hosted_payload_too_large"},
        {"collection count", "provider_hosted_payload_too_large"},
        {"nesting", "provider_hosted_payload_rejected"},
        {"invalid metadata", "provider_hosted_payload_rejected"}
      ] do
    test "#{name} rejects capable snapshots and cleans failed attachment without dropping messages",
         ctx do
      envelope = invalid_metadata(unquote(name))
      assert {:ok, _} = Writer.append(ctx.writer, {:message_end, message(envelope)})
      before_subscribers = :sys.get_state(ctx.agent).subscribers
      before_relays = Registry.count(Sigma.Agent.ProtocolSubscriptionRegistry)

      assert {:error, %{error: %{code: unquote(code)}}} =
               execute(ctx.context, "session.status", opted())

      assert {:error, %{error: %{code: unquote(code)}}} =
               execute(ctx.context, "subscription.attach", opted())

      assert Registry.count(Sigma.Agent.ProtocolSubscriptionRegistry) == before_relays
      assert :sys.get_state(ctx.agent).subscribers == before_subscribers
      assert {:ok, legacy} = execute(ctx.context, "session.status")
      assert length(legacy.payload["messages"]) == 1
    end
  end

  test "failed capable status keeps an existing subscription alive", ctx do
    assert {:ok, attached} = execute(ctx.context, "subscription.attach", opted())
    id = attached.payload["subscriptionId"]
    pid = relay(id)

    envelope =
      put_in(
        native_metadata(),
        ["items", Access.at(0), "item", "action", "queries"],
        List.duplicate(String.duplicate("q", 9_000), 8)
      )

    assert {:ok, _} = Writer.append(ctx.writer, {:message_end, message(envelope)})

    assert {:error, %{error: %{code: "provider_hosted_payload_too_large"}}} =
             execute(ctx.context, "session.status", Map.put(opted(), "subscriptionId", id))

    assert Process.alive?(pid)
    assert relay(id) == pid
  end

  test "unknown origin fields reject the complete projection without exposing their values",
       ctx do
    assert {:ok, attached} = execute(ctx.context, "subscription.attach", opted())
    id = attached.payload["subscriptionId"]
    envelope = put_in(native_metadata(), ["origin", "private"], "private-origin-value")
    assert {:ok, _} = Writer.append(ctx.writer, {:message_end, message(envelope)})

    assert {:error, snapshot_error} = execute(ctx.context, "session.status", opted())
    assert snapshot_error.error.code == "provider_hosted_payload_rejected"
    assert {:ok, encoded} = Codec.encode(snapshot_error)
    refute encoded =~ "private-origin-value"

    send(relay(id), {:message_end, message(envelope)})
    live_error = receive_type(id, "session.error")
    assert live_error.error.code == "provider_hosted_payload_rejected"
    assert {:ok, encoded} = Codec.encode(live_error)
    refute encoded =~ "private-origin-value"
  end

  test "failed attachment validates its final envelope before publishing queued observations",
       ctx do
    envelope = invalid_metadata("aggregate bytes")
    assert {:ok, _} = Writer.append(ctx.writer, {:message_end, message(envelope)})
    owner = self()
    subscribers = :sys.get_state(ctx.agent).subscribers
    count = Registry.count(Sigma.Agent.ProtocolSubscriptionRegistry)

    context =
      ctx.context
      |> Map.put(:subscriber, owner)
      |> Map.put(:async_interaction_snapshot, fn _agent ->
        send(owner, {:attachment_loading, self()})

        receive do
          :release_attachment -> {:ok, %{items: [], leaf_id: "anchor"}}
        after
          5_000 -> {:error, :fixture_release_timeout}
        end
      end)

    task =
      Task.async(fn ->
        result =
          execute(context, "subscription.attach", %{
            "requiredCapabilities" => [@capability, "async_interactions.v1"]
          })

        send(owner, {:attachment_result, result})
        result
      end)

    assert_receive {:attachment_loading, pid}
    assert :erlang.suspend_process(task.pid)

    try do
      send(pid, {:provider_hosted_event, "web_search", search_frame()})
      send(pid, :release_attachment)
      refute_receive {:sigma_protocol, _, _}, 100
    after
      :erlang.resume_process(task.pid)
      Task.await(task, 5_000)
    end

    assert_receive {:attachment_result,
                    {:error, %{error: %{code: "provider_hosted_payload_too_large"}}}}

    refute Process.alive?(pid)
    assert Registry.count(Sigma.Agent.ProtocolSubscriptionRegistry) == count
    assert :sys.get_state(ctx.agent).subscribers == subscribers
    refute_receive {:sigma_protocol, _, _}, 30
  end

  test "raw delivery validates the final cursor-bearing envelope", ctx do
    assert {:ok, attached} = execute(ctx.context, "subscription.attach", opted())
    id = attached.payload["subscriptionId"]
    frame = search_frame() |> Map.put("padding", List.duplicate(String.duplicate("x", 15_000), 4))

    {:ok, probe} =
      Envelope.event("provider.hosted", @session, %{
        "capability" => "web_search",
        "event" => frame
      })

    {:ok, encoded} = Codec.encode(probe)
    padding = 65_536 - byte_size(encoded)
    frame = Map.update!(frame, "padding", &(&1 ++ [String.duplicate("p", padding - 3)]))

    {:ok, bare} =
      Envelope.event("provider.hosted", @session, %{
        "capability" => "web_search",
        "event" => frame
      })

    assert {:ok, _} = Codec.encode(bare)

    assert {:error, :payload_too_large} =
             Codec.encode(%{bare | payload: Map.put(bare.payload, "cursor", 1)})

    send(relay(id), {:provider_hosted_event, "web_search", frame})
    error = receive_type(id, "session.error")
    assert error.error.code == "provider_hosted_payload_too_large"
    refute Map.has_key?(error.payload, "event")
  end

  test "unsafe raw frames and unrepresentable message metadata yield explicit encodable errors",
       ctx do
    assert {:ok, attached} = execute(ctx.context, "subscription.attach", opted())
    id = attached.payload["subscriptionId"]

    send(
      relay(id),
      {:provider_hosted_event, "web_search", Map.put(search_frame(), "unsafe", self())}
    )

    assert receive_type(id, "session.error").error.code == "provider_hosted_payload_rejected"

    envelope =
      put_in(
        native_metadata(),
        ["items", Access.at(0), "item", "action", "queries"],
        List.duplicate(String.duplicate("q", 9_000), 8)
      )

    send(relay(id), {:message_end, message(envelope)})
    assert receive_type(id, "session.error").error.code == "provider_hosted_payload_too_large"
    send(relay(id), {:turn_completed, "finished"})
    assert receive_type(id, "turn.completed").turn_id == "finished"
  end

  test "reattachment restores durable metadata without replaying raw observations", ctx do
    assert {:ok, _} = Writer.append(ctx.writer, {:message_end, message(native_metadata())})
    assert {:ok, first} = execute(ctx.context, "subscription.attach", opted())
    first_id = first.payload["subscriptionId"]
    send(relay(first_id), {:provider_hosted_event, "web_search", search_frame()})
    assert receive_type(first_id, "provider.hosted")
    assert {:ok, _} = execute(ctx.context, "subscription.detach", %{"subscriptionId" => first_id})
    assert {:ok, second} = execute(ctx.context, "subscription.attach", opted())
    second_id = second.payload["subscriptionId"]

    assert hd(second.payload["messages"])["metadata"] == %{
             "openai_responses_hosted" => native_metadata()
           }

    refute_receive {:sigma_protocol, ^second_id, %{type: "provider.hosted"}}, 30
  end

  defp native_metadata do
    %{
      "version" => 1,
      "origin" => %{
        "protocol" => "openai-responses",
        "provider" => "fixture",
        "model" => "fixture",
        "endpoint_sha256" => String.duplicate("a", 64)
      },
      "response_id" => "response",
      "items" => [
        %{
          "output_index" => 0,
          "item" => %{
            "type" => "web_search_call",
            "id" => "search",
            "status" => "completed",
            "action" => %{"type" => "search", "query" => "source"}
          }
        },
        %{
          "output_index" => 1,
          "item" => %{
            "type" => "message",
            "id" => "message",
            "role" => "assistant",
            "status" => "completed",
            "content" => [
              %{
                "type" => "output_text",
                "text" => "Found it",
                "annotations" => [
                  %{
                    "type" => "url_citation",
                    "url" => "https://example.com/source",
                    "title" => "Source",
                    "start_index" => 0,
                    "end_index" => 5
                  }
                ]
              }
            ]
          }
        }
      ]
    }
  end

  defp invalid_metadata("single string"),
    do:
      put_in(
        native_metadata(),
        [
          "items",
          Access.at(1),
          "item",
          "content",
          Access.at(0),
          "annotations",
          Access.at(0),
          "title"
        ],
        String.duplicate("x", 32_769)
      )

  defp invalid_metadata("aggregate bytes"),
    do:
      put_in(
        native_metadata(),
        ["items", Access.at(0), "item", "action", "queries"],
        List.duplicate(String.duplicate("q", 9_000), 8)
      )

  defp invalid_metadata("collection count"),
    do:
      put_in(
        native_metadata(),
        ["items", Access.at(0), "item", "action", "queries"],
        List.duplicate("query", 201)
      )

  defp invalid_metadata("nesting"),
    do:
      put_in(
        native_metadata(),
        ["items", Access.at(0), "item", "extra"],
        Enum.reduce(1..18, "leaf", fn _, value -> %{"nested" => value} end)
      )

  defp invalid_metadata("invalid metadata"), do: Map.put(native_metadata(), "version", 2)

  defp message(envelope) do
    Message.assistant("hosted-message", %{
      content: [%{type: :text, text: "Found it"}],
      provider: "fixture",
      model: "fixture",
      timestamp: 1
    })
    |> Map.put(:metadata, %{
      "openai_responses_hosted" => envelope,
      "private" => "private-host-value"
    })
  end

  defp search_frame,
    do: %{
      "type" => "response.web_search_call.searching",
      "output_index" => 0,
      "item_id" => "search"
    }

  defp opted, do: %{"requiredCapabilities" => [@capability]}

  defp execute(context, type, payload \\ %{}) do
    assert {:ok, command} = Envelope.command(type, @session, payload)
    PublicRuntime.execute(command, context)
  end

  defp relay(id) do
    [{pid, _}] = Registry.lookup(Sigma.Agent.ProtocolSubscriptionRegistry, id)
    pid
  end

  defp receive_type(id, type) do
    receive do
      {:sigma_protocol, ^id, %{type: ^type} = event} ->
        assert {:ok, _} = Codec.encode(event)
        event

      {:sigma_protocol, ^id, _} ->
        receive_type(id, type)
    after
      1_000 -> flunk("timed out waiting for #{type}")
    end
  end
end
