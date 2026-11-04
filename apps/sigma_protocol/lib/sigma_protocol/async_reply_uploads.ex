defmodule Sigma.Protocol.AsyncReplyUploads do
  @moduledoc """
  Bounded temporary reply bytes owned by one Agent, without persistence or effects.

  Completed uploads remain available until cancellation or their original deadline
  so the durable reply path can acknowledge retries. The caller authenticates the
  current item and leaf on each mutation; a leaf is not part of an upload binding.
  """

  @max_uploads 8
  @max_bytes 262_144
  @chunk_bytes 12_288
  @lifetime_ms 300_000
  @binding_fields ~w(uploadId itemId byteLength sha256)
  @reply_fields @binding_fields ++ ~w(expectedLeafId)
  @chunk_fields @reply_fields ++ ~w(byteOffset data)
  @common_fields ~w(requiredCapabilities repoPath sessionsDir)

  def new, do: %{}

  def append(state, request, now_ms) do
    state = prune(state, now_ms)

    with :ok <- validate_request("async_interaction.reply_chunk", request),
         {:ok, upload} <- upload_for_append(state, request, now_ms),
         :ok <- same_binding(upload, request),
         {:ok, bytes} <- append_bytes(upload.bytes, request),
         :ok <- verify_complete(bytes, request) do
      upload = %{upload | bytes: bytes}
      {:ok, Map.put(state, request["uploadId"], upload), progress(upload)}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def reply(state, request, now_ms) do
    state = prune(state, now_ms)

    with :ok <- validate_request("async_interaction.reply_commit", request),
         {:ok, upload} <- find_upload(state, request["uploadId"]),
         :ok <- same_binding(upload, request),
         :ok <- complete(upload),
         {:ok, reply} <- decode_reply(upload.bytes) do
      {:ok, state, reply}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  def cancel(state, request, now_ms) do
    state = prune(state, now_ms)

    case validate_request("async_interaction.reply_cancel", request) do
      :ok ->
        {:ok, Map.delete(state, request["uploadId"]),
         %{"uploadId" => request["uploadId"], "status" => "cancelled"}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  def validate_request(type, request) when is_map(request) and not is_struct(request) do
    valid? =
      case type do
        "async_interaction.reply_chunk" ->
          fields?(request, @chunk_fields) and binding?(request) and chunk?(request)

        "async_interaction.reply_commit" ->
          fields?(request, @reply_fields) and binding?(request)

        "async_interaction.reply_cancel" ->
          fields?(request, ["uploadId"]) and text?(request["uploadId"], 512)

        _ ->
          false
      end

    if valid?, do: :ok, else: {:error, :invalid_async_upload}
  end

  def validate_request(_type, _request), do: {:error, :invalid_async_upload}

  defp prune(state, now_ms),
    do: Map.reject(state, fn {_id, upload} -> upload.expires_at <= now_ms end)

  defp upload_for_append(state, request, now_ms) do
    case Map.fetch(state, request["uploadId"]) do
      {:ok, upload} ->
        {:ok, upload}

      :error ->
        cond do
          request["byteOffset"] != 0 ->
            {:error, :async_upload_not_found}

          map_size(state) >= @max_uploads ->
            {:error, :async_upload_limit}

          true ->
            {:ok,
             %{
               binding: Map.take(request, @binding_fields),
               bytes: "",
               expires_at: now_ms + @lifetime_ms
             }}
        end
    end
  end

  defp find_upload(state, id) do
    case Map.fetch(state, id) do
      {:ok, upload} -> {:ok, upload}
      :error -> {:error, :async_upload_not_found}
    end
  end

  defp same_binding(upload, request) do
    if upload.binding == Map.take(request, @binding_fields),
      do: :ok,
      else: {:error, :async_upload_conflict}
  end

  defp append_bytes(bytes, request) do
    data = Base.decode64!(request["data"])
    offset = request["byteOffset"]
    received = byte_size(bytes)

    cond do
      offset == received ->
        {:ok, bytes <> data}

      offset + byte_size(data) <= received ->
        if binary_part(bytes, offset, byte_size(data)) == data,
          do: {:ok, bytes},
          else: {:error, :async_upload_conflict}

      true ->
        {:error, :async_upload_offset}
    end
  end

  defp verify_complete(bytes, request) do
    if byte_size(bytes) == request["byteLength"] and sha256(bytes) != request["sha256"],
      do: {:error, :async_upload_hash_mismatch},
      else: :ok
  end

  defp complete(upload) do
    if byte_size(upload.bytes) == upload.binding["byteLength"],
      do: :ok,
      else: {:error, :async_upload_incomplete}
  end

  defp decode_reply(bytes) do
    case Jason.decode(bytes) do
      {:ok, reply} when is_map(reply) -> {:ok, reply}
      _ -> {:error, :async_upload_invalid_json}
    end
  end

  defp progress(upload) do
    received = byte_size(upload.bytes)
    complete? = received == upload.binding["byteLength"]

    %{
      "uploadId" => upload.binding["uploadId"],
      "itemId" => upload.binding["itemId"],
      "byteLength" => upload.binding["byteLength"],
      "receivedBytes" => received,
      "nextByteOffset" => if(complete?, do: nil, else: received),
      "status" => if(complete?, do: "complete", else: "receiving")
    }
  end

  defp fields?(request, required) do
    Enum.all?(required, &Map.has_key?(request, &1)) and
      Enum.all?(Map.keys(request), &(&1 in (required ++ @common_fields))) and
      valid_common?(request)
  end

  defp binding?(request) do
    text?(request["uploadId"], 512) and text?(request["itemId"], 512) and
      (is_nil(request["expectedLeafId"]) or text?(request["expectedLeafId"], 512)) and
      is_integer(request["byteLength"]) and request["byteLength"] in 1..@max_bytes and
      is_binary(request["sha256"]) and byte_size(request["sha256"]) == 64 and
      Regex.match?(~r/\A[0-9a-f]{64}\z/, request["sha256"])
  end

  defp chunk?(request) do
    is_integer(request["byteOffset"]) and request["byteOffset"] >= 0 and
      case decoded_chunk(request["data"]) do
        {:ok, bytes} -> request["byteOffset"] + byte_size(bytes) <= request["byteLength"]
        :error -> false
      end
  end

  defp decoded_chunk(data) when is_binary(data) and byte_size(data) <= 16_384 do
    case Base.decode64(data) do
      {:ok, bytes} when byte_size(bytes) in 1..@chunk_bytes ->
        if Base.encode64(bytes) == data, do: {:ok, bytes}, else: :error

      _ ->
        :error
    end
  end

  defp decoded_chunk(_data), do: :error

  defp valid_common?(request) do
    Enum.all?(@common_fields, fn field ->
      case Map.fetch(request, field) do
        :error ->
          true

        {:ok, values} when field == "requiredCapabilities" ->
          is_list(values) and Enum.all?(values, &text?(&1, 32_768))

        {:ok, value} ->
          text?(value, 32_768)
      end
    end)
  end

  defp text?(value, limit),
    do:
      is_binary(value) and byte_size(value) <= limit and String.valid?(value) and
        String.trim(value) != ""

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
