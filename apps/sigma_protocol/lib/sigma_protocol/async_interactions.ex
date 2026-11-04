defmodule Sigma.Protocol.AsyncInteractions do
  @moduledoc """
  Individually bounded async cards and their host acknowledgement states.

  Facts are JSON values, not Runtime effect receipts or synchronous waiters.
  `saved`, `admitted` and `consumed` describe distinct host boundaries. Once a
  dispatch has started, uncertainty cannot make a reply eligible for redispatch.
  The embedding Writer authenticates session/branch ownership before applying a
  fact and persists it before publishing this projection. Historical cards and
  receipts have no lifetime ceiling: replay must retain their deduplication facts.
  """

  @common ~w(version fact event_id item_id session_id)
  @origin ~w(run_id incarnation turn_id step_id attempt_id invocation_id tool_call_id tool_name branch_entry_id)
  @reply ~w(reply_id message_id turn_id content metadata)
  @facts ~w(received reply_saved dispatch_started admitted runtime_admitted consumed dismissed delivery_unknown)
  @max_bytes 131_072
  @max_answer_bytes 98_304
  # Replies retain a complete received batch plus separately bounded answers.
  # The envelope budget also leaves room for escaped text and correlation fields.
  @max_reply_content_bytes @max_bytes * 2
  @max_reply_bytes @max_bytes * 3

  @doc "Validates complete async cards without truncating their questions, replies or identities."
  def project(%{items: items, leaf_id: leaf}, session_id)
      when is_list(items) do
    with true <- is_nil(leaf) or async_identity?(leaf),
         true <- Enum.all?(items, &valid_async_card?(&1, session_id)),
         true <- length(Enum.uniq_by(items, & &1["item_id"])) == length(items) do
      {:ok, %{"items" => items, "leafId" => leaf}}
    else
      _ -> {:error, :async_payload_rejected}
    end
  end

  def project(_, _), do: {:error, :async_payload_rejected}

  defp valid_async_card?(card, session_id) when is_map(card) and not is_struct(card) do
    received =
      card
      |> Map.take(~w(version item_id session_id origin questions message))
      |> Map.merge(%{"fact" => "received", "event_id" => "projection:received"})

    with true <- is_integer(card["sequence"]) and card["sequence"] > 0,
         true <- is_boolean(card["can_reply"]),
         true <-
           not card["can_reply"] or
             (card["session_id"] == session_id and card["status"] in ~w(open notice saved)),
         {:ok, state} <- apply_event(new(), received),
         {:ok, state} <- async_card_reply(state, card),
         {:ok, state} <- async_card_status(state, card),
         canonical <- Map.put(state.items[card["item_id"]], "sequence", card["sequence"]) do
      canonical == Map.delete(card, "can_reply")
    else
      _ -> false
    end
  end

  defp valid_async_card?(_, _), do: false

  defp async_card_reply(state, %{"reply" => nil}), do: {:ok, state}

  defp async_card_reply(state, card) do
    if valid_reply?(card["reply"]),
      do: async_card_fact(state, card, "reply_saved", %{"reply" => card["reply"]}),
      else: {:error, :async_payload_rejected}
  end

  defp async_card_status(state, card) do
    current = state.items[card["item_id"]]["status"]

    cond do
      card["status"] == current ->
        {:ok, state}

      card["status"] == "dismissed" ->
        async_card_fact(state, card, "dismissed", %{"reason" => card["reason"]})

      card["status"] == "delivery_unknown" and is_nil(card["reply"]) ->
        async_card_fact(state, card, "delivery_unknown", %{"reason" => card["reason"]})

      card["status"] in ~w(dispatching admitted consumed delivery_unknown) ->
        with {:ok, state} <-
               async_card_fact(state, card, "dispatch_started", %{
                 "reply_id" => get_in(card, ["reply", "reply_id"])
               }),
             {:ok, state} <- async_card_delivery(state, card) do
          cond do
            card["status"] == "dispatching" ->
              {:ok, state}

            card["status"] == "consumed" and Map.has_key?(card, "reason") ->
              with {:ok, state} <-
                     async_card_fact(state, card, "delivery_unknown", %{
                       "reply_id" => get_in(card, ["reply", "reply_id"]),
                       "reason" => card["reason"]
                     }) do
                async_card_fact(state, card, "consumed", %{
                  "reply_id" => get_in(card, ["reply", "reply_id"])
                })
              end

            true ->
              attrs = %{"reply_id" => get_in(card, ["reply", "reply_id"])}

              attrs =
                if card["status"] == "delivery_unknown",
                  do: Map.put(attrs, "reason", card["reason"]),
                  else: attrs

              async_card_fact(state, card, card["status"], attrs)
          end
        end

      true ->
        {:error, :async_payload_rejected}
    end
  end

  defp async_card_delivery(state, card) do
    case Map.fetch(card, "delivery") do
      :error ->
        {:ok, state}

      {:ok, %{"run_id" => run_id, "runtime_message_id" => runtime_id} = delivery}
      when map_size(delivery) == 2 ->
        async_card_fact(state, card, "runtime_admitted", %{
          "reply_id" => get_in(card, ["reply", "reply_id"]),
          "run_id" => run_id,
          "runtime_message_id" => runtime_id
        })

      _ ->
        {:error, :async_payload_rejected}
    end
  end

  defp async_card_fact(state, card, name, attrs) do
    with {:ok, fact} <- fact(card, name, attrs),
         do: apply_event(state, fact)
  end

  defp async_identity?(text),
    do:
      is_binary(text) and byte_size(text) <= 512 and String.valid?(text) and
        String.trim(text) != ""

  def new, do: %{version: 1, items: %{}, events: %{}}

  def event(value) when is_map(value) and not is_struct(value) do
    with true <- value["version"] == 1 and value["fact"] in @facts,
         true <- Enum.all?(~w(event_id item_id session_id), &text?(value[&1], 512)),
         true <- valid_fact?(value),
         {:ok, encoded} <- Jason.encode(value),
         true <- byte_size(encoded) <= event_limit(value) do
      {:ok, value}
    else
      _ -> {:error, :invalid_async_interaction}
    end
  end

  def event(_), do: {:error, :invalid_async_interaction}
  def to_map(event), do: event

  def fact(item, name, attrs \\ %{}) when is_map(item) and is_map(attrs) do
    reply_id = attrs["reply_id"] || get_in(attrs, ["reply", "reply_id"])

    event(
      Map.merge(attrs, %{
        "version" => 1,
        "fact" => name,
        "event_id" => "async_fact_" <> digest([item["item_id"], name, reply_id]),
        "item_id" => item["item_id"],
        "session_id" => item["session_id"]
      })
    )
  end

  def apply_event(%{version: 1, items: items, events: events} = state, value)
      when is_map(items) and is_map(events) do
    with {:ok, value} <- event(value) do
      case Map.fetch(events, value["event_id"]) do
        {:ok, ^value} -> {:ok, state}
        {:ok, _} -> {:error, :async_interaction_conflict}
        :error -> apply_new(state, value)
      end
    end
  end

  def apply_event(_, _), do: {:error, :invalid_async_interaction}

  def snapshot(%{items: items}, branch_entry_ids) when is_list(branch_entry_ids) do
    anchors = MapSet.new(branch_entry_ids)

    items
    |> Map.values()
    |> Enum.filter(&MapSet.member?(anchors, &1["origin"]["branch_entry_id"]))
    |> Enum.sort_by(& &1["sequence"])
  end

  def reply(payload, item) when is_map(payload) and is_map(item) do
    with true <- item["status"] in ~w(open notice saved),
         true <- text?(payload["replyId"], 512),
         {:ok, content} <- reply_content(payload, item),
         reply <- reply_record(item, payload["replyId"], content),
         true <- is_nil(item["reply"]) or item["reply"] == reply do
      {:ok, reply}
    else
      _ -> {:error, :invalid_async_reply}
    end
  end

  def reply(_, _), do: {:error, :invalid_async_reply}

  defp apply_new(state, event) do
    with {:ok, item} <- transition(state.items[event["item_id"]], event, state) do
      {:ok,
       %{
         state
         | items: Map.put(state.items, event["item_id"], item),
           events: Map.put(state.events, event["event_id"], event)
       }}
    end
  end

  defp transition(nil, %{"fact" => "received"} = event, state) do
    {:ok,
     event
     |> Map.drop(~w(event_id fact))
     |> Map.merge(%{
       "status" => if(Map.has_key?(event, "questions"), do: "open", else: "notice"),
       "reply" => nil,
       "sequence" => map_size(state.items) + 1
     })}
  end

  defp transition(%{"session_id" => session} = item, %{"session_id" => session} = event, _state) do
    status = item["status"]
    reply_id = get_in(item, ["reply", "reply_id"])
    event_reply_id = event["reply_id"]

    case event["fact"] do
      "reply_saved" when status in ["open", "notice"] ->
        if reply_matches_item?(event["reply"], item),
          do: {:ok, Map.merge(item, %{"status" => "saved", "reply" => event["reply"]})},
          else: {:error, :invalid_async_reply}

      "dispatch_started" when status == "saved" and reply_id == event_reply_id ->
        {:ok, Map.put(item, "status", "dispatching")}

      "admitted" when status == "dispatching" and reply_id == event_reply_id ->
        {:ok, Map.put(item, "status", "admitted")}

      "runtime_admitted"
      when status in ["dispatching", "admitted", "delivery_unknown"] and
             not is_nil(reply_id) and reply_id == event_reply_id ->
        delivery = Map.take(event, ~w(run_id runtime_message_id))

        if is_nil(item["delivery"]) or item["delivery"] == delivery,
          do: {:ok, Map.put(item, "delivery", delivery)},
          else: {:error, :async_interaction_conflict}

      "consumed"
      when status in ["dispatching", "admitted", "delivery_unknown"] and
             not is_nil(reply_id) and reply_id == event_reply_id ->
        {:ok, Map.put(item, "status", "consumed")}

      "dismissed" when status in ["open", "notice", "saved"] ->
        {:ok, Map.merge(item, %{"status" => "dismissed", "reason" => event["reason"]})}

      "delivery_unknown" when status in ["open", "notice", "dispatching", "admitted"] ->
        if event["reply_id"] == reply_id do
          {:ok, Map.merge(item, %{"status" => "delivery_unknown", "reason" => event["reason"]})}
        else
          {:error, :async_interaction_conflict}
        end

      _ ->
        {:error, :async_interaction_conflict}
    end
  end

  defp transition(_, _, _), do: {:error, :async_interaction_conflict}

  defp valid_fact?(%{"fact" => "received", "origin" => origin} = value) do
    valid_origin?(origin) and
      case origin["tool_name"] do
        "request_user_input_async" ->
          keys?(value, @common ++ ~w(origin questions)) and questions?(value["questions"])

        "send_message_to_user_async" ->
          keys?(value, @common ++ ~w(origin message)) and text?(value["message"], 32_768)

        _ ->
          false
      end
  end

  defp valid_fact?(%{"fact" => "reply_saved"} = value),
    do: keys?(value, @common ++ ["reply"]) and valid_reply?(value["reply"])

  defp valid_fact?(%{"fact" => fact} = value)
       when fact in ~w(dispatch_started admitted consumed),
       do: keys?(value, @common ++ ["reply_id"]) and text?(value["reply_id"], 512)

  defp valid_fact?(%{"fact" => "runtime_admitted"} = value) do
    fields = ~w(reply_id run_id runtime_message_id)
    keys?(value, @common ++ fields) and Enum.all?(fields, &text?(value[&1], 512))
  end

  defp valid_fact?(%{"fact" => "dismissed"} = value),
    do: keys?(value, @common ++ ["reason"]) and text?(value["reason"], 4_096)

  defp valid_fact?(%{"fact" => "delivery_unknown"} = value) do
    keys = @common ++ ["reason"]

    (keys?(value, keys) or
       (keys?(value, keys ++ ["reply_id"]) and text?(value["reply_id"], 512))) and
      text?(value["reason"], 4_096)
  end

  defp valid_fact?(_), do: false

  defp valid_origin?(origin) when is_map(origin) do
    keys?(origin, @origin) and is_integer(origin["incarnation"]) and
      origin["incarnation"] > 0 and
      Enum.all?(@origin -- ["incarnation"], &text?(origin[&1], 512))
  end

  defp valid_origin?(_), do: false

  defp questions?(questions) when is_list(questions) and length(questions) in 1..32 do
    Enum.all?(questions, fn question ->
      is_map(question) and
        (keys?(question, ["title"]) or keys?(question, ~w(title options))) and
        text?(question["title"], 32_768) and
        (not Map.has_key?(question, "options") or options?(question["options"]))
    end)
  end

  defp questions?(_), do: false

  defp options?(options) when is_list(options) and length(options) in 1..200,
    do: Enum.all?(options, &text?(&1, 32_768))

  defp options?(_), do: false

  defp valid_reply?(reply) when is_map(reply) do
    keys?(reply, @reply) and
      Enum.all?(~w(reply_id message_id turn_id), &text?(reply[&1], 512)) and
      text?(reply["content"], @max_reply_content_bytes) and valid_metadata?(reply["metadata"])
  end

  defp valid_reply?(_), do: false

  defp valid_metadata?(%{"async_interaction" => correlation} = metadata) do
    map_size(metadata) == 1 and is_map(correlation) and
      keys?(correlation, ~w(version item_id reply_id origin_session_id)) and
      correlation["version"] == 1 and
      Enum.all?(~w(item_id reply_id origin_session_id), &text?(correlation[&1], 512))
  end

  defp valid_metadata?(_), do: false

  defp reply_matches_item?(reply, item) do
    valid_reply?(reply) and
      reply == reply_record(item, reply["reply_id"], reply["content"])
  end

  defp reply_content(payload, %{"questions" => questions} = item) do
    answers = payload["answers"]

    if keys?(payload, ~w(replyId answers)) and is_list(answers) and
         length(answers) == length(questions) and
         Enum.all?(Enum.with_index(answers), fn {answer, index} ->
           is_map(answer) and keys?(answer, ~w(questionIndex answer)) and
             answer["questionIndex"] === index and text?(answer["answer"], 32_768)
         end) and bounded_answers?(answers) do
      text =
        Enum.zip(questions, answers)
        |> Enum.map_join("\n\n", fn {question, answer} ->
          question["title"] <> "\nAnswer:\n" <> answer["answer"]
        end)

      bounded_content("Reply to async questions #{item["item_id"]}:\n" <> text)
    else
      {:error, :invalid_async_reply}
    end
  end

  defp reply_content(payload, %{"message" => _message, "item_id" => id}) do
    if keys?(payload, ~w(replyId text)) and text?(payload["text"], 32_768),
      do: bounded_content("Reply to async message #{id}:\n" <> payload["text"]),
      else: {:error, :invalid_async_reply}
  end

  defp reply_content(_, _), do: {:error, :invalid_async_reply}

  # Bound user input independently of the complete question context. The JSON
  # bound also accounts for escaping without dropping any answer or title.
  defp bounded_answers?(answers) do
    texts = Enum.map(answers, & &1["answer"])

    Enum.reduce(texts, 0, &(byte_size(&1) + &2)) <= @max_answer_bytes and
      byte_size(Jason.encode!(texts)) <= @max_bytes
  end

  defp bounded_content(text) do
    if text?(text, @max_reply_content_bytes),
      do: {:ok, text},
      else: {:error, :invalid_async_reply}
  end

  defp event_limit(%{"fact" => "reply_saved"}), do: @max_reply_bytes
  defp event_limit(_), do: @max_bytes

  defp reply_record(item, reply_id, content) do
    identity = digest([item["session_id"], item["item_id"], reply_id])

    %{
      "reply_id" => reply_id,
      "message_id" => "msg_async_" <> identity,
      "turn_id" => "turn_async_" <> identity,
      "content" => content,
      "metadata" => %{
        "async_interaction" => %{
          "version" => 1,
          "item_id" => item["item_id"],
          "reply_id" => reply_id,
          "origin_session_id" => item["session_id"]
        }
      }
    }
  end

  defp keys?(map, keys),
    do: map_size(map) == length(keys) and Enum.all?(keys, &Map.has_key?(map, &1))

  defp text?(text, limit),
    do:
      is_binary(text) and byte_size(text) <= limit and String.valid?(text) and
        String.trim(text) != ""

  defp digest(value),
    do: :crypto.hash(:sha256, Jason.encode!(value)) |> Base.url_encode64(padding: false)
end
