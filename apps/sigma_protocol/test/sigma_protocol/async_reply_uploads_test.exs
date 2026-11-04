defmodule Sigma.Protocol.AsyncReplyUploadsTest do
  use ExUnit.Case, async: true

  alias Sigma.Protocol.AsyncReplyUploads

  test "large reply JSON survives byte chunks split inside UTF-8 and repeat commits" do
    reply = %{
      "replyId" => "large-reply",
      "answers" =>
        for(
          index <- 0..2,
          do: %{"questionIndex" => index, "answer" => String.duplicate("原文\n", 3_500)}
        )
    }

    bytes = Jason.encode!(reply)
    assert byte_size(bytes) > 65_536
    binding = upload_binding(bytes)
    {utf8_start, _} = :binary.match(bytes, "原")
    first_size = utf8_start + 1
    refute String.valid?(binary_part(bytes, 0, first_size))

    assert {:ok, state, progress} =
             AsyncReplyUploads.append(
               AsyncReplyUploads.new(),
               chunk(binding, bytes, 0, first_size),
               10
             )

    assert_progress(progress, binding, first_size)
    {state, progress} = append_rest!(state, binding, bytes, first_size, 11)
    assert_progress(progress, binding, byte_size(bytes))
    assert {:ok, ^state, ^reply} = AsyncReplyUploads.reply(state, binding, 12)

    current_leaf = Map.put(binding, "expectedLeafId", "leaf-after-accepted-turn")
    assert {:ok, ^state, ^reply} = AsyncReplyUploads.reply(state, current_leaf, 13)
    assert {:ok, ^state, ^reply} = AsyncReplyUploads.reply(state, current_leaf, 14)

    assert {:ok, _state, repeated} =
             AsyncReplyUploads.append(state, chunk(current_leaf, bytes, 0, first_size), 15)

    assert repeated == progress
    refute Map.has_key?(progress, "reply")
    refute Map.has_key?(progress, "data")
  end

  test "only the next offset or an exact fully contained duplicate is accepted" do
    bytes = Jason.encode!(%{"text" => "abcdef"})
    binding = upload_binding(bytes)
    empty = AsyncReplyUploads.new()

    assert {:error, :async_upload_not_found, ^empty} =
             AsyncReplyUploads.append(empty, chunk(binding, bytes, 4, 2), 0)

    assert {:ok, state, _} = AsyncReplyUploads.append(empty, chunk(binding, bytes, 0, 4), 0)

    for request <- [chunk(binding, bytes, 5, 2), chunk(binding, bytes, 2, 4)] do
      assert {:error, :async_upload_offset, ^state} = AsyncReplyUploads.append(state, request, 1)
    end

    assert {:ok, ^state, duplicate} =
             AsyncReplyUploads.append(state, chunk(binding, bytes, 1, 2), 2)

    assert_progress(duplicate, binding, 4)
    conflict = chunk(binding, bytes, 1, 2) |> Map.put("data", Base.encode64("XX"))
    assert {:error, :async_upload_conflict, ^state} = AsyncReplyUploads.append(state, conflict, 3)
    assert {:error, :async_upload_incomplete, ^state} = AsyncReplyUploads.reply(state, binding, 4)
    {state, _} = append_rest!(state, binding, bytes, 4, 5)
    assert {:ok, _, %{"text" => "abcdef"}} = AsyncReplyUploads.reply(state, binding, 6)
  end

  test "upload item length and checksum are immutable while command leaf fences may change" do
    bytes = Jason.encode!(%{"replyId" => "reply", "text" => "Continue"})
    binding = upload_binding(bytes)

    assert {:ok, state, _} =
             AsyncReplyUploads.append(AsyncReplyUploads.new(), chunk(binding, bytes, 0, 2), 0)

    for changed <- [
          Map.put(binding, "itemId", "other-item"),
          Map.put(binding, "byteLength", byte_size(bytes) + 1),
          Map.put(binding, "sha256", String.duplicate("0", 64))
        ] do
      assert {:error, :async_upload_conflict, ^state} =
               AsyncReplyUploads.append(state, chunk(changed, bytes, 0, 2), 1)

      assert {:error, :async_upload_conflict, ^state} = AsyncReplyUploads.reply(state, changed, 1)
    end

    changed_leaf = Map.put(binding, "expectedLeafId", nil)
    assert {:ok, ^state, _} = AsyncReplyUploads.append(state, chunk(changed_leaf, bytes, 0, 2), 2)
    {state, _} = append_rest!(state, changed_leaf, bytes, 2, 3)

    assert {:ok, _, %{"replyId" => "reply", "text" => "Continue"}} =
             AsyncReplyUploads.reply(state, Map.put(binding, "expectedLeafId", "new-leaf"), 4)
  end

  test "a bad final checksum never accepts the last chunk or consumes a fresh slot" do
    bytes = Jason.encode!(%{"replyId" => "reply", "text" => "Continue"})
    binding = upload_binding(bytes)
    empty = AsyncReplyUploads.new()

    wrong =
      chunk(binding, bytes, 0, byte_size(bytes))
      |> Map.put("data", Base.encode64(String.duplicate("x", byte_size(bytes))))

    assert {:error, :async_upload_hash_mismatch, ^empty} =
             AsyncReplyUploads.append(empty, wrong, 0)

    boundary = byte_size(bytes) - 5

    assert {:ok, state, _} =
             AsyncReplyUploads.append(empty, chunk(binding, bytes, 0, boundary), 1)

    wrong_last = chunk(binding, bytes, boundary, 5) |> Map.put("data", Base.encode64("xxxxx"))

    assert {:error, :async_upload_hash_mismatch, ^state} =
             AsyncReplyUploads.append(state, wrong_last, 2)

    assert {:error, :async_upload_incomplete, ^state} = AsyncReplyUploads.reply(state, binding, 3)

    assert {:ok, state, progress} =
             AsyncReplyUploads.append(state, chunk(binding, bytes, boundary, 5), 4)

    assert_progress(progress, binding, byte_size(bytes))

    assert {:ok, _, %{"replyId" => "reply", "text" => "Continue"}} =
             AsyncReplyUploads.reply(state, binding, 5)
  end

  test "eight uploads fill capacity until cancellation or fixed expiry releases slots" do
    bytes = Jason.encode!(%{"text" => "unfinished"})

    state =
      Enum.reduce(1..8, AsyncReplyUploads.new(), fn index, state ->
        request = chunk(upload_binding(bytes, "upload-#{index}"), bytes, 0, 1)
        assert {:ok, updated, _} = AsyncReplyUploads.append(state, request, 0)
        updated
      end)

    ninth = chunk(upload_binding(bytes, "upload-9"), bytes, 0, 1)
    assert {:error, :async_upload_limit, ^state} = AsyncReplyUploads.append(state, ninth, 1)

    assert {:ok, _, _} =
             AsyncReplyUploads.append(
               state,
               chunk(upload_binding(bytes, "upload-1"), bytes, 0, 1),
               2
             )

    assert {:ok, freed, %{"uploadId" => "upload-1", "status" => "cancelled"}} =
             AsyncReplyUploads.cancel(state, %{"uploadId" => "upload-1"}, 3)

    assert {:ok, _, _} = AsyncReplyUploads.append(freed, ninth, 4)
    assert {:ok, expired, _} = AsyncReplyUploads.append(state, ninth, 300_000)

    assert {:error, :async_upload_not_found, _} =
             AsyncReplyUploads.reply(expired, upload_binding(bytes, "upload-1"), 300_000)
  end

  test "duplicates appends and commits never extend the first chunk deadline" do
    bytes = Jason.encode!(%{"text" => "Continue"})
    binding = upload_binding(bytes)

    assert {:ok, state, _} =
             AsyncReplyUploads.append(AsyncReplyUploads.new(), chunk(binding, bytes, 0, 2), 10)

    assert {:ok, state, _} = AsyncReplyUploads.append(state, chunk(binding, bytes, 0, 2), 300_009)
    {state, _} = append_rest!(state, binding, bytes, 2, 300_009)

    assert {:ok, state, %{"text" => "Continue"}} =
             AsyncReplyUploads.reply(state, binding, 300_009)

    assert {:error, :async_upload_not_found, empty} =
             AsyncReplyUploads.reply(state, binding, 300_010)

    assert empty == AsyncReplyUploads.new()

    assert {:error, :async_upload_not_found, ^empty} =
             AsyncReplyUploads.append(empty, chunk(binding, bytes, 2, 2), 300_011)

    assert {:ok, _, _} = AsyncReplyUploads.append(empty, chunk(binding, bytes, 0, 2), 300_012)
  end

  test "every operation prunes expired entries even when its request is invalid or missing" do
    bytes = Jason.encode!(%{"text" => "Continue"})
    binding = upload_binding(bytes)

    assert {:ok, state, _} =
             AsyncReplyUploads.append(AsyncReplyUploads.new(), chunk(binding, bytes, 0, 1), 0)

    empty = AsyncReplyUploads.new()

    for {operation, request, reason} <- [
          {:append, %{}, :invalid_async_upload},
          {:reply, %{}, :invalid_async_upload},
          {:cancel, %{}, :invalid_async_upload},
          {:reply, binding, :async_upload_not_found}
        ] do
      assert {:error, ^reason, ^empty} =
               apply(AsyncReplyUploads, operation, [state, request, 300_000])
    end

    assert {:ok, ^empty, %{"uploadId" => "missing", "status" => "cancelled"}} =
             AsyncReplyUploads.cancel(state, %{"uploadId" => "missing"}, 300_000)
  end

  test "cancel is idempotent and needs no current card or leaf fence" do
    bytes = Jason.encode!(%{"text" => "Continue"})
    binding = upload_binding(bytes)

    assert {:ok, state, _} =
             AsyncReplyUploads.append(AsyncReplyUploads.new(), chunk(binding, bytes, 0, 1), 0)

    cancel = %{
      "uploadId" => binding["uploadId"],
      "requiredCapabilities" => ["async_interactions.pages.v1"]
    }

    assert {:ok, empty, result} = AsyncReplyUploads.cancel(state, cancel, 1)
    assert result == %{"uploadId" => binding["uploadId"], "status" => "cancelled"}
    assert {:ok, ^empty, ^result} = AsyncReplyUploads.cancel(empty, cancel, 2)
    assert {:error, :async_upload_not_found, ^empty} = AsyncReplyUploads.reply(empty, binding, 3)
  end

  test "complete buffers decode only plain JSON maps and remain available after rejected commits" do
    for bytes <- ["not JSON", "[]", "null", "123", ~s("text"), <<255>>] do
      binding = upload_binding(bytes)

      assert {:ok, state, progress} =
               AsyncReplyUploads.append(
                 AsyncReplyUploads.new(),
                 chunk(binding, bytes, 0, byte_size(bytes)),
                 0
               )

      assert_progress(progress, binding, byte_size(bytes))

      assert {:error, :async_upload_invalid_json, ^state} =
               AsyncReplyUploads.reply(state, binding, 1)

      assert {:error, :async_upload_invalid_json, ^state} =
               AsyncReplyUploads.reply(state, binding, 2)
    end

    key = "unknown_upload_json_key_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    reply = %{key => %{"text" => "原文\n"}}
    bytes = Jason.encode!(reply)
    binding = upload_binding(bytes)

    assert {:ok, state, _} =
             AsyncReplyUploads.append(
               AsyncReplyUploads.new(),
               chunk(binding, bytes, 0, byte_size(bytes)),
               0
             )

    assert {:ok, _, ^reply} = AsyncReplyUploads.reply(state, binding, 1)
    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
  end

  test "raw total and chunk limits include their exact upper boundaries" do
    bytes = String.duplicate("x", 262_144)
    binding = upload_binding(bytes)

    assert :ok =
             AsyncReplyUploads.validate_request(
               "async_interaction.reply_chunk",
               chunk(binding, bytes, 0, 12_288)
             )

    {state, progress} = append_rest!(AsyncReplyUploads.new(), binding, bytes, 0, 0)
    assert_progress(progress, binding, 262_144)
    assert {:error, :async_upload_invalid_json, _} = AsyncReplyUploads.reply(state, binding, 1)
  end

  test "strict command validation rejects malformed types unknown fields and noncanonical base64" do
    bytes = Jason.encode!(%{"text" => "Continue"})
    binding = upload_binding(bytes)
    request = chunk(binding, bytes, 0, 1)
    assert :ok = AsyncReplyUploads.validate_request("async_interaction.reply_chunk", request)
    assert :ok = AsyncReplyUploads.validate_request("async_interaction.reply_commit", binding)

    assert :ok =
             AsyncReplyUploads.validate_request("async_interaction.reply_cancel", %{
               "uploadId" => "upload-1"
             })

    for key <- ~w(uploadId itemId expectedLeafId byteLength sha256 byteOffset data) do
      assert {:error, :invalid_async_upload} =
               AsyncReplyUploads.validate_request(
                 "async_interaction.reply_chunk",
                 Map.delete(request, key)
               )
    end

    invalid = [
      Map.put(request, "uploadId", ""),
      Map.put(request, "uploadId", String.duplicate("u", 513)),
      Map.put(request, "itemId", <<255>>),
      Map.put(request, "expectedLeafId", false),
      Map.put(request, "expectedLeafId", String.duplicate("l", 513)),
      Map.put(request, "byteLength", 0),
      Map.put(request, "byteLength", 262_145),
      Map.put(request, "byteLength", 1.0),
      Map.put(request, "sha256", String.duplicate("A", 64)),
      Map.put(request, "sha256", "short"),
      Map.put(request, "byteOffset", -1),
      Map.put(request, "byteOffset", 0.0),
      Map.put(request, "byteOffset", nil),
      Map.put(request, "byteOffset", byte_size(bytes)),
      Map.put(request, "data", ""),
      Map.put(request, "data", "Zg"),
      Map.put(request, "data", "Zh=="),
      Map.put(request, "data", "Zg==\n"),
      Map.put(request, "data", "____"),
      Map.put(request, "data", true),
      Map.put(request, "data", Base.encode64(String.duplicate("x", 12_289))),
      Map.put(request, "extra", "private"),
      Map.put(request, :byteOffset, 0),
      Map.put(request, "repoPath", false),
      Map.put(request, "requiredCapabilities", "not-a-list"),
      %URI{},
      []
    ]

    for payload <- invalid do
      assert {:error, :invalid_async_upload} =
               AsyncReplyUploads.validate_request("async_interaction.reply_chunk", payload)
    end

    for {type, payload} <- [
          {"async_interactions.reply_chunk", request},
          {"async_interaction.reply_commit", request},
          {"async_interaction.reply_commit", Map.delete(binding, "expectedLeafId")},
          {"async_interaction.reply_cancel", %{"uploadId" => "upload-1", "itemId" => "item-1"}},
          {"async_interaction.reply_cancel", %{"uploadId" => "upload-1", "expectedLeafId" => nil}}
        ] do
      assert {:error, :invalid_async_upload} = AsyncReplyUploads.validate_request(type, payload)
    end

    routed =
      Map.merge(request, %{
        "expectedLeafId" => nil,
        "requiredCapabilities" => ["async_interactions.pages.v1"],
        "repoPath" => "/repo",
        "sessionsDir" => "/sessions"
      })

    assert :ok = AsyncReplyUploads.validate_request("async_interaction.reply_chunk", routed)
  end

  defp append_rest!(state, binding, bytes, offset, now) do
    size = min(12_288, byte_size(bytes) - offset)
    assert size > 0

    assert {:ok, state, progress} =
             AsyncReplyUploads.append(state, chunk(binding, bytes, offset, size), now)

    if offset + size == byte_size(bytes),
      do: {state, progress},
      else: append_rest!(state, binding, bytes, offset + size, now)
  end

  defp assert_progress(progress, binding, received) do
    complete? = received == binding["byteLength"]

    assert progress == %{
             "uploadId" => binding["uploadId"],
             "itemId" => binding["itemId"],
             "byteLength" => binding["byteLength"],
             "receivedBytes" => received,
             "nextByteOffset" => if(complete?, do: nil, else: received),
             "status" => if(complete?, do: "complete", else: "receiving")
           }
  end

  defp upload_binding(bytes, upload_id \\ "upload-1") do
    %{
      "uploadId" => upload_id,
      "itemId" => "item-1",
      "expectedLeafId" => "leaf-1",
      "byteLength" => byte_size(bytes),
      "sha256" => :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    }
  end

  defp chunk(binding, bytes, offset, size),
    do:
      Map.merge(binding, %{
        "byteOffset" => offset,
        "data" => Base.encode64(binary_part(bytes, offset, size))
      })
end
