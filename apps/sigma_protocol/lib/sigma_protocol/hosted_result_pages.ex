defmodule Sigma.Protocol.HostedResultPages do
  @moduledoc "Bounded, revision-checked reads of complete selected native hosted results."

  alias Sigma.Ai.Providers.OpenAIResponses.Hosted
  alias Sigma.Protocol.{Codec, Envelope}

  @chunk_bytes 12_288
  @common_fields ~w(requiredCapabilities repoPath sessionsDir)

  def descriptor(view, session_id) do
    with {:ok, {_results, descriptor}} <- prepare(view, session_id), do: {:ok, descriptor}
  end

  def list(view, session_id, request) do
    with {:ok, {results, descriptor}} <- prepare(view, session_id),
         :ok <- validate_request(:list, request),
         :ok <- current_revision(descriptor, request),
         offset = Map.get(request, "offset", 0),
         true <- offset <= descriptor["resultCount"] do
      summaries =
        results
        |> Enum.slice(offset, Map.get(request, "limit", 20))
        |> Enum.map(& &1.summary)

      page(session_id, descriptor, offset, summaries)
    else
      false -> {:error, :invalid_provider_hosted_page}
      {:error, _} = error -> error
    end
  end

  def read(view, session_id, request) do
    with {:ok, {results, descriptor}} <- prepare(view, session_id),
         :ok <- validate_request(:read, request),
         :ok <- current_revision(descriptor, request),
         {:ok, result} <- find_result(results, request),
         offset = Map.get(request, "byteOffset", 0),
         true <- offset <= byte_size(result.bytes) do
      size = min(@chunk_bytes, byte_size(result.bytes) - offset)
      next = offset + size

      encoded_event(
        "provider_hosted.chunk",
        session_id,
        Map.merge(result.summary, %{
          "results" => descriptor,
          "encoding" => "base64-json",
          "byteOffset" => offset,
          "nextByteOffset" => if(next < byte_size(result.bytes), do: next),
          "data" => Base.encode64(binary_part(result.bytes, offset, size))
        })
      )
    else
      false -> {:error, :invalid_provider_hosted_page}
      {:error, _} = error -> error
    end
  end

  def validate_request("provider_hosted.list", payload), do: validate_request(:list, payload)
  def validate_request("provider_hosted.read", payload), do: validate_request(:read, payload)

  def validate_request(type, payload)
      when type in [:list, :read] and is_map(payload) and not is_struct(payload) do
    fields =
      case type do
        :list -> ~w(expectedRevision offset limit)
        :read -> ~w(expectedRevision entryId messageId byteOffset)
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
            text?(payload["entryId"], 512) and text?(payload["messageId"], 512) and
              nonnegative_integer?(Map.get(payload, "byteOffset", 0))
        end

    if valid?, do: :ok, else: {:error, :invalid_provider_hosted_page}
  end

  def validate_request(_type, _payload), do: {:error, :invalid_provider_hosted_page}

  defp prepare(
         %{repo_path: repo, session_id: session_id, leaf_id: leaf, results: sources} = view,
         session_id
       )
       when is_list(sources) and not is_struct(view) do
    with true <-
           text?(repo, 32_768) and text?(session_id, 512) and (is_nil(leaf) or text?(leaf, 512)),
         {:ok, results} <- prepare_sources(sources),
         {:ok, bytes} <-
           json(%{
             "sessionId" => session_id,
             "repoPath" => repo,
             "leafId" => leaf,
             "results" => Enum.map(results, & &1.summary)
           }) do
      {:ok,
       {results,
        %{
          "version" => 1,
          "revision" => sha256(bytes),
          "leafId" => leaf,
          "resultCount" => length(results)
        }}}
    else
      _ -> {:error, :provider_hosted_payload_rejected}
    end
  end

  defp prepare(_view, _session_id), do: {:error, :provider_hosted_payload_rejected}

  defp prepare_sources(sources) do
    sources
    |> Enum.reduce_while({:ok, [], MapSet.new(), MapSet.new()}, fn source,
                                                                   {:ok, results, entries, pairs} ->
      with %{entry_id: entry_id, message: message} <- source,
           true <- is_map(message) and text?(entry_id, 512) and text?(Map.get(message, :id), 512),
           pair = {entry_id, message.id},
           false <- MapSet.member?(entries, entry_id) or MapSet.member?(pairs, pair),
           {:ok, result} <- prepare_source(message, entry_id) do
        results = if is_nil(result), do: results, else: [result | results]

        {:cont, {:ok, results, MapSet.put(entries, entry_id), MapSet.put(pairs, pair)}}
      else
        _ -> {:halt, {:error, :provider_hosted_payload_rejected}}
      end
    end)
    |> case do
      {:ok, results, _entries, _pairs} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp prepare_source(message, entry_id) do
    case Hosted.project_metadata(message) do
      {:ok, metadata} ->
        with {:ok, bytes} <- json(metadata) do
          {:ok,
           %{
             bytes: bytes,
             summary: %{
               "entryId" => entry_id,
               "messageId" => message.id,
               "byteLength" => byte_size(bytes),
               "sha256" => sha256(bytes)
             }
           }}
        end

      :none ->
        {:ok, nil}

      {:error, _} ->
        {:error, :provider_hosted_payload_rejected}
    end
  end

  defp page(session_id, descriptor, offset, summaries) do
    next = offset + length(summaries)

    result =
      encoded_event("provider_hosted.page", session_id, %{
        "results" => descriptor,
        "offset" => offset,
        "nextOffset" => if(next < descriptor["resultCount"], do: next),
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

  defp find_result(results, request) do
    case Enum.find(results, fn %{summary: summary} ->
           summary["entryId"] == request["entryId"] and
             summary["messageId"] == request["messageId"]
         end) do
      nil -> {:error, :provider_hosted_result_not_found}
      result -> {:ok, result}
    end
  end

  defp current_revision(%{"revision" => revision}, %{"expectedRevision" => revision}), do: :ok
  defp current_revision(_descriptor, _request), do: {:error, :provider_hosted_results_stale}

  defp json(value) do
    case Jason.encode(ordered(value)) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _} -> {:error, :provider_hosted_payload_rejected}
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
