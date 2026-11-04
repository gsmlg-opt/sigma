defmodule Sigma.Protocol.PluginInstallations do
  @moduledoc "Bounded plugin request pages and durable installation acknowledgements."

  alias Sigma.Protocol.{Codec, Envelope}

  @common_fields ~w(requiredCapabilities repoPath sessionsDir)

  def validate_request("plugins.requests", payload) when is_map(payload) do
    offset = Map.get(payload, "offset", 0)
    limit = Map.get(payload, "limit", 20)
    revision = payload["expectedRevision"]

    valid? =
      fields?(payload, ~w(offset limit expectedRevision)) and
        is_integer(offset) and offset >= 0 and is_integer(limit) and limit in 1..50 and
        ((offset == 0 and is_nil(revision)) or text?(revision, 512))

    if valid?, do: :ok, else: {:error, :invalid_plugin_request_page}
  end

  def validate_request("plugins.install", payload) when is_map(payload) do
    if fields?(payload, ~w(requestId)) and text?(payload["requestId"], 512),
      do: :ok,
      else: {:error, :invalid_plugin_installation_request}
  end

  def validate_request(_type, _payload), do: {:error, :invalid_plugin_installation_request}

  def page(session_id, %{"items" => items} = payload) when is_list(items) do
    case encoded_event("plugins.requests.page", session_id, payload) do
      {:error, :payload_too_large} when length(items) > 1 ->
        items = Enum.take(items, max(div(length(items), 2), 1))
        next = payload["offset"] + length(items)

        page(
          session_id,
          Map.merge(payload, %{
            "items" => items,
            "nextOffset" => if(next < payload["total"], do: next)
          })
        )

      result ->
        result
    end
  end

  def installed(session_id, %{"status" => "installed"} = receipt) do
    case encoded_event("plugins.installed", session_id, %{"installation" => receipt}) do
      {:error, :payload_too_large} ->
        # The installation already committed. Keep its immutable acknowledgement
        # even when the complete receipt cannot fit Protocol V1's envelope.
        encoded_event("plugins.installed", session_id, %{
          "installation" => Map.take(receipt, ~w(requestId status)),
          "receiptOmitted" => true,
          "receiptError" => "payload_too_large"
        })

      result ->
        result
    end
  end

  defp fields?(payload, allowed),
    do:
      not is_struct(payload) and
        Enum.all?(Map.keys(payload), &(&1 in (allowed ++ @common_fields)))

  defp text?(value, bytes),
    do: is_binary(value) and value != "" and byte_size(value) <= bytes and String.valid?(value)

  defp encoded_event(type, session_id, payload) do
    with {:ok, event} <- Envelope.event(type, session_id, payload),
         {:ok, _encoded} <- Codec.encode(event),
         do: {:ok, event}
  end
end
