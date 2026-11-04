defmodule Sigma.Agent.Backplane.HookDelivery do
  @moduledoc """
  Session-owned, durable delivery of native and MCP asynchronous PostToolUse context.

  A callback saves its immutable origin and original text directly to the owned
  Writer. Delivery requires the matching public Store intent and successful
  settlement. A canonical journal message and the matching Runtime checkpoint
  prove consumption; neither a Writer receipt nor an admission alone does so.
  Ambiguous admissions are never retried. This module never starts a turn.
  """

  require Logger

  alias Sigma.Agent.Backplane.Store
  alias Sigma.Agent.Message
  alias Sigma.Session.HookFeedback

  @identity ~w(run_id incarnation turn_id step_id attempt_id invocation_id tool_call_id tool_name)a
  @prefix "[Developer context from async hook]\n"

  def factory(writer, operation) do
    fn index, spec ->
      with {:ok, state} <- writer_state(writer),
           {:ok, nodes} <- selected_nodes(state),
           %{entry: %{"id" => anchor}} <-
             Enum.find(Enum.reverse(nodes), &(&1.entry["type"] == "message")),
           origin <-
             Map.new(@identity, &{Atom.to_string(&1), operation[&1]})
             |> Map.merge(%{
               "branch_entry_id" => anchor,
               "handler_index" => index,
               "handler_digest" => digest(spec)
             }),
           {:ok, _} <-
             apply(HookFeedback, :received, [state.session_id, origin, "validate origin"]) do
        fn text, warnings ->
          Enum.each(warnings, &Logger.warning("[hooks] #{&1}"))

          if is_binary(text) and text != "" do
            result =
              with {:ok, event} <-
                     apply(HookFeedback, :received, [state.session_id, origin, text]),
                   do: append(writer, event)

            if result != :ok,
              do: Logger.warning("[hooks] async feedback could not be saved: #{inspect(result)}")
          end
        end
      else
        _ -> {:error, :hook_feedback_origin_unavailable}
      end
    end
  end

  def message?(%{metadata: %{"hook_feedback" => %{"version" => 1, "item_ids" => ids}}}),
    do: is_list(ids) and ids != []

  def message?(_), do: false

  def prepare_prompt(writer, store, message, run_id) do
    with :ok <- reconcile(writer, store),
         {:ok, items} <- ready_items(writer, store),
         :ok <- start_delivery(writer, items, message.id, run_id, "prompt") do
      {:ok, attach(message, items, run_id)}
    end
  end

  def next(writer, store, run_id, pending_ids \\ MapSet.new()) do
    with :ok <- reconcile(writer, store, pending_ids),
         {:ok, items} <- ready_items(writer, store) do
      case items do
        [] ->
          :none

        [item | _] ->
          id = "hook_message_" <> item["item_id"]

          with :ok <- start_delivery(writer, [item], id, run_id, "steering") do
            {:ok, attach(Message.user(id, ""), [item], run_id)}
          end
      end
    end
  end

  def admitted(writer, message, runtime_id) do
    each_message_item(writer, message, fn item ->
      fact(writer, item, "admitted", %{
        "message_id" => message.id,
        "runtime_message_id" => runtime_id
      })
    end)
  end

  def unknown(writer, message, reason) do
    each_message_item(writer, message, fn item ->
      if item["status"] in ~w(dispatching admitted),
        do: fact(writer, item, "delivery_unknown", %{"reason" => reason}),
        else: :ok
    end)
  end

  def reconcile(writer, store, pending_ids \\ MapSet.new()) do
    with {:ok, state} <- writer_state(writer),
         {:ok, nodes} <- selected_nodes(state) do
      reduce_items(state.projection.items, fn item ->
        if item["status"] in ~w(dispatching admitted delivery_unknown) do
          reconcile_delivery(writer, store, item, nodes, pending_ids)
        else
          :ok
        end
      end)
    end
  end

  defp ready_items(writer, store) do
    with {:ok, state} <- writer_state(writer),
         {:ok, nodes} <- selected_nodes(state) do
      outcomes = host_outcomes(state, nodes)

      state.projection.items
      |> Map.values()
      |> Enum.filter(fn item ->
        item["status"] == "received" and
          get_in(state.history.items, [item["item_id"], "status"]) == "received"
      end)
      |> Enum.sort_by(& &1["item_id"])
      |> Enum.reduce_while({:ok, []}, fn item, {:ok, items} ->
        source =
          if outcomes[item["origin"]["run_id"]] in [:cancelled, :failed, :interrupted],
            do: :discard,
            else: source_state(store, item)

        case source do
          :successful ->
            {:cont, {:ok, items ++ [item]}}

          :pending ->
            {:cont, {:ok, items}}

          :discard ->
            case fact(writer, item, "discarded", %{
                   "reason" => "origin_not_successfully_completed"
                 }) do
              :ok -> {:cont, {:ok, items}}
              error -> {:halt, error}
            end

          error ->
            {:halt, error}
        end
      end)
    end
  end

  defp source_state(store, %{"origin" => origin}) do
    with {:ok, %{run: run}} <- Store.load(store, origin["run_id"]),
         true <- run.run_id == origin["run_id"] and run.incarnation == origin["incarnation"],
         %{type: :tool, operation: operation} = intent <-
           Map.get(Map.get(run, :execution_intents, %{}), "tool:" <> origin["invocation_id"]),
         true <- Enum.all?(@identity, &(operation[&1] == origin[Atom.to_string(&1)])) do
      result = Map.get(Map.get(run, :tool_results, %{}), origin["invocation_id"])

      cond do
        run.state in [:cancelling, :cancelled, :failed, :timed_out, :unknown_outcome] -> :discard
        intent[:status] != :consumed -> :pending
        is_map(result) and result[:is_error] == false and is_nil(result[:error]) -> :successful
        true -> :discard
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_hook_feedback_origin}
    end
  end

  # Host cancellation can win after Runtime commits completion. Only the
  # selected raw ancestry's durable host facts may override that origin.
  defp host_outcomes(state, nodes) do
    ancestry = MapSet.new(nodes, & &1.entry["id"])
    index = apply(Sigma.Session.Journal.Index, :build, [state.entries])

    Enum.reduce(index.ordered, %{}, fn %{entry: entry, parent_id: parent_id}, outcomes ->
      if MapSet.member?(ancestry, parent_id) do
        case apply(Sigma.Session.EntryDecoder, :metrics, [entry]) do
          {:ok,
           {:turn_finished, %{"session_id" => session, "turn_id" => run, "status" => status}}}
          when session == state.session_id and is_binary(run) ->
            Map.put(outcomes, run, status)

          _ ->
            outcomes
        end
      else
        outcomes
      end
    end)
  end

  defp start_delivery(writer, items, message_id, turn_id, mode) do
    reduce_items(items, fn item ->
      fact(writer, item, "dispatch_started", %{
        "delivery" => %{"message_id" => message_id, "turn_id" => turn_id, "mode" => mode}
      })
    end)
  end

  defp attach(message, [], _run_id), do: message

  defp attach(message, items, run_id) do
    context = Enum.map_join(items, "\n\n", &(@prefix <> &1["text"]))

    content =
      case message.content do
        "" -> context
        text when is_binary(text) -> text <> "\n\n" <> context
        blocks when is_list(blocks) -> blocks ++ [%{type: :text, text: context}]
      end

    metadata = %{
      "version" => 1,
      "session_id" => hd(items)["session_id"],
      "destination_run_id" => run_id,
      "item_ids" => Enum.map(items, & &1["item_id"])
    }

    Map.merge(message, %{
      content: content,
      metadata: Map.put(Map.get(message, :metadata, %{}), "hook_feedback", metadata)
    })
  end

  defp reconcile_delivery(writer, store, item, nodes, pending_ids) do
    delivery = item["delivery"]

    with {:ok, consumed?} <- consumed?(store, item, nodes) do
      cond do
        consumed? ->
          fact(writer, item, "consumed", %{"message_id" => delivery["message_id"]})

        MapSet.member?(pending_ids, delivery["message_id"]) ->
          :ok

        item["status"] == "delivery_unknown" ->
          :ok

        true ->
          fact(writer, item, "delivery_unknown", %{"reason" => "runtime_consumption_unconfirmed"})
      end
    end
  end

  defp consumed?(store, item, nodes) do
    delivery = item["delivery"]
    canonical = Enum.find_value(nodes, &canonical_message(&1, item))

    if is_binary(delivery["runtime_message_id"]) and canonical do
      with {:ok, %{run: run}} <- Store.load(store, delivery["turn_id"]) do
        messages = get_in(run, [:context, :conversation, :messages]) || []

        {:ok,
         Enum.any?(messages, fn message ->
           Map.get(message, :role) == :user and
             same_content?(Map.get(message, :content), canonical["content"]) and
             (Map.get(message, :id) == delivery["runtime_message_id"] or
                (Map.get(message, :id) == delivery["message_id"] and
                   get_in(Map.get(message, :metadata, %{}), ["hook_feedback"]) ==
                     get_in(canonical, ["metadata", "hook_feedback"])))
         end)}
      end
    else
      {:ok, false}
    end
  end

  defp canonical_message(%{entry: %{"type" => "message", "message" => message}}, item) do
    delivery = item["delivery"]
    metadata = get_in(message, ["metadata", "hook_feedback"])

    if message["role"] == "user" and message["id"] == delivery["message_id"] and
         is_map(metadata) and metadata["version"] == 1 and
         metadata["session_id"] == item["session_id"] and
         metadata["destination_run_id"] == delivery["turn_id"] and
         is_list(metadata["item_ids"]) and item["item_id"] in metadata["item_ids"],
       do: message
  end

  defp canonical_message(_, _), do: nil

  defp same_content?(content, canonical) do
    with {:ok, json} <- Jason.encode(content),
         {:ok, normalized} <- Jason.decode(json),
         do: normalized == canonical,
         else: (_ -> false)
  end

  defp each_message_item(writer, message, fun) do
    if message?(message) do
      with {:ok, state} <- writer_state(writer) do
        ids = get_in(message.metadata, ["hook_feedback", "item_ids"])

        reduce_items(ids, fn id ->
          case state.projection.items[id] do
            %{"delivery" => %{"message_id" => message_id}} = item when message_id == message.id ->
              fun.(item)

            _ ->
              {:error, :invalid_hook_feedback_delivery}
          end
        end)
      end
    else
      :ok
    end
  end

  defp fact(writer, item, name, attrs) do
    with {:ok, event} <- apply(HookFeedback, :fact, [item, name, attrs]),
         do: append(writer, event)
  end

  # Only a definite leaf-CAS refusal can be retried; Writer deduplicates exact
  # event IDs. An exit/unknown append result never re-enters this path.
  defp append(writer, event, attempts \\ 3) do
    with {:ok, state} <- writer_state(writer) do
      case apply(Sigma.Session.Writer, :append_hook_feedback, [writer, event, state.leaf_id]) do
        {:ok, _receipt} ->
          :ok

        {:error, :invalid_hook_feedback_scope} = error when attempts > 1 ->
          case writer_state(writer) do
            {:ok, %{leaf_id: leaf}} when leaf != state.leaf_id ->
              append(writer, event, attempts - 1)

            _ ->
              error
          end

        error ->
          error
      end
    end
  catch
    :exit, _ -> {:error, :hook_feedback_append_unknown}
  end

  defp reduce_items(items, fun) do
    Enum.reduce_while(items, :ok, fn
      {_id, item}, :ok -> reduce_result(fun.(item))
      item, :ok -> reduce_result(fun.(item))
    end)
  end

  defp reduce_result(:ok), do: {:cont, :ok}
  defp reduce_result(error), do: {:halt, error}

  defp selected_nodes(state) do
    index = apply(Sigma.Session.Journal.Index, :build, [state.entries])

    with {:ok, {_leaf, nodes}} <-
           apply(Sigma.Session.Journal.Index, :path, [index, state.leaf_id]),
         do: {:ok, nodes}
  end

  defp writer_state(writer), do: apply(Sigma.Session.Writer, :hook_feedback_state, [writer])

  defp digest(spec) do
    matcher =
      case spec.matcher do
        %Regex{} = regex -> {Regex.source(regex), Regex.opts(regex)}
        matcher -> matcher
      end

    spec
    |> Map.from_struct()
    |> Map.put(:matcher, matcher)
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
