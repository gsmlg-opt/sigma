defmodule Sigma.Agent.ProtocolHostedPagesTest do
  use ExUnit.Case, async: false

  alias Sigma.Agent.{Message, PublicRuntime, Runtime}
  alias Sigma.Protocol.{Codec, Envelope}
  alias Sigma.Session.{Log, Writer}

  @moduletag :tmp_dir
  @session "hosted-pages"
  @capability "provider_hosted.pages.v1"

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

    on_exit(fn ->
      if supervisor = Runtime.lookup(repo, :supervisor),
        do: DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, supervisor)
    end)

    %{
      context: context,
      writer: Runtime.lookup(repo, @session, :writer),
      path: Path.join(sessions, @session <> ".jsonl")
    }
  end

  test "complete large native results can be listed and read without changing the journal", ctx do
    native = native_metadata()
    assert {:ok, entry_id} = Writer.append(ctx.writer, {:message_end, message("large", native)})
    before = File.read!(ctx.path)
    assert @capability in Envelope.capabilities()

    assert {:ok, snapshot} = execute(ctx.context, "session.status", opted())
    assert {:ok, _} = Codec.encode(snapshot)
    refute Map.has_key?(hd(snapshot.payload["messages"]), "metadata")
    directory = snapshot.payload["providerHostedResults"]
    assert directory["leafId"] == entry_id
    assert directory["resultCount"] == 1

    assert {:ok, page} = list(ctx, directory)
    assert [%{"entryId" => ^entry_id, "messageId" => "large"} = summary] = page.payload["items"]
    assert summary["byteLength"] > 65_536
    assert read_all(ctx, directory, summary) == native
    assert File.read!(ctx.path) == before

    assert {:error, %{error: %{code: "provider_hosted_payload_too_large"}}} =
             execute(ctx.context, "session.status", %{
               "requiredCapabilities" => ["provider_hosted.v1"]
             })
  end

  test "reads use the actual Writer checkout and reject stale or sibling source identities",
       ctx do
    assert {:ok, anchor} =
             Writer.append(ctx.writer, {:message_end, Message.user("anchor", "start")})

    assert {:ok, left} =
             Writer.append(ctx.writer, {:message_end, message("left", native_metadata())})

    assert {:ok, left_snapshot} = execute(ctx.context, "session.status", opted())
    left_directory = left_snapshot.payload["providerHostedResults"]
    assert :ok = Writer.checkout(ctx.writer, anchor, left)

    assert {:ok, right} =
             Writer.append(ctx.writer, {:message_end, message("right", native_metadata())})

    assert {:ok, right_snapshot} = execute(ctx.context, "session.status", opted())
    right_directory = right_snapshot.payload["providerHostedResults"]
    assert left_directory["revision"] != right_directory["revision"]

    assert {:error, %{error: %{code: "provider_hosted_results_stale"}}} =
             list(ctx, left_directory)

    assert :ok = Writer.checkout(ctx.writer, left, right)
    assert {:ok, disk} = Log.snapshot(ctx.path)
    assert disk.active_leaf_id == right
    assert {:ok, selected} = execute(ctx.context, "session.status", opted())
    assert selected.payload["activeLeafId"] == left
    assert selected.payload["providerHostedResults"] == left_directory
    assert {:ok, page} = list(ctx, left_directory)
    assert [%{"entryId" => ^left, "messageId" => "left"} = summary] = page.payload["items"]
    assert read_all(ctx, left_directory, summary) == native_metadata()

    for source <- [Map.put(summary, "entryId", right), Map.put(summary, "messageId", "right")] do
      assert {:error, %{error: %{code: "provider_hosted_result_not_found"}}} =
               read(ctx, left_directory, source, 0)
    end

    assert {:error, %{error: %{code: "provider_hosted_results_stale"}}} =
             list(ctx, right_directory)

    foreign = %{ctx.context | repo_path: Path.join(ctx.context.repo_path, "foreign")}

    assert {:error, %{error: %{code: "provider_hosted_results_stale"}}} =
             execute(
               foreign,
               "provider_hosted.list",
               Map.put(opted(), "expectedRevision", left_directory["revision"])
             )

    assert {:ok, wrong_session} =
             Envelope.command("provider_hosted.read", "other", %{
               "requiredCapabilities" => [@capability],
               "expectedRevision" => left_directory["revision"],
               "entryId" => left,
               "messageId" => "left"
             })

    assert {:error, %{error: %{code: "provider_hosted_results_stale"}}} =
             PublicRuntime.execute(wrong_session, ctx.context)
  end

  test "discovery includes selected results older than the bounded snapshot messages", ctx do
    assert {:ok, hosted_id} =
             Writer.append(ctx.writer, {:message_end, message("old", native_metadata())})

    for i <- 1..8,
        do:
          assert(
            {:ok, _} =
              Writer.append(ctx.writer, {:message_end, Message.user("later-#{i}", "later")})
          )

    assert {:ok, snapshot} = execute(ctx.context, "session.status", opted())
    assert snapshot.payload["messagesTruncated"]
    refute Enum.any?(snapshot.payload["messages"], &(&1["id"] == "old"))
    directory = snapshot.payload["providerHostedResults"]
    assert {:ok, page} = list(ctx, directory)
    assert [%{"entryId" => ^hosted_id} = summary] = page.payload["items"]
    assert read_all(ctx, directory, summary) == native_metadata()
  end

  test "stopped sessions expose readable durable results without restarting an Agent", ctx do
    assert {:ok, _} =
             Writer.append(ctx.writer, {:message_end, message("stopped", native_metadata())})

    assert {:ok, active} = execute(ctx.context, "session.status", opted())
    supervisor = Runtime.lookup(ctx.context.repo_path, :supervisor)
    assert :ok = DynamicSupervisor.terminate_child(Sigma.Agent.DynamicSupervisor, supervisor)
    assert Runtime.lookup(ctx.context.repo_path, @session, :agent) == nil
    before = File.read!(ctx.path)
    assert {:ok, stopped} = execute(ctx.context, "session.status", opted())
    directory = stopped.payload["providerHostedResults"]
    assert directory == active.payload["providerHostedResults"]
    assert {:ok, page} = list(ctx, directory)
    assert read_all(ctx, directory, hd(page.payload["items"])) == native_metadata()
    assert Runtime.lookup(ctx.context.repo_path, @session, :agent) == nil
    assert Runtime.lookup(ctx.context.repo_path, @session, :writer) == nil
    assert File.read!(ctx.path) == before
  end

  test "paging mode is explicit, exclusive, and fixed to its subscription", ctx do
    assert {:error, %{error: %{code: "incompatible_protocol_capabilities"}}} =
             execute(ctx.context, "session.status", %{
               "requiredCapabilities" => [@capability, "provider_hosted.v1"]
             })

    assert {:ok, attached} = execute(ctx.context, "subscription.attach", opted())
    id = attached.payload["subscriptionId"]

    for capabilities <- [[], ["provider_hosted.v1"]] do
      assert {:error, %{error: %{code: "subscription_mode_mismatch"}}} =
               execute(ctx.context, "session.status", %{
                 "subscriptionId" => id,
                 "requiredCapabilities" => capabilities
               })
    end

    assert {:ok, _} =
             execute(ctx.context, "session.status", Map.put(opted(), "subscriptionId", id))

    assert Process.alive?(relay(id))

    assert {:error, %{error: %{code: "required_capability_missing"}}} =
             execute(ctx.context, "provider_hosted.list", %{
               "expectedRevision" => String.duplicate("a", 64)
             })

    assert {:ok, legacy} = execute(ctx.context, "subscription.attach")

    assert {:error, %{error: %{code: "subscription_mode_mismatch"}}} =
             execute(
               ctx.context,
               "session.status",
               Map.put(opted(), "subscriptionId", legacy.payload["subscriptionId"])
             )
  end

  test "fork and switch snapshots bind a complete directory to the target session", ctx do
    assert {:ok, _} =
             Writer.append(ctx.writer, {:message_end, message("fork-source", native_metadata())})

    assert {:ok, original} = execute(ctx.context, "session.status", opted())
    target = "hosted-pages-fork"
    assert {:ok, source} = Log.snapshot(ctx.path)

    payload =
      Map.merge(opted(), %{
        "targetSessionId" => target,
        "expectedSourceRevision" => length(source.branch_entry_ids) + 1,
        "expectedSourceLeaf" => source.active_leaf_id
      })

    assert {:ok, forked} = execute(ctx.context, "session.fork", payload)
    assert forked.session_id == target
    assert forked.payload["providerHostedResults"]["resultCount"] == 1

    refute forked.payload["providerHostedResults"]["revision"] ==
             original.payload["providerHostedResults"]["revision"]

    assert {:ok, switched} = execute(ctx.context, "session.switch", payload)
    assert switched.session_id == target
    directory = switched.payload["providerHostedResults"]
    assert directory["resultCount"] == 1
    assert directory["leafId"] == switched.payload["activeLeafId"]

    assert {:ok, command} =
             Envelope.command(
               "provider_hosted.list",
               target,
               Map.put(opted(), "expectedRevision", directory["revision"])
             )

    assert {:ok, page} = PublicRuntime.execute(command, ctx.context)
    assert [%{"messageId" => "fork-source"}] = page.payload["items"]
  end

  test "live paging sends bounded committed-result invalidation without claiming raw frame recovery",
       ctx do
    assert {:ok, attached} = execute(ctx.context, "subscription.attach", opted())
    id = attached.payload["subscriptionId"]
    native = native_metadata()
    msg = message("live", native)

    frame = %{
      "type" => "response.web_search_call.searching",
      "output_index" => 0,
      "item_id" => "search",
      "extra" => String.duplicate("x", 70_000)
    }

    send(relay(id), {:provider_hosted_event, "web_search", frame})
    send(relay(id), {:message_start, msg})
    assert %{payload: %{"message" => %{"id" => "live"}}} = receive_type(id, "message.started")
    refute_receive {:sigma_protocol, ^id, %{type: "provider_hosted.changed"}}, 20
    assert {:ok, _} = Writer.append(ctx.writer, {:message_end, msg})
    send(relay(id), {:message_end, msg})
    completed = receive_type(id, "message.completed")
    refute Map.has_key?(completed.payload["message"], "metadata")
    changed = receive_type(id, "provider_hosted.changed")
    assert changed.payload["snapshotRequired"] == true
    refute Map.has_key?(changed.payload, "entryId")
    refute_receive {:sigma_protocol, ^id, %{type: "provider.hosted"}}, 20

    assert {:ok, snapshot} =
             execute(ctx.context, "session.status", Map.put(opted(), "subscriptionId", id))

    directory = snapshot.payload["providerHostedResults"]
    assert {:ok, page} = list(ctx, directory)
    assert read_all(ctx, directory, hd(page.payload["items"])) == native
  end

  test "invalid complete native metadata fails both snapshot and live paging explicitly", ctx do
    assert {:ok, attached} = execute(ctx.context, "subscription.attach", opted())
    id = attached.payload["subscriptionId"]
    invalid = native_metadata() |> put_in(["origin", "private"], "private-origin-value")
    msg = message("invalid", invalid)
    assert {:ok, _} = Writer.append(ctx.writer, {:message_end, msg})
    assert {:error, error} = execute(ctx.context, "session.status", opted())
    assert error.error.code == "provider_hosted_payload_rejected"
    assert {:ok, encoded} = Codec.encode(error)
    refute encoded =~ "private-origin-value"
    send(relay(id), {:message_end, msg})
    assert receive_type(id, "session.error").error.code == "provider_hosted_payload_rejected"
    refute_receive {:sigma_protocol, ^id, %{type: "provider_hosted.changed"}}, 20
  end

  defp list(ctx, directory),
    do:
      execute(
        ctx.context,
        "provider_hosted.list",
        Map.put(opted(), "expectedRevision", directory["revision"])
      )

  defp read(ctx, directory, summary, offset) do
    execute(
      ctx.context,
      "provider_hosted.read",
      Map.merge(opted(), %{
        "expectedRevision" => directory["revision"],
        "entryId" => summary["entryId"],
        "messageId" => summary["messageId"],
        "byteOffset" => offset
      })
    )
  end

  defp read_all(ctx, directory, summary) do
    chunks =
      Stream.unfold(0, fn
        nil ->
          nil

        offset ->
          assert {:ok, event} = read(ctx, directory, summary, offset)
          assert {:ok, encoded} = Codec.encode(event)
          assert byte_size(encoded) <= 65_536
          assert event.payload["byteOffset"] == offset
          assert event.payload["byteLength"] == summary["byteLength"]
          assert event.payload["sha256"] == summary["sha256"]
          {Base.decode64!(event.payload["data"]), event.payload["nextByteOffset"]}
      end)

    bytes = chunks |> Enum.to_list() |> IO.iodata_to_binary()
    assert byte_size(bytes) == summary["byteLength"]
    assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == summary["sha256"]
    Jason.decode!(bytes)
  end

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

  defp message(id, native) do
    Message.assistant(id, %{
      content: [%{type: :text, text: "Found it"}],
      provider: "fixture",
      model: "fixture",
      timestamp: 1
    })
    |> Map.put(:metadata, %{
      "openai_responses_hosted" => native,
      "private" => "private-host-value"
    })
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
            "type" => "reasoning",
            "id" => "reasoning",
            "summary" => [],
            "encrypted_content" => String.duplicate("opaque", 15_000)
          }
        },
        %{
          "output_index" => 1,
          "item" => %{
            "type" => "web_search_call",
            "id" => "search",
            "status" => "completed",
            "action" => %{"type" => "search", "query" => "source"}
          }
        },
        %{
          "output_index" => 2,
          "item" => %{
            "type" => "message",
            "id" => "native-message",
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
                    "title" => String.duplicate("源", 15_000),
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
end
