defmodule Sigma.Protocol.Codec do
  @moduledoc "Bounded JSON codec for Protocol V1 envelopes."

  alias Sigma.Protocol.{Envelope, Error}

  @max_encoded_bytes 65_536
  @version Envelope.version()
  # Structured native calls include message/content/arguments before their own
  # question/options containers; retain those values within a finite budget.
  @max_depth 16
  @max_collection_size 200
  @max_string_bytes 32_768

  def encode(%Envelope{} = envelope) do
    with {:ok, document} <- envelope_document(envelope),
         {:ok, encoded} <- Jason.encode(document),
         true <- byte_size(encoded) <= @max_encoded_bytes do
      {:ok, encoded}
    else
      false -> {:error, :payload_too_large}
      {:error, _reason} = error -> error
    end
  end

  def encode(_envelope), do: {:error, :invalid_envelope}

  def decode(encoded) when is_binary(encoded) and byte_size(encoded) <= @max_encoded_bytes do
    with {:ok, document} when is_map(document) <- Jason.decode(encoded),
         :ok <- validate_version(document["version"]),
         {:ok, kind, type} <- validate_type(document["kind"], document["type"]),
         :ok <- validate_required_strings(document),
         :ok <- validate_timestamp(document["timestamp"]),
         {:ok, payload} <- validate_payload(document["payload"]),
         :ok <- validate_command_payload(type, payload),
         {:ok, error} <- decode_error(document["error"]) do
      {:ok,
       %Envelope{
         version: @version,
         id: document["id"],
         session_id: document["sessionId"],
         turn_id: document["turnId"],
         timestamp: document["timestamp"],
         type: type,
         kind: kind,
         payload: payload,
         error: error
       }}
    else
      {:ok, _other} -> {:error, :invalid_envelope}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_envelope}
    end
  end

  def decode(encoded) when is_binary(encoded), do: {:error, :payload_too_large}
  def decode(_encoded), do: {:error, :invalid_json}

  defp envelope_document(envelope) do
    with {:ok, payload} <- sanitize(envelope.payload, 0),
         :ok <- validate_command_payload(envelope.type, payload),
         {:ok, error} <- encode_error(envelope.error),
         :ok <- validate_envelope(envelope) do
      {:ok,
       %{
         "version" => envelope.version,
         "id" => envelope.id,
         "sessionId" => envelope.session_id,
         "turnId" => envelope.turn_id,
         "timestamp" => envelope.timestamp,
         "kind" => Atom.to_string(envelope.kind),
         "type" => envelope.type,
         "payload" => payload,
         "error" => error
       }}
    end
  end

  defp validate_envelope(%Envelope{} = envelope) do
    with :ok <- validate_version(envelope.version),
         {:ok, _kind, _type} <- validate_type(envelope.kind, envelope.type),
         true <- is_binary(envelope.id) and envelope.id != "",
         true <- is_binary(envelope.session_id) and envelope.session_id != "",
         true <- is_nil(envelope.turn_id) or is_binary(envelope.turn_id),
         :ok <- validate_timestamp(envelope.timestamp) do
      :ok
    else
      false -> {:error, :invalid_envelope}
      {:error, _reason} = error -> error
    end
  end

  defp validate_version(@version), do: :ok
  defp validate_version(version), do: {:error, {:unsupported_version, version}}

  defp validate_type(kind, type) when kind in [:command, "command"] do
    if type in Envelope.commands(),
      do: {:ok, :command, type},
      else: {:error, {:unknown_type, type}}
  end

  defp validate_type(kind, type) when kind in [:event, "event"] do
    if type in Envelope.events(),
      do: {:ok, :event, type},
      else: {:error, {:unknown_type, type}}
  end

  defp validate_type(_kind, _type), do: {:error, :invalid_kind}

  defp validate_required_strings(document) do
    valid? =
      is_binary(document["id"]) and document["id"] != "" and
        is_binary(document["sessionId"]) and document["sessionId"] != "" and
        (is_nil(document["turnId"]) or is_binary(document["turnId"]))

    if valid?, do: :ok, else: {:error, :invalid_envelope}
  end

  defp validate_timestamp(timestamp) when is_integer(timestamp), do: :ok
  defp validate_timestamp(_timestamp), do: {:error, :invalid_timestamp}

  defp validate_payload(nil), do: {:ok, %{}}
  defp validate_payload(payload) when is_map(payload), do: {:ok, payload}
  defp validate_payload(_payload), do: {:error, :invalid_payload}

  defp validate_command_payload(type, payload)
       when type in ~w(plugins.requests plugins.install),
       do: Sigma.Protocol.PluginInstallations.validate_request(type, payload)

  defp validate_command_payload(type, payload)
       when type in ~w(provider_hosted.list provider_hosted.read),
       do: Sigma.Protocol.HostedResultPages.validate_request(type, payload)

  defp validate_command_payload(type, payload)
       when type in ~w(async_interaction.reply_chunk async_interaction.reply_commit async_interaction.reply_cancel),
       do: Sigma.Protocol.AsyncReplyUploads.validate_request(type, payload)

  defp validate_command_payload(type, payload)
       when type in ~w(async_interactions.list async_interaction.read),
       do: Sigma.Protocol.AsyncInteractionPages.validate_request(type, payload)

  defp validate_command_payload(type, payload)
       when type in ~w(async_interaction.reply async_interaction.dismiss) do
    required = ~w(itemId expectedLeafId)
    required = if type == "async_interaction.reply", do: required ++ ["reply"], else: required
    allowed = required ++ ~w(requiredCapabilities repoPath sessionsDir)

    valid? =
      Enum.all?(required, &Map.has_key?(payload, &1)) and
        Enum.all?(Map.keys(payload), &(&1 in allowed)) and
        async_text?(payload["itemId"], 512) and
        (is_nil(payload["expectedLeafId"]) or async_text?(payload["expectedLeafId"], 512)) and
        (type == "async_interaction.dismiss" or async_reply?(payload["reply"]))

    if valid?, do: :ok, else: {:error, :invalid_async_interaction_command}
  end

  defp validate_command_payload(_, _), do: :ok

  defp async_reply?(%{"replyId" => id, "answers" => answers} = reply)
       when map_size(reply) == 2 and is_list(answers) and length(answers) in 1..32 do
    async_text?(id, 512) and
      Enum.all?(Enum.with_index(answers), fn
        {%{"questionIndex" => index, "answer" => answer} = row, index} when map_size(row) == 2 ->
          async_text?(answer, 32_768)

        _ ->
          false
      end)
  end

  defp async_reply?(%{"replyId" => id, "text" => text} = reply) when map_size(reply) == 2,
    do: async_text?(id, 512) and async_text?(text, 32_768)

  defp async_reply?(_), do: false

  defp async_text?(text, limit),
    do:
      is_binary(text) and byte_size(text) <= limit and String.valid?(text) and
        String.trim(text) != ""

  defp encode_error(nil), do: {:ok, nil}

  defp encode_error(%Error{} = error) do
    with {:ok, details} <- sanitize(error.details, 0) do
      {:ok, %{"code" => error.code, "message" => error.message, "details" => details}}
    end
  end

  defp encode_error(_error), do: {:error, :invalid_error}

  defp decode_error(nil), do: {:ok, nil}

  defp decode_error(%{"code" => code, "message" => message} = error)
       when is_binary(code) and is_binary(message) do
    details = Map.get(error, "details", %{})

    if is_map(details),
      do: {:ok, Error.new(code, message, details)},
      else: {:error, :invalid_error}
  end

  defp decode_error(_error), do: {:error, :invalid_error}

  defp sanitize(_value, depth) when depth > @max_depth, do: {:error, :payload_too_deep}
  defp sanitize(nil, _depth), do: {:ok, nil}
  defp sanitize(value, _depth) when is_boolean(value) or is_number(value), do: {:ok, value}

  defp sanitize(value, _depth) when is_binary(value) do
    if byte_size(value) <= @max_string_bytes,
      do: {:ok, value},
      else: {:error, :payload_too_large}
  end

  defp sanitize(value, _depth) when is_atom(value), do: {:ok, Atom.to_string(value)}

  defp sanitize(value, depth) when is_list(value) do
    if length(value) <= @max_collection_size do
      map_sanitized(value, depth + 1)
    else
      {:error, :payload_too_large}
    end
  end

  defp sanitize(%_struct{}, _depth), do: {:error, :unsafe_payload}

  defp sanitize(value, depth) when is_map(value) do
    if map_size(value) <= @max_collection_size do
      Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, acc} ->
        with {:ok, key} <- sanitize_key(key),
             {:ok, item} <- sanitize(item, depth + 1) do
          {:cont, {:ok, Map.put(acc, key, item)}}
        else
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    else
      {:error, :payload_too_large}
    end
  end

  defp sanitize(_value, _depth), do: {:error, :unsafe_payload}

  defp sanitize_key(key) when is_binary(key), do: {:ok, key}
  defp sanitize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp sanitize_key(_key), do: {:error, :unsafe_payload}

  defp map_sanitized(values, depth) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case sanitize(value, depth) do
        {:ok, sanitized} -> {:cont, {:ok, [sanitized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _reason} = error -> error
    end
  end
end
