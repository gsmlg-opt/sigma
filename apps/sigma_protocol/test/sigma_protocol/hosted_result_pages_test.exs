defmodule Sigma.Protocol.HostedResultPagesTest do
  use ExUnit.Case, async: true

  alias Sigma.Protocol.{Codec, Envelope, HostedResultPages}

  test "empty views bind the trusted session and expose an empty terminal page" do
    view = view([])
    descriptor = descriptor!(view)

    assert descriptor == %{
             "version" => 1,
             "revision" =>
               sha256(~s({"leafId":"leaf","repoPath":"/repo","results":[],"sessionId":"session"})),
             "leafId" => "leaf",
             "resultCount" => 0
           }

    assert list!(view, %{"expectedRevision" => descriptor["revision"]}).payload == %{
             "results" => descriptor,
             "offset" => 0,
             "nextOffset" => nil,
             "items" => []
           }

    assert {:ok, %{payload: %{"items" => []}}} =
             HostedResultPages.list(%{view | leaf_id: nil}, "session", %{
               "expectedRevision" => descriptor!(%{view | leaf_id: nil})["revision"]
             })

    assert {:error, :provider_hosted_payload_rejected} =
             HostedResultPages.descriptor(view, "another-session")

    for session_id <- [nil, 123, "", "  ", <<255>>, String.duplicate("s", 513)] do
      assert {:error, :provider_hosted_payload_rejected} =
               HostedResultPages.descriptor(%{view | session_id: session_id}, session_id)
    end
  end

  test "pages retain selected ancestry order and skip messages without hosted metadata" do
    sources = for index <- 1..73, do: source("entry-#{index}", "message-#{index}")
    ordinary = %{entry_id: "ordinary", message: %{id: "ordinary", role: :user, content: []}}
    view = view(List.insert_at(sources, 3, ordinary))
    descriptor = descriptor!(view)
    assert descriptor["resultCount"] == 73

    summaries = pages!(view, descriptor["revision"], 0)
    assert Enum.map(summaries, & &1["entryId"]) == Enum.map(sources, & &1.entry_id)
    assert Enum.map(summaries, & &1["messageId"]) == Enum.map(sources, & &1.message.id)

    for summary <- summaries do
      assert Enum.sort(Map.keys(summary)) == ~w(byteLength entryId messageId sha256)
      assert summary["byteLength"] > 0
      assert Regex.match?(~r/\A[0-9a-f]{64}\z/, summary["sha256"])
    end

    request = %{
      "expectedRevision" => descriptor["revision"],
      "requiredCapabilities" => ["provider_hosted.pages.v1"],
      "repoPath" => "/repo",
      "sessionsDir" => "/sessions"
    }

    first = list!(view, request)
    assert length(first.payload["items"]) == 20
    assert first.payload["nextOffset"] == 20
    assert list!(view, request).payload == first.payload

    terminal = list!(view, Map.merge(request, %{"offset" => 73, "limit" => 1}))
    assert terminal.payload["items"] == []
    assert terminal.payload["nextOffset"] == nil
  end

  for {name, encrypted_bytes} <- [{"over the wire limit", 70_000}, {"near one MiB", 1_030_000}] do
    @encrypted_bytes encrypted_bytes
    test "#{name} metadata reconstructs complete ordered native envelopes through bounded chunks" do
      source = source("entry", "message", String.duplicate("e", @encrypted_bytes))
      view = view([source])
      descriptor = descriptor!(view)
      page = list!(view, %{"expectedRevision" => descriptor["revision"]})
      assert [summary] = page.payload["items"]
      assert summary["byteLength"] > 65_536
      assert summary["byteLength"] <= 1_048_576
      if @encrypted_bytes > 1_000_000, do: assert(summary["byteLength"] > 1_000_000)

      bytes = chunks!(view, descriptor, summary, 0)
      assert byte_size(bytes) == summary["byteLength"]
      assert sha256(bytes) == summary["sha256"]
      native = source.message.metadata["openai_responses_hosted"]
      assert Jason.decode!(bytes) == native
      assert Enum.map(Jason.decode!(bytes)["items"], & &1["output_index"]) == [0, 1, 2]
      assert_sorted_objects!(Jason.decode!(bytes, objects: :ordered_objects))
      refute bytes =~ "private-host-value"

      request = read_request(descriptor, summary)
      first = read!(view, request)
      assert read!(view, request).payload == first.payload
      assert byte_size(Base.decode64!(first.payload["data"])) == 12_288

      terminal = read!(view, Map.put(request, "byteOffset", byte_size(bytes)))
      assert terminal.payload["data"] == ""
      assert terminal.payload["nextByteOffset"] == nil
    end
  end

  test "revision covers session leaf ordered source identities and complete native metadata" do
    first = source("entry-one", "message-one")
    second = source("entry-two", "message-two")
    view = view([first, second])
    descriptor = descriptor!(view)

    reordered_maps =
      put_in(
        view,
        [:results, Access.at(0), :message, :metadata],
        reverse_maps(first.message.metadata)
      )

    assert descriptor!(reordered_maps) == descriptor

    unrelated = put_in(view, [:results, Access.at(0), :message, :metadata, "private"], "changed")
    assert descriptor!(unrelated) == descriptor

    changed_metadata =
      put_in(
        view,
        [:results, Access.at(0), :message, :metadata, "openai_responses_hosted", "response_id"],
        "new-response"
      )

    for changed <- [
          %{view | repo_path: "/other-repo"},
          %{view | leaf_id: "other-leaf"},
          %{view | results: Enum.reverse(view.results)},
          %{view | results: [second]},
          put_in(view, [:results, Access.at(0), :entry_id], "another-entry"),
          put_in(view, [:results, Access.at(0), :message, :id], "another-message"),
          changed_metadata
        ] do
      refute descriptor!(changed)["revision"] == descriptor["revision"]

      assert {:error, :provider_hosted_results_stale} =
               HostedResultPages.list(changed, "session", %{
                 "expectedRevision" => descriptor["revision"]
               })

      assert {:error, :provider_hosted_results_stale} =
               HostedResultPages.read(changed, "session", %{
                 "expectedRevision" => descriptor["revision"],
                 "entryId" => first.entry_id,
                 "messageId" => first.message.id
               })
    end

    other_session = %{view | session_id: "other-session"}
    assert {:ok, other_descriptor} = HostedResultPages.descriptor(other_session, "other-session")
    refute other_descriptor["revision"] == descriptor["revision"]
  end

  test "source lookup requires the exact entry and message pair in the current selected view" do
    first = source("entry-one", "same-message")
    second = source("entry-two", "same-message", "other-encrypted-content")
    view = view([first, second])
    descriptor = descriptor!(view)
    [summary | _] = list!(view, %{"expectedRevision" => descriptor["revision"]}).payload["items"]
    request = read_request(descriptor, summary)
    assert read!(view, request).payload["entryId"] == first.entry_id

    second_chunk = read!(view, Map.put(request, "entryId", second.entry_id))
    assert second_chunk.payload["entryId"] == second.entry_id
    refute second_chunk.payload["sha256"] == summary["sha256"]

    for changed <- [
          Map.put(request, "entryId", "sibling-entry"),
          Map.put(request, "messageId", "sibling-message"),
          Map.put(request, "entryId", second.entry_id) |> Map.put("messageId", "other-message")
        ] do
      assert {:error, :provider_hosted_result_not_found} =
               HostedResultPages.read(view, "session", changed)
    end

    for {operation, payload} <- [
          {:list, Map.take(request, ["expectedRevision"])},
          {:read, request}
        ] do
      assert {:error, :provider_hosted_payload_rejected} =
               apply(HostedResultPages, operation, [view, "foreign", payload])
    end
  end

  test "native origin content and aggregate bounds are validated before exposing any page" do
    original = source("entry", "message")
    metadata = original.message.metadata["openai_responses_hosted"]

    too_many =
      for index <- 0..128,
          do: %{
            "output_index" => index,
            "item" => %{"type" => "reasoning", "id" => "r-#{index}", "summary" => []}
          }

    for invalid <- [
          put_in(metadata, ["origin", "protocol"], "other"),
          put_in(metadata, ["origin", "endpoint_sha256"], "invalid"),
          put_in(metadata, ["origin", "private"], "private-origin-value"),
          put_in(
            metadata,
            ["items", Access.at(0), "item", "encrypted_content"],
            String.duplicate("x", 1_048_576)
          ),
          Map.put(metadata, "items", too_many)
        ] do
      bad = put_in(original, [:message, :metadata, "openai_responses_hosted"], invalid)

      assert {:error, :provider_hosted_payload_rejected} =
               HostedResultPages.descriptor(view([bad]), "session")

      assert {:error, :provider_hosted_payload_rejected} =
               HostedResultPages.list(view([bad]), "session", %{
                 "expectedRevision" => String.duplicate("a", 64)
               })
    end

    bad_content = put_in(original, [:message, :content], [%{type: :text, text: "changed"}])

    assert {:error, :provider_hosted_payload_rejected} =
             HostedResultPages.descriptor(view([bad_content]), "session")
  end

  test "invalid views IDs duplicate sources and rejected complete metadata return typed errors" do
    source = source("entry", "message")
    view = view([source])
    descriptor = descriptor!(view)

    request = %{
      "expectedRevision" => descriptor["revision"],
      "entryId" => "entry",
      "messageId" => "message"
    }

    invalid_views = [
      nil,
      %{},
      %{view | session_id: "foreign"},
      %{view | session_id: ""},
      %{view | leaf_id: 123},
      %{view | leaf_id: <<255>>},
      %{view | leaf_id: String.duplicate("l", 513)},
      %{view | results: nil},
      %{view | results: [nil]},
      %{view | results: [%{entry_id: "entry", message: nil}]},
      %{view | results: [source, source]},
      %{view | results: [source, %{source | message: %{source.message | id: "another"}}]},
      put_in(view, [:results, Access.at(0), :message, :role], :user),
      put_in(view, [:results, Access.at(0), :message, :content], [%{type: :text, text: "wrong"}]),
      put_in(
        view,
        [:results, Access.at(0), :message, :metadata, "openai_responses_hosted", "version"],
        2
      )
    ]

    invalid_id_views =
      for id <- [nil, 123, "", "  ", <<255>>, String.duplicate("x", 513)],
          field <- [:entry_id, :message_id] do
        case field do
          :entry_id -> put_in(view, [:results, Access.at(0), :entry_id], id)
          :message_id -> put_in(view, [:results, Access.at(0), :message, :id], id)
        end
      end

    for invalid <- invalid_views ++ invalid_id_views do
      assert {:error, :provider_hosted_payload_rejected} =
               HostedResultPages.descriptor(invalid, "session")

      assert {:error, :provider_hosted_payload_rejected} =
               HostedResultPages.list(invalid, "session", Map.take(request, ["expectedRevision"]))

      assert {:error, :provider_hosted_payload_rejected} =
               HostedResultPages.read(invalid, "session", request)
    end
  end

  test "request schemas reject unexpected fields invalid identifiers offsets limits and routing values" do
    view = view([source("entry", "message")])
    descriptor = descriptor!(view)
    list_request = %{"expectedRevision" => descriptor["revision"]}
    read_request = Map.merge(list_request, %{"entryId" => "entry", "messageId" => "message"})
    byte_length = read!(view, read_request).payload["byteLength"]

    for invalid <- [
          %{},
          Map.put(list_request, "expectedRevision", nil),
          Map.put(list_request, "expectedRevision", String.duplicate("A", 64)),
          Map.put(list_request, "offset", -1),
          Map.put(list_request, "offset", 2),
          Map.put(list_request, "offset", 0.0),
          Map.put(list_request, "offset", nil),
          Map.put(list_request, "limit", 0),
          Map.put(list_request, "limit", 51),
          Map.put(list_request, "limit", true),
          Map.put(list_request, "limit", "20"),
          Map.put(list_request, :offset, 0),
          Map.put(list_request, "entryId", "entry"),
          Map.put(list_request, "requiredCapabilities", "not-a-list"),
          Map.put(list_request, "repoPath", false),
          Map.put(list_request, "sessionsDir", nil),
          []
        ] do
      assert {:error, :invalid_provider_hosted_page} =
               HostedResultPages.list(view, "session", invalid)
    end

    for invalid <- [
          %{},
          Map.delete(read_request, "entryId"),
          Map.delete(read_request, "messageId"),
          Map.put(read_request, "entryId", " "),
          Map.put(read_request, "messageId", <<255>>),
          Map.put(read_request, "expectedRevision", "short"),
          Map.put(read_request, "byteOffset", -1),
          Map.put(read_request, "byteOffset", byte_length + 1),
          Map.put(read_request, "byteOffset", 0.0),
          Map.put(read_request, "byteOffset", "0"),
          Map.put(read_request, "byteOffset", nil),
          Map.put(read_request, "limit", 1),
          Map.put(read_request, "extra", true),
          Map.put(read_request, :byteOffset, 0),
          Map.put(read_request, "requiredCapabilities", [<<255>>]),
          %URI{},
          []
        ] do
      assert {:error, :invalid_provider_hosted_page} =
               HostedResultPages.read(view, "session", invalid)
    end

    assert :ok = HostedResultPages.validate_request("provider_hosted.list", list_request)
    assert :ok = HostedResultPages.validate_request("provider_hosted.read", read_request)

    assert :ok =
             HostedResultPages.validate_request(:list, Map.put(list_request, "offset", 99_999))

    assert :ok =
             HostedResultPages.validate_request(
               :read,
               Map.put(read_request, "byteOffset", 99_999)
             )

    assert {:error, :invalid_provider_hosted_page} =
             HostedResultPages.validate_request("provider_hosted.result.read", read_request)
  end

  test "control-byte source identities force adaptive pages using final encoded envelopes" do
    sources =
      for index <- 1..50 do
        id = String.duplicate(<<1>>, 480) <> Integer.to_string(index)
        source("entry:" <> id, "message:" <> id)
      end

    view = view(sources)
    descriptor = descriptor!(view)
    first = list!(view, %{"expectedRevision" => descriptor["revision"], "limit" => 50})
    assert length(first.payload["items"]) in 1..49
    assert first.payload["nextOffset"] == length(first.payload["items"])
    summaries = pages!(view, descriptor["revision"], 0)
    assert Enum.map(summaries, & &1["entryId"]) == Enum.map(sources, & &1.entry_id)
  end

  defp descriptor!(view) do
    assert {:ok, descriptor} = HostedResultPages.descriptor(view, "session")
    descriptor
  end

  defp list!(view, request) do
    assert {:ok, %Envelope{type: "provider_hosted.page"} = event} =
             HostedResultPages.list(view, "session", request)

    wire!(event)
  end

  defp read!(view, request) do
    assert {:ok, %Envelope{type: "provider_hosted.chunk"} = event} =
             HostedResultPages.read(view, "session", request)

    wire!(event)
  end

  defp wire!(event) do
    assert {:ok, encoded} = Codec.encode(event)
    assert byte_size(encoded) <= 65_536
    assert {:ok, decoded} = Codec.decode(encoded)
    assert decoded == event
    decoded
  end

  defp pages!(view, revision, offset) do
    page = list!(view, %{"expectedRevision" => revision, "offset" => offset, "limit" => 50})
    items = page.payload["items"]

    case page.payload["nextOffset"] do
      nil ->
        items

      next ->
        assert items != []
        assert next == offset + length(items)
        items ++ pages!(view, revision, next)
    end
  end

  defp chunks!(view, descriptor, summary, offset) do
    chunk = read!(view, Map.put(read_request(descriptor, summary), "byteOffset", offset))
    payload = chunk.payload
    assert payload["results"] == descriptor
    assert payload["entryId"] == summary["entryId"]
    assert payload["messageId"] == summary["messageId"]
    assert payload["encoding"] == "base64-json"
    assert payload["sha256"] == summary["sha256"]
    assert payload["byteLength"] == summary["byteLength"]
    assert payload["byteOffset"] == offset
    bytes = Base.decode64!(payload["data"])
    assert byte_size(bytes) <= 12_288

    case payload["nextByteOffset"] do
      nil ->
        bytes

      next ->
        assert byte_size(bytes) == 12_288
        assert next == offset + byte_size(bytes)
        bytes <> chunks!(view, descriptor, summary, next)
    end
  end

  defp read_request(descriptor, summary) do
    %{
      "expectedRevision" => descriptor["revision"],
      "entryId" => summary["entryId"],
      "messageId" => summary["messageId"]
    }
  end

  defp view(results),
    do: %{repo_path: "/repo", session_id: "session", leaf_id: "leaf", results: results}

  defp source(entry_id, message_id, encrypted \\ "encrypted-reasoning") do
    native = %{
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
            "status" => "completed",
            "encrypted_content" => encrypted,
            "summary" => [%{"type" => "summary_text", "text" => "  原文\n\"\\  "}]
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
                    "title" => "原文\nSource",
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

    %{
      entry_id: entry_id,
      message: %{
        id: message_id,
        role: :assistant,
        content: [%{type: :text, text: "Found it"}],
        metadata: %{"openai_responses_hosted" => native, "private" => "private-host-value"}
      }
    }
  end

  defp reverse_maps(value) when is_map(value),
    do: value |> Enum.reverse() |> Map.new(fn {key, item} -> {key, reverse_maps(item)} end)

  defp reverse_maps(value) when is_list(value), do: Enum.map(value, &reverse_maps/1)
  defp reverse_maps(value), do: value

  defp assert_sorted_objects!(%Jason.OrderedObject{values: values}) do
    keys = Enum.map(values, &elem(&1, 0))
    assert keys == Enum.sort(keys)
    Enum.each(values, fn {_key, value} -> assert_sorted_objects!(value) end)
  end

  defp assert_sorted_objects!(values) when is_list(values),
    do: Enum.each(values, &assert_sorted_objects!/1)

  defp assert_sorted_objects!(_), do: :ok
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
