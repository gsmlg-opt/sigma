defmodule Sigma.Session.HookFeedback do
  @moduledoc """
  Pure durable host facts for asynchronous PostToolUse feedback.

  These facts are separate from user interaction cards and Runtime receipts.
  The Writer owns session/branch authentication and durable append; the host
  owns proof of admission and canonical message consumption. This reducer never
  schedules delivery. Replaying an old fact cannot make an uncertain or terminal
  item eligible for dispatch again.
  """

  @common ~w(version fact event_id item_id session_id)
  @origin ~w(run_id incarnation turn_id step_id attempt_id invocation_id tool_call_id tool_name branch_entry_id handler_index handler_digest)
  @delivery ~w(message_id turn_id mode)
  @facts ~w(received dispatch_started admitted consumed delivery_unknown discarded)
  @max_event_bytes 458_752

  def new, do: %{version: 1, items: %{}, events: %{}}

  def received(session_id, origin, text) do
    if text?(session_id, 512) and valid_origin?(origin) and text?(text, 65_536) do
      item_id = item_id(session_id, origin)

      event(%{
        "version" => 1,
        "fact" => "received",
        "event_id" => event_id(item_id, "received"),
        "item_id" => item_id,
        "session_id" => session_id,
        "origin" => origin,
        "text" => text
      })
    else
      {:error, :invalid_hook_feedback}
    end
  end

  def fact(item, name, attrs \\ %{})

  def fact(item, name, attrs)
      when is_map(item) and not is_struct(item) and is_map(attrs) and not is_struct(attrs) do
    if valid_item_identity?(item) and name in (@facts -- ["received"]) and
         valid_attrs?(name, attrs) do
      event(
        Map.merge(attrs, %{
          "version" => 1,
          "fact" => name,
          "event_id" => event_id(item["item_id"], name),
          "item_id" => item["item_id"],
          "session_id" => item["session_id"]
        })
      )
    else
      {:error, :invalid_hook_feedback}
    end
  end

  def fact(_, _, _), do: {:error, :invalid_hook_feedback}

  def event(value) when is_map(value) and not is_struct(value) do
    with true <- value["version"] === 1 and value["fact"] in @facts,
         true <- text?(value["session_id"], 512),
         true <- valid_item_id?(value["item_id"]),
         true <- value["event_id"] == event_id(value["item_id"], value["fact"]),
         true <- valid_fact?(value),
         {:ok, encoded} <- Jason.encode(value),
         true <- byte_size(encoded) <= @max_event_bytes do
      {:ok, value}
    else
      _ -> {:error, :invalid_hook_feedback}
    end
  end

  def event(_), do: {:error, :invalid_hook_feedback}

  def apply_event(%{version: 1, items: items, events: events} = state, value)
      when is_map(items) and is_map(events) do
    with {:ok, value} <- event(value) do
      case Map.fetch(events, value["event_id"]) do
        {:ok, ^value} ->
          {:ok, state}

        {:ok, _} ->
          {:error, :hook_feedback_conflict}

        :error ->
          with {:ok, item} <- transition(items[value["item_id"]], value) do
            {:ok,
             %{
               state
               | items: Map.put(items, value["item_id"], item),
                 events: Map.put(events, value["event_id"], value)
             }}
          end
      end
    end
  end

  def apply_event(_, _), do: {:error, :invalid_hook_feedback}

  defp transition(nil, %{"fact" => "received"} = event) do
    {:ok,
     event
     |> Map.take(~w(item_id session_id origin text))
     |> Map.merge(%{"status" => "received", "delivery" => nil})}
  end

  defp transition(%{"session_id" => session_id} = item, %{"session_id" => session_id} = event) do
    status = item["status"]

    case event["fact"] do
      "dispatch_started" when status == "received" ->
        {:ok, Map.merge(item, %{"status" => "dispatching", "delivery" => event["delivery"]})}

      "admitted" when status == "dispatching" ->
        if message_matches?(item, event) do
          delivery = Map.put(item["delivery"], "runtime_message_id", event["runtime_message_id"])
          {:ok, Map.merge(item, %{"status" => "admitted", "delivery" => delivery})}
        else
          {:error, :hook_feedback_conflict}
        end

      "consumed" when status in ["admitted", "delivery_unknown"] ->
        if message_matches?(item, event),
          do: {:ok, Map.put(item, "status", "consumed")},
          else: {:error, :hook_feedback_conflict}

      "delivery_unknown" when status in ["dispatching", "admitted"] ->
        {:ok, Map.merge(item, %{"status" => "delivery_unknown", "reason" => event["reason"]})}

      "discarded" when status in ["received", "dispatching", "admitted", "delivery_unknown"] ->
        {:ok, Map.merge(item, %{"status" => "discarded", "reason" => event["reason"]})}

      _ ->
        {:error, :hook_feedback_conflict}
    end
  end

  defp transition(_, _), do: {:error, :hook_feedback_conflict}

  defp message_matches?(item, event),
    do: get_in(item, ["delivery", "message_id"]) == event["message_id"]

  defp valid_fact?(%{"fact" => "received"} = value) do
    keys?(value, @common ++ ~w(origin text)) and valid_item_identity?(value)
  end

  defp valid_fact?(value) do
    attrs = Map.drop(value, @common)
    keys?(value, @common ++ Map.keys(attrs)) and valid_attrs?(value["fact"], attrs)
  end

  defp valid_attrs?("dispatch_started", attrs),
    do: keys?(attrs, ["delivery"]) and valid_delivery?(attrs["delivery"])

  defp valid_attrs?("admitted", attrs),
    do:
      keys?(attrs, ~w(message_id runtime_message_id)) and
        text?(attrs["message_id"], 512) and text?(attrs["runtime_message_id"], 512)

  defp valid_attrs?("consumed", attrs),
    do: keys?(attrs, ["message_id"]) and text?(attrs["message_id"], 512)

  defp valid_attrs?(name, attrs) when name in ["delivery_unknown", "discarded"],
    do: keys?(attrs, ["reason"]) and text?(attrs["reason"], 4_096)

  defp valid_attrs?(_, _), do: false

  defp valid_delivery?(delivery) when is_map(delivery) do
    keys?(delivery, @delivery) and text?(delivery["message_id"], 512) and
      text?(delivery["turn_id"], 512) and delivery["mode"] in ["steering", "prompt"]
  end

  defp valid_delivery?(_), do: false

  defp valid_item_identity?(item) do
    text?(item["session_id"], 512) and valid_origin?(item["origin"]) and
      text?(item["text"], 65_536) and
      item["item_id"] == item_id(item["session_id"], item["origin"])
  end

  defp valid_origin?(origin) when is_map(origin) do
    keys?(origin, @origin) and is_integer(origin["incarnation"]) and
      origin["incarnation"] > 0 and is_integer(origin["handler_index"]) and
      origin["handler_index"] >= 0 and digest?(origin["handler_digest"]) and
      Enum.all?(@origin -- ~w(incarnation handler_index handler_digest), &text?(origin[&1], 512))
  end

  defp valid_origin?(_), do: false

  defp item_id(session_id, origin) do
    identity = Jason.encode!([session_id | Enum.map(@origin, &origin[&1])])
    "sigma-async-hook-" <> Base.encode16(:crypto.hash(:sha256, identity), case: :lower)
  end

  defp event_id(item_id, fact), do: item_id <> ":" <> fact

  defp valid_item_id?("sigma-async-hook-" <> digest), do: digest?(digest)
  defp valid_item_id?(_), do: false

  defp digest?(digest),
    do:
      is_binary(digest) and byte_size(digest) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)

  defp keys?(map, keys),
    do:
      not is_struct(map) and map_size(map) == length(keys) and
        Enum.all?(keys, &Map.has_key?(map, &1))

  defp text?(text, limit),
    do:
      is_binary(text) and byte_size(text) <= limit and String.valid?(text) and
        String.trim(text) != ""
end
