defmodule Sigma.Agent.Backplane.AsyncDelivery do
  @moduledoc false

  alias Sigma.Agent.Backplane.{AsyncInbox, Store}
  alias Sigma.Protocol.AsyncInteractions

  def refresh(writer, store, pending_ids) do
    with {:ok, _} <- AsyncInbox.reconcile(writer, store),
         {:ok, state} <- writer_state(writer),
         {:ok, nodes} <- selected_nodes(state),
         :ok <- reconcile_items(writer, store, state, nodes, pending_ids) do
      snapshot(writer)
    end
  end

  def snapshot(writer) do
    with {:ok, state} <- writer_state(writer),
         {:ok, nodes} <- selected_nodes(state) do
      items =
        state.projection
        |> AsyncInteractions.snapshot(Enum.map(nodes, & &1.entry["id"]))
        |> Enum.map(fn item ->
          Map.put(
            item,
            "can_reply",
            item["session_id"] == state.session_id and item["status"] in ~w(open notice saved)
          )
        end)

      {:ok, %{items: items, leaf_id: state.leaf_id}}
    end
  end

  def fact(writer, item, name, attrs \\ %{}) do
    with {:ok, state} <- writer_state(writer),
         {:ok, event} <- AsyncInteractions.fact(item, name, attrs),
         {:ok, _} <-
           apply(Sigma.Session.Writer, :append_async_interaction, [writer, event, state.leaf_id]) do
      :ok
    end
  end

  # Host queue acceptance is not a Runtime admission. Persist the exact public
  # admission identity before allowing it to become consumption evidence.
  def runtime_admitted(writer, message, run_id, runtime_id) do
    case get_in(Map.get(message, :metadata, %{}), ["async_interaction"]) do
      nil ->
        :ok

      correlation ->
        with {:ok, state} <- writer_state(writer),
             %{"reply" => reply} = item <- state.projection.items[correlation["item_id"]],
             true <- item["session_id"] == state.session_id,
             true <- reply["message_id"] == message.id,
             true <- reply["metadata"]["async_interaction"] == correlation do
          fact(writer, item, "runtime_admitted", %{
            "reply_id" => reply["reply_id"],
            "run_id" => run_id,
            "runtime_message_id" => runtime_id
          })
        else
          {:error, _} = error -> error
          _ -> {:error, :invalid_async_runtime_admission}
        end
    end
  end

  def dismiss(writer, item_id, expected_leaf) do
    with {:ok, state} <- writer_state(writer),
         true <- state.leaf_id == expected_leaf,
         {:ok, item} <- Map.fetch(state.projection.items, item_id),
         {:ok, event} <-
           AsyncInteractions.fact(item, "dismissed", %{"reason" => "user_dismissed"}),
         {:ok, _} <-
           apply(Sigma.Session.Writer, :append_async_interaction, [writer, event, expected_leaf]) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_async_interaction_scope}
    end
  end

  def close_run(writer, run_id, outcome) do
    with {:ok, state} <- writer_state(writer),
         {:ok, nodes} <- selected_nodes(state) do
      state.projection
      |> AsyncInteractions.snapshot(Enum.map(nodes, & &1.entry["id"]))
      |> Enum.reduce_while(:ok, fn item, :ok ->
        if item["session_id"] == state.session_id and item["origin"]["run_id"] == run_id and
             item["origin"]["tool_name"] == "request_user_input_async" and
             item["status"] in ~w(open saved) do
          case fact(writer, item, "dismissed", %{"reason" => "origin_#{outcome}"}) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        else
          {:cont, :ok}
        end
      end)
    end
  end

  defp reconcile_items(writer, store, state, nodes, pending_ids) do
    host_outcomes = host_terminal_outcomes(state, nodes)

    state.projection
    |> AsyncInteractions.snapshot(Enum.map(nodes, & &1.entry["id"]))
    |> Enum.reduce_while(:ok, fn item, :ok ->
      result =
        cond do
          item["session_id"] != state.session_id ->
            :ok

          item["status"] in ~w(dispatching admitted delivery_unknown) ->
            reconcile_reply(writer, store, item, nodes, pending_ids)

          item["origin"]["tool_name"] == "request_user_input_async" and
              item["status"] in ~w(open saved) ->
            reconcile_question(writer, store, item, host_outcomes)

          true ->
            :ok
        end

      case result do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp reconcile_question(writer, store, item, host_outcomes) do
    run_id = item["origin"]["run_id"]

    case host_outcomes[run_id] do
      outcome when outcome in [:cancelled, :failed] ->
        fact(writer, item, "dismissed", %{"reason" => "origin_#{outcome}"})

      _ ->
        case Store.load(store, run_id) do
          {:ok, %{run: %{state: outcome}}} when outcome in [:cancelled, :failed] ->
            fact(writer, item, "dismissed", %{"reason" => "origin_#{outcome}"})

          {:ok, _} ->
            :ok

          {:error, _} = error ->
            error
        end
    end
  end

  defp host_terminal_outcomes(state, nodes) do
    ancestry = MapSet.new(nodes, & &1.entry["id"])
    index = apply(Sigma.Session.Journal.Index, :build, [state.entries])

    # Metrics are auxiliary siblings of conversation entries, not path nodes.
    # The host can finish cancelled/failed after the runtime has completed.
    Enum.reduce(index.ordered, %{}, fn %{entry: entry, parent_id: parent_id}, outcomes ->
      if MapSet.member?(ancestry, parent_id) do
        case apply(Sigma.Session.EntryDecoder, :metrics, [entry]) do
          {:ok,
           {:turn_finished,
            %{"session_id" => session_id, "turn_id" => run_id, "status" => outcome}}}
          when is_binary(run_id) and run_id != "" and
                 outcome in [:completed, :cancelled, :failed] ->
            if session_id == state.session_id,
              do: Map.put(outcomes, run_id, outcome),
              else: outcomes

          _ ->
            outcomes
        end
      else
        outcomes
      end
    end)
  end

  defp reconcile_reply(writer, store, item, nodes, pending_ids) do
    reply = item["reply"]

    with {:ok, consumed?} <- consumed?(store, item, nodes) do
      cond do
        consumed? ->
          fact(writer, item, "consumed", %{"reply_id" => reply["reply_id"]})

        MapSet.member?(pending_ids, reply["message_id"]) ->
          :ok

        item["status"] == "delivery_unknown" ->
          :ok

        true ->
          fact(writer, item, "delivery_unknown", %{
            "reply_id" => reply["reply_id"],
            "reason" => "runtime_consumption_unconfirmed"
          })
      end
    end
  end

  defp consumed?(store, %{"reply" => reply, "delivery" => delivery}, nodes)
       when is_map(reply) and is_map(delivery) do
    canonical =
      Enum.find_value(nodes, fn
        %{
          entry: %{
            "type" => "message",
            "message" => %{"role" => "user", "id" => id, "metadata" => metadata} = message
          }
        }
        when is_map(metadata) ->
          if id == reply["message_id"] and metadata["turn_id"] == delivery["run_id"] and
               metadata["async_interaction"] == reply["metadata"]["async_interaction"],
             do: message

        _ ->
          nil
      end)

    if canonical do
      case Store.load(store, delivery["run_id"]) do
        {:ok, %{run: run}} ->
          messages = get_in(run, [:context, :conversation, :messages]) || []

          {:ok,
           run.run_id == delivery["run_id"] and
             Enum.any?(messages, fn message ->
               Map.get(message, :role) == :user and
                 Map.get(message, :id) == delivery["runtime_message_id"] and
                 same_content?(Map.get(message, :content), canonical["content"])
             end)}

        {:error, %Backplane.AgentRuntime.Error{class: :not_found}} ->
          {:ok, false}

        {:error, _} = error ->
          error
      end
    else
      {:ok, false}
    end
  end

  defp consumed?(_store, _item, _nodes), do: {:ok, false}

  defp same_content?(content, canonical) do
    with {:ok, json} <- Jason.encode(content),
         {:ok, normalized} <- Jason.decode(json),
         do: normalized == canonical,
         else: (_ -> false)
  end

  defp selected_nodes(state) do
    index = apply(Sigma.Session.Journal.Index, :build, [state.entries])

    with {:ok, {_leaf, nodes}} <-
           apply(Sigma.Session.Journal.Index, :path, [index, state.leaf_id]),
         do: {:ok, nodes}
  end

  defp writer_state(writer), do: apply(Sigma.Session.Writer, :async_interaction_state, [writer])
end
