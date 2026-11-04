defmodule Sigma.Protocol.AsyncInteractionPages do
  @moduledoc "Bounded, revision-checked pages over a complete selected async inbox."

  alias Sigma.Protocol.{AsyncInteractions, Codec, Envelope}

  @chunk_bytes 12_288
  @common_fields ~w(requiredCapabilities repoPath sessionsDir)

  def descriptor(snapshot, session_id) do
    with {:ok, {_view, descriptor}} <- prepare(snapshot, session_id), do: {:ok, descriptor}
  end

  def list(snapshot, session_id, request) do
    with {:ok, {view, descriptor}} <- prepare(snapshot, session_id),
         :ok <- validate_request(:list, request),
         :ok <- current_revision(descriptor, request),
         offset = Map.get(request, "offset", 0),
         true <- offset <= descriptor["itemCount"],
         {:ok, summaries} <-
           view["items"]
           |> Enum.slice(offset, Map.get(request, "limit", 20))
           |> summaries() do
      page(session_id, descriptor, offset, summaries)
    else
      false -> {:error, :invalid_async_page}
      {:error, _} = error -> error
    end
  end

  def read(snapshot, session_id, request) do
    with {:ok, {view, descriptor}} <- prepare(snapshot, session_id),
         :ok <- validate_request(:read, request),
         :ok <- current_revision(descriptor, request),
         {:ok, item} <- find_item(view["items"], request["itemId"]),
         {:ok, bytes} <- json(item),
         offset = Map.get(request, "byteOffset", 0),
         true <- offset <= byte_size(bytes) do
      size = min(@chunk_bytes, byte_size(bytes) - offset)
      next = offset + size

      encoded_event("async_interaction.chunk", session_id, %{
        "inbox" => descriptor,
        "itemId" => item["item_id"],
        "encoding" => "base64-json",
        "sha256" => sha256(bytes),
        "byteLength" => byte_size(bytes),
        "byteOffset" => offset,
        "nextByteOffset" => if(next < byte_size(bytes), do: next),
        "data" => Base.encode64(binary_part(bytes, offset, size))
      })
    else
      false -> {:error, :invalid_async_page}
      {:error, _} = error -> error
    end
  end

  def validate_request("async_interactions.list", payload), do: validate_request(:list, payload)
  def validate_request("async_interaction.read", payload), do: validate_request(:read, payload)

  def validate_request(type, payload)
      when type in [:list, :read] and is_map(payload) and not is_struct(payload) do
    fields =
      case type do
        :list -> ~w(expectedRevision offset limit)
        :read -> ~w(expectedRevision itemId byteOffset)
      end

    valid? =
      Enum.all?(Map.keys(payload), &(&1 in (fields ++ @common_fields))) and
        revision?(payload["expectedRevision"]) and valid_common?(payload) and
        case type do
          :list ->
            nonnegative_integer?(Map.get(payload, "offset", 0)) and
              is_integer(Map.get(payload, "limit", 20)) and
              Map.get(payload, "limit", 20) in 1..50

          :read ->
            text?(payload["itemId"], 512) and
              nonnegative_integer?(Map.get(payload, "byteOffset", 0))
        end

    if valid?, do: :ok, else: {:error, :invalid_async_page}
  end

  def validate_request(_type, _payload), do: {:error, :invalid_async_page}

  defp prepare(snapshot, session_id) do
    with {:ok, view} <- AsyncInteractions.project(snapshot, session_id),
         {:ok, bytes} <- json(view) do
      {:ok,
       {view,
        %{
          "version" => 1,
          "revision" => sha256(bytes),
          "leafId" => view["leafId"],
          "itemCount" => length(view["items"])
        }}}
    end
  end

  defp summaries(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case json(item) do
        {:ok, bytes} ->
          summary = %{
            "itemId" => item["item_id"],
            "sequence" => item["sequence"],
            "kind" => if(Map.has_key?(item, "questions"), do: "questions", else: "message"),
            "status" => item["status"],
            "canReply" => item["can_reply"],
            "byteLength" => byte_size(bytes),
            "sha256" => sha256(bytes)
          }

          {:cont, {:ok, [summary | acc]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp page(session_id, descriptor, offset, summaries) do
    next = offset + length(summaries)

    result =
      encoded_event("async_interactions.page", session_id, %{
        "inbox" => descriptor,
        "offset" => offset,
        "nextOffset" => if(next < descriptor["itemCount"], do: next),
        "items" => summaries
      })

    case result do
      {:error, :payload_too_large} when length(summaries) > 1 ->
        page(session_id, descriptor, offset, Enum.drop(summaries, -1))

      result ->
        result
    end
  end

  defp encoded_event(type, session_id, payload) do
    with {:ok, event} <- Envelope.event(type, session_id, payload),
         {:ok, _encoded} <- Codec.encode(event),
         do: {:ok, event}
  end

  defp find_item(items, item_id) do
    case Enum.find(items, &(&1["item_id"] == item_id)) do
      nil -> {:error, :async_item_not_found}
      item -> {:ok, item}
    end
  end

  defp current_revision(%{"revision" => revision}, %{"expectedRevision" => revision}), do: :ok
  defp current_revision(_descriptor, _request), do: {:error, :async_inbox_stale}

  defp json(value) do
    case Jason.encode(ordered(value)) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _} -> {:error, :async_payload_rejected}
    end
  end

  defp ordered(value) when is_map(value) do
    value
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {key, item} -> {key, ordered(item)} end)
    |> Jason.OrderedObject.new()
  end

  defp ordered(value) when is_list(value), do: Enum.map(value, &ordered/1)
  defp ordered(value), do: value

  defp valid_common?(payload) do
    Enum.all?(@common_fields, fn field ->
      case Map.fetch(payload, field) do
        :error ->
          true

        {:ok, values} when field == "requiredCapabilities" ->
          is_list(values) and Enum.all?(values, &text?(&1, 32_768))

        {:ok, value} ->
          text?(value, 32_768)
      end
    end)
  end

  defp revision?(value),
    do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp nonnegative_integer?(value), do: is_integer(value) and value >= 0

  defp text?(value, limit),
    do:
      is_binary(value) and byte_size(value) <= limit and String.valid?(value) and
        String.trim(value) != ""

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
