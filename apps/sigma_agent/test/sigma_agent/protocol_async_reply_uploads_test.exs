defmodule Sigma.Agent.ProtocolAsyncReplyUploadsTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.{PublicRuntime, Runtime}
  alias Sigma.Agent.Backplane.AsyncDelivery
  alias Sigma.Protocol.{AsyncInteractions, Codec, Envelope}
  alias Sigma.Session.Writer

  @moduletag :tmp_dir
  @session "async-uploads"
  @caps ["async_interactions.pages.v1", "async_interactions.uploads.v1"]
  @chunk_bytes 12_288

  defmodule Provider do
    @behaviour Sigma.Ai.Provider
    def stream(params) do
      send(params.options[:test_pid], {:upload_provider, self(), params})

      receive do
        {:respond, content} ->
          reason = if Enum.any?(content, &(&1.type == :tool_call)), do: :tool_use, else: :stop

          message = %{
            role: :assistant,
            content: content,
            stop_reason: reason,
            usage: %{input: 1, output: 1, total_tokens: 2, cost: %{total: 0.0}},
            model: "fixture",
            provider: "fixture",
            api: "openai-responses",
            timestamp: System.system_time(:millisecond)
          }

          [{:start, %{message | content: []}}, {:done, reason, message}]
      end
    end
  end

  defmodule FailAdmittedStorage do
    @behaviour Sigma.Session.Storage
    alias Sigma.Session.Storage.JsonlFile
    defdelegate read(path), to: JsonlFile
    defdelegate read_with_diagnostics(path), to: JsonlFile

    def append(_path, %{"type" => "async_interaction", "event" => %{"fact" => "admitted"}}),
      do: {:error, :admission_receipt_disk_full}

    def append(path, entry), do: JsonlFile.append(path, entry)
  end

  setup %{tmp_dir: dir} do
    context = %{
      repo_path: dir,
      sessions_dir: Path.join(dir, "sessions"),
      session_opts: [
        model: %{id: "fixture", api: "openai-responses", provider: "fixture"},
        provider: Provider,
        native_tools: true,
        hook_specs: [],
        options: [test_pid: self()]
      ]
    }

    File.mkdir_p!(context.sessions_dir)
    assert {:ok, _} = execute(context, "session.create", %{"cwd" => dir})
    agent = Runtime.lookup(dir, @session, :agent)
    writer = Runtime.lookup(dir, @session, :writer)
    :ok = Sigma.Agent.subscribe(agent)

    on_exit(fn ->
      if supervisor = Runtime.lookup(dir, :supervisor),
        do: DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, supervisor)
    end)

    %{context: context, agent: agent, writer: writer}
  end

  test "uploads require pages and reject mixed legacy negotiation", %{context: context} do
    for caps <- [
          ["async_interactions.uploads.v1"],
          ["async_interactions.v1", "async_interactions.uploads.v1"],
          ["async_interactions.v1" | @caps]
        ] do
      assert {:error, event} =
               execute(context, "session.status", %{"requiredCapabilities" => caps})

      assert event.error.code == "incompatible_protocol_capabilities"
    end

    assert {:ok, snapshot} =
             execute(context, "session.status", %{"requiredCapabilities" => @caps})

    assert snapshot.payload["asyncInteractionInbox"]["itemCount"] == 0
    refute Map.has_key?(snapshot.payload, "asyncInteractions")

    request =
      metadata("item", "anchor", "{}") |> Map.merge(%{"byteOffset" => 0, "data" => "e30="})

    for caps <- [[], ["async_interactions.pages.v1"]] do
      assert {:error, event} =
               execute(context, "async_interaction.reply_chunk", %{
                 request
                 | "requiredCapabilities" => caps
               })

      assert event.error.code == "required_capability_missing"
    end
  end

  test "upload commands have closed schemas and retain the existing V1 wire bounds" do
    payload = metadata("item", "leaf", "{}") |> Map.merge(%{"byteOffset" => 0, "data" => "e30="})
    assert {:ok, command} = Envelope.command("async_interaction.reply_chunk", @session, payload)
    assert {:ok, json} = Codec.encode(command)
    assert {:ok, ^command} = Codec.decode(json)

    for invalid <- [
          Map.put(payload, "reply", %{}),
          Map.delete(payload, "expectedLeafId"),
          Map.put(payload, "byteOffset", -1),
          Map.put(payload, "byteLength", 262_145),
          Map.put(payload, "sha256", String.upcase(payload["sha256"])),
          Map.put(payload, "data", Base.encode64(String.duplicate("x", @chunk_bytes + 1)))
        ] do
      assert {:ok, bad} = Envelope.command("async_interaction.reply_chunk", @session, invalid)
      assert {:error, :invalid_async_upload} = Codec.encode(bad)
      document = Jason.decode!(json) |> Map.put("payload", invalid)
      assert {:error, :invalid_async_upload} = Codec.decode(Jason.encode!(document))
    end

    assert {:ok, ordinary} =
             Envelope.command("async_interaction.reply", @session, %{
               "itemId" => "item",
               "expectedLeafId" => "leaf",
               "requiredCapabilities" => @caps,
               "reply" => %{"replyId" => "large", "text" => String.duplicate("x", 32_769)}
             })

    assert {:error, :payload_too_large} = Codec.encode(ordinary)
  end

  test "large complete original answers have no effects until commit and consume exactly once",
       ctx do
    item = completed_question!(ctx.agent)
    assert {:ok, %{leaf_id: leaf}} = AsyncDelivery.snapshot(ctx.writer)

    answer = %{
      "replyId" => "large-original",
      "answers" =>
        for index <- 0..2 do
          %{
            "questionIndex" => index,
            "answer" => "  #{index}\n" <> String.duplicate("原文\n  ", 3_000)
          }
        end
    }

    assert {:ok, expected} = AsyncInteractions.reply(answer, item)
    bytes = Jason.encode!(answer)
    assert byte_size(bytes) > 65_536
    before = journal(ctx.writer)
    {request, complete} = stage!(ctx.context, item["item_id"], leaf, bytes)
    assert complete.payload["status"] == "complete"
    assert complete.payload["nextByteOffset"] == nil
    refute Map.has_key?(complete.payload, "acknowledgement")
    assert journal(ctx.writer) == before
    refute_receive {:upload_provider, _, _}, 30

    assert {:ok, accepted} = execute(ctx.context, "async_interaction.reply_commit", request)

    assert accepted.payload["acknowledgement"] == %{
             "itemId" => item["item_id"],
             "status" => "admitted"
           }

    {provider, params} = provider!()
    assert [canonical] = correlated(params.context.messages)
    assert canonical.content == expected["content"]
    finish!(provider)

    assert {:ok, %{leaf_id: current, items: [consumed]}} =
             Sigma.Agent.async_interaction_snapshot(ctx.agent)

    assert consumed["status"] == "consumed"
    after_commit = journal(ctx.writer)

    assert {:ok, repeated} =
             execute(ctx.context, "async_interaction.reply_commit", %{
               request
               | "expectedLeafId" => current
             })

    assert repeated.payload["acknowledgement"]["status"] == "consumed"
    assert journal(ctx.writer) == after_commit
    refute_receive {:upload_provider, _, _}, 30
  end

  test "chunk retry and fresh branch fences cannot change staged identity or reply scope", ctx do
    {item, leaf} = notice!(ctx.writer)
    bytes = Jason.encode!(%{"replyId" => "one", "text" => "answer"})
    request = metadata(item, leaf, bytes)

    chunk =
      Map.merge(request, %{"byteOffset" => 0, "data" => Base.encode64(binary_part(bytes, 0, 10))})

    assert {:ok, first} = execute(ctx.context, "async_interaction.reply_chunk", chunk)
    assert {:ok, repeated} = execute(ctx.context, "async_interaction.reply_chunk", chunk)
    assert first.payload == repeated.payload

    assert {:error, _} =
             execute(ctx.context, "async_interaction.reply_chunk", %{
               chunk
               | "expectedLeafId" => "stale"
             })

    assert {:error, _} =
             execute(ctx.context, "async_interaction.reply_chunk", %{chunk | "itemId" => "hidden"})

    assert {:error, _} = execute(ctx.context, "async_interaction.reply_commit", request)
    before = journal(ctx.writer)

    assert {:ok, _} =
             execute(
               ctx.context,
               "session.create",
               %{"cwd" => ctx.context.repo_path},
               "other-session"
             )

    assert {:error, _} =
             execute(ctx.context, "async_interaction.reply_chunk", chunk, "other-session")

    assert journal(ctx.writer) == before

    assert :ok = Sigma.Agent.dismiss_async_interaction(ctx.agent, item, leaf)
    assert {:error, _} = execute(ctx.context, "async_interaction.reply_chunk", chunk)
    assert {:error, _} = execute(ctx.context, "async_interaction.reply_commit", request)

    assert {:ok, cancelled} =
             execute(ctx.context, "async_interaction.reply_cancel", %{
               "uploadId" => request["uploadId"],
               "requiredCapabilities" => @caps
             })

    assert cancelled.payload["status"] == "cancelled"
    refute_receive {:upload_provider, _, _}, 30
  end

  test "an uploaded answer during an active run steers once at the real checkpoint", ctx do
    assert {:accepted, _} = Sigma.Agent.prompt(ctx.agent, "Ask while continuing")
    {provider, _} = provider!()
    questions = for i <- 1..3, do: %{"title" => "Active question #{i}?"}

    send(
      provider,
      {:respond,
       [
         %{
           type: :tool_call,
           id: "active-upload",
           name: "request_user_input_async",
           arguments: %{"questions" => questions}
         }
       ]}
    )

    {provider, _} = provider!()

    assert {:ok, %{items: [item], leaf_id: leaf}} =
             Sigma.Agent.async_interaction_snapshot(ctx.agent)

    reply = %{
      "replyId" => "active-original",
      "answers" =>
        for(
          index <- 0..2,
          do: %{
            "questionIndex" => index,
            "answer" => "  原文\n" <> String.duplicate("active", 4_000)
          }
        )
    }

    assert {:ok, expected} = AsyncInteractions.reply(reply, item)
    bytes = Jason.encode!(reply)
    assert byte_size(bytes) > 65_536
    {request, _} = stage!(ctx.context, item["item_id"], leaf, bytes)
    assert {:ok, accepted} = execute(ctx.context, "async_interaction.reply_commit", request)
    assert accepted.payload["acknowledgement"]["status"] == "admitted"
    assert {:ok, %{leaf_id: current}} = AsyncDelivery.snapshot(ctx.writer)

    assert {:ok, repeated} =
             execute(ctx.context, "async_interaction.reply_commit", %{
               request
               | "expectedLeafId" => current
             })

    assert repeated.payload["acknowledgement"]["status"] == "admitted"
    refute_receive {:upload_provider, _, _}, 30
    send(provider, {:respond, [%{type: :text, text: "Still working"}]})
    {provider, params} = provider!()
    assert [canonical] = correlated(params.context.messages)
    assert canonical.content == expected["content"]

    assert {:ok, %{items: [%{"status" => "consumed"}]}} =
             Sigma.Agent.async_interaction_snapshot(ctx.agent)

    finish!(provider)
    refute_receive {:upload_provider, _, _}, 30
  end

  test "staged buffers never reconcile pending durable delivery facts", ctx do
    {item_id, leaf} = notice!(ctx.writer)
    assert {:ok, %{items: [item]}} = AsyncDelivery.snapshot(ctx.writer)
    payload = %{"replyId" => "unconfirmed", "text" => "pending"}
    assert {:ok, reply} = AsyncInteractions.reply(payload, item)

    for {fact, attrs} <- [
          {"reply_saved", %{"reply" => reply}},
          {"dispatch_started", %{"reply_id" => "unconfirmed"}}
        ] do
      assert :ok = AsyncDelivery.fact(ctx.writer, item, fact, attrs)
    end

    before = journal(ctx.writer)
    stage!(ctx.context, item_id, leaf, Jason.encode!(payload))
    assert journal(ctx.writer) == before
    assert {:ok, %{items: [unchanged]}} = AsyncDelivery.snapshot(ctx.writer)
    assert unchanged["status"] == "dispatching"
    refute_receive {:upload_provider, _, _}, 30
  end

  test "invalid complete replies and hidden selected branches never admit effects", ctx do
    {item, leaf} = notice!(ctx.writer)
    before = journal(ctx.writer)

    for {bytes, id} <- [
          {"not json", "bad-json"},
          {Jason.encode!(%{"replyId" => "wrong", "answers" => []}), "wrong-kind"},
          {Jason.encode!(%{"replyId" => "bad", "text" => " ", "extra" => true}), "extra"}
        ] do
      {request, _} = stage!(ctx.context, item, leaf, bytes, id)
      assert {:error, _} = execute(ctx.context, "async_interaction.reply_commit", request)
      assert journal(ctx.writer) == before
    end

    {request, _} =
      stage!(
        ctx.context,
        item,
        leaf,
        Jason.encode!(%{"replyId" => "branch", "text" => "reply"}),
        "branch"
      )

    assert :ok = Writer.checkout(ctx.writer, nil, leaf)

    assert {:error, _} =
             execute(ctx.context, "async_interaction.reply_commit", %{
               request
               | "expectedLeafId" => nil
             })

    assert {:ok, %{items: []}} = AsyncDelivery.snapshot(ctx.writer)
    refute_receive {:upload_provider, _, _}, 30
  end

  test "accepted upload commits keep receipts when refreshed snapshots fail", ctx do
    {item, leaf} = notice!(ctx.writer)

    {request, _} =
      stage!(
        ctx.context,
        item,
        leaf,
        Jason.encode!(%{"replyId" => "refresh-failure", "text" => "reply"})
      )

    context =
      Map.put(ctx.context, :async_interaction_snapshot, fn _ -> raise "refresh unavailable" end)

    assert {:error, event} = execute(context, "async_interaction.reply_commit", request)
    assert event.payload["acknowledgement"] == %{"itemId" => item, "status" => "admitted"}
    assert event.payload["snapshotRequired"]
    assert {:ok, _} = Codec.encode(event)
    {provider, _} = provider!()
    finish!(provider)
  end

  for type <- ~w(async_interaction.reply async_interaction.reply_commit) do
    @reply_type type
    test "#{type} preserves dispatch acceptance when the admitted receipt cannot persist", ctx do
      {item, leaf} = notice!(ctx.writer)
      reply = %{"replyId" => "failed-admitted", "text" => "  原文\n"}

      request =
        if @reply_type == "async_interaction.reply_commit" do
          {request, _} = stage!(ctx.context, item, leaf, Jason.encode!(reply))
          request
        else
          %{
            "itemId" => item,
            "expectedLeafId" => leaf,
            "reply" => reply,
            "requiredCapabilities" => @caps
          }
        end

      :sys.replace_state(ctx.writer, &%{&1 | storage_mod: FailAdmittedStorage})
      assert {:error, event} = execute(ctx.context, @reply_type, request)
      assert event.payload["acknowledgement"] == %{"itemId" => item, "status" => "dispatching"}
      assert event.payload["snapshotRequired"]
      assert event.error.code == "storage_append_failed"
      assert {:ok, _} = Codec.encode(event)
      assert {:ok, %{projection: projection}} = Writer.async_interaction_state(ctx.writer)
      refute Enum.any?(projection.events, fn {_id, fact} -> fact["fact"] == "admitted" end)
      {provider, params} = provider!()
      assert length(correlated(params.context.messages)) == 1
      assert {:ok, %{leaf_id: active_leaf}} = AsyncDelivery.snapshot(ctx.writer)

      assert {:ok, active_retry} =
               execute(ctx.context, @reply_type, %{request | "expectedLeafId" => active_leaf})

      assert active_retry.payload["acknowledgement"]["status"] in ~w(dispatching admitted consumed delivery_unknown)

      refute_receive {:upload_provider, _, _}, 30
      finish!(provider)
      assert {:ok, %{leaf_id: current}} = AsyncDelivery.snapshot(ctx.writer)

      assert {:ok, repeated} =
               execute(ctx.context, @reply_type, %{request | "expectedLeafId" => current})

      assert repeated.payload["acknowledgement"]["status"] == "consumed"
      restart!(ctx.context)

      assert {:ok, repeated} =
               execute(ctx.context, "async_interaction.reply", %{
                 "itemId" => item,
                 "expectedLeafId" => current,
                 "reply" => reply,
                 "requiredCapabilities" => @caps
               })

      assert repeated.payload["acknowledgement"]["status"] == "consumed"
      refute_receive {:upload_provider, _, _}, 30
    end
  end

  test "unknown origin without a saved reply cannot acknowledge an invented answer", ctx do
    {item_id, leaf} = notice!(ctx.writer)
    reply = %{"replyId" => "invented", "text" => "answer"}
    {request, _} = stage!(ctx.context, item_id, leaf, Jason.encode!(reply))
    assert {:ok, %{items: [item]}} = AsyncDelivery.snapshot(ctx.writer)

    assert :ok =
             AsyncDelivery.fact(ctx.writer, item, "delivery_unknown", %{
               "reason" => "origin_unconfirmed"
             })

    before = journal(ctx.writer)
    assert {:error, event} = execute(ctx.context, "async_interaction.reply_commit", request)
    refute Map.has_key?(event.payload, "acknowledgement")

    assert {:error, event} =
             execute(ctx.context, "async_interaction.reply", %{
               "itemId" => item_id,
               "expectedLeafId" => leaf,
               "reply" => reply,
               "requiredCapabilities" => @caps
             })

    refute Map.has_key?(event.payload, "acknowledgement")
    assert journal(ctx.writer) == before
    refute_receive {:upload_provider, _, _}, 30
  end

  test "Agent restart discards staged bytes and reupload reuses the durable consumed receipt",
       ctx do
    {item, leaf} = notice!(ctx.writer)
    bytes = Jason.encode!(%{"replyId" => "restart", "text" => "  原文\n"})
    {request, _} = stage!(ctx.context, item, leaf, bytes)
    before = journal(ctx.writer)
    restart!(ctx.context)
    assert {:error, missing} = execute(ctx.context, "async_interaction.reply_commit", request)
    assert missing.error.code == "async_upload_not_found"
    writer = Runtime.lookup(ctx.context.repo_path, @session, :writer)
    assert journal(writer) == before
    {request, _} = stage!(ctx.context, item, leaf, bytes)
    assert {:ok, _} = execute(ctx.context, "async_interaction.reply_commit", request)
    {provider, _} = provider!()
    finish!(provider)
    restart!(ctx.context)
    agent = Runtime.lookup(ctx.context.repo_path, @session, :agent)
    assert {:ok, %{leaf_id: current}} = Sigma.Agent.async_interaction_snapshot(agent)
    {request, _} = stage!(ctx.context, item, current, bytes)
    assert {:ok, repeated} = execute(ctx.context, "async_interaction.reply_commit", request)
    assert repeated.payload["acknowledgement"]["status"] == "consumed"
    refute_receive {:upload_provider, _, _}, 30
  end

  defp stage!(context, item, leaf, bytes, id \\ "upload") do
    request = metadata(item, leaf, bytes) |> Map.put("uploadId", id)

    progress =
      for offset <- 0..div(byte_size(bytes) - 1, @chunk_bytes) do
        offset = offset * @chunk_bytes
        size = min(@chunk_bytes, byte_size(bytes) - offset)

        chunk =
          Map.merge(request, %{
            "byteOffset" => offset,
            "data" => Base.encode64(binary_part(bytes, offset, size))
          })

        assert {:ok, event} = execute(context, "async_interaction.reply_chunk", chunk)
        assert event.type == "async_interaction.uploaded"
        assert {:ok, _} = Codec.encode(event)
        event
      end

    {request, List.last(progress)}
  end

  defp metadata(item, leaf, bytes),
    do: %{
      "uploadId" => "upload",
      "itemId" => item,
      "expectedLeafId" => leaf,
      "byteLength" => byte_size(bytes),
      "sha256" => :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
      "requiredCapabilities" => @caps
    }

  defp notice!(writer) do
    message =
      Sigma.Agent.Message.user("origin", "Origin")
      |> Map.put(:metadata, %{turn_id: "fixture-run"})

    assert {:ok, anchor} = Writer.append(writer, {:message_end, message})

    event = %{
      "version" => 1,
      "fact" => "received",
      "event_id" => "received",
      "item_id" => "notice",
      "session_id" => @session,
      "message" => "Progress",
      "origin" => %{
        "run_id" => "fixture-run",
        "incarnation" => 1,
        "turn_id" => "fixture-run",
        "step_id" => "step",
        "attempt_id" => "attempt",
        "invocation_id" => "invocation",
        "tool_call_id" => "call",
        "tool_name" => "send_message_to_user_async",
        "branch_entry_id" => anchor
      }
    }

    assert {:ok, _} = Writer.append_async_interaction(writer, event, anchor)
    {"notice", anchor}
  end

  defp completed_question!(agent) do
    assert {:accepted, _} = Sigma.Agent.prompt(agent, "Ask")
    {provider, _} = provider!()
    questions = for i <- 1..3, do: %{"title" => "Question #{i}?"}

    send(
      provider,
      {:respond,
       [
         %{
           type: :tool_call,
           id: "questions",
           name: "request_user_input_async",
           arguments: %{"questions" => questions}
         }
       ]}
    )

    {provider, _} = provider!()
    finish!(provider)
    assert {:ok, %{items: [item]}} = Sigma.Agent.async_interaction_snapshot(agent)
    item
  end

  defp restart!(context) do
    assert :ok =
             DynamicSupervisor.terminate_child(
               Runtime.lookup(context.repo_path, :sessions),
               Runtime.lookup(context.repo_path, @session, :supervisor)
             )

    assert {:ok, _} = execute(context, "session.resume", %{})
    :ok = Sigma.Agent.subscribe(Runtime.lookup(context.repo_path, @session, :agent))
  end

  defp journal(writer) do
    assert {:ok, state} = Writer.async_interaction_state(writer)
    {state.entries, state.projection, state.leaf_id}
  end

  defp provider! do
    assert_receive {:upload_provider, provider, params}, 8_000
    {provider, params}
  end

  defp finish!(provider) do
    send(provider, {:respond, [%{type: :text, text: "Done"}]})
    assert_receive {:agent_end, _}, 5_000
  end

  defp correlated(messages),
    do:
      Enum.filter(
        messages,
        &(&1.role == :user and is_map(Map.get(&1, :metadata)) and
            Map.has_key?(&1.metadata, "async_interaction"))
      )

  defp execute(context, type, payload, session \\ @session) do
    assert {:ok, command} = Envelope.command(type, session, payload)
    PublicRuntime.execute(command, context)
  end
end
