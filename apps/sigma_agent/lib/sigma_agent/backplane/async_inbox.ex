defmodule Sigma.Agent.Backplane.AsyncInbox do
  @moduledoc """
  Durable host projection of settled native async interactions.

  Runtime events are hints until their exact invocation has a committed successful
  result in the public Store. Recovery reads only root runs named by the selected
  raw journal ancestry and never executes an effect. Replies are acknowledged as
  saved only after the session Writer accepts their fact; admission and delivery
  remain separate host operations.
  """

  alias Sigma.Agent.Backplane.Store
  alias Sigma.Protocol.AsyncInteractions

  @tools ~w(request_user_input_async send_message_to_user_async)
  @identity ~w(run_id incarnation turn_id step_id attempt_id invocation_id tool_call_id tool_name)a

  def capture(writer, store, origin, event) when is_map(origin) and is_map(event) do
    with {:ok, state} <- writer_state(writer),
         true <- origin[:session_id] == state.session_id,
         true <- origin[:run_id] == event[:run_id],
         true <- origin[:incarnation] == event[:incarnation],
         {:ok, branch} <- selected_branch(state),
         anchor when is_binary(anchor) <- branch.runs[origin[:run_id]],
         {:ok, %{run: run}} <- Store.load(store, origin[:run_id]),
         true <- run.run_id == origin[:run_id] and run.incarnation == origin[:incarnation],
         {:ok, operation} <- settled_operation(run, event),
         {:ok, received} <- received(state.session_id, anchor, operation),
         true <- event_matches?(event, received),
         {:ok, _entry_id} <- append(writer, received, state.leaf_id),
         {:ok, latest} <- writer_state(writer),
         {:ok, item} <- Map.fetch(latest.projection.items, received["item_id"]) do
      {:ok, item}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_async_origin}
    end
  end

  def capture(_, _, _, _), do: {:error, :invalid_async_origin}

  def reconcile(writer, store) do
    with {:ok, state} <- writer_state(writer),
         {:ok, branch} <- selected_branch(state) do
      branch.runs
      |> Enum.sort()
      |> Enum.reduce_while({:ok, %{recovered: 0, uncertain: 0}}, fn {run_id, anchor}, acc ->
        case Store.load(store, run_id) do
          {:ok, %{run: %{run_id: ^run_id} = run}} ->
            case recover_run(writer, state, run, anchor, elem(acc, 1)) do
              {:ok, _} = result -> {:cont, result}
              error -> {:halt, error}
            end

          {:error, %Backplane.AgentRuntime.Error{class: :not_found}} ->
            {:cont, acc}

          {:error, _} = error ->
            {:halt, error}

          _ ->
            {:halt, {:error, :invalid_async_runtime_record}}
        end
      end)
    end
  end

  def prepare_reply(writer, item_id, payload, expected_leaf_id) do
    with {:ok, state} <- writer_state(writer),
         true <- state.leaf_id == expected_leaf_id,
         {:ok, branch} <- selected_branch(state),
         {:ok, item} <- Map.fetch(state.projection.items, item_id),
         true <- item["session_id"] == state.session_id,
         true <- MapSet.member?(branch.ids, item["origin"]["branch_entry_id"]),
         {:ok, reply} <- AsyncInteractions.reply(payload, item),
         {:ok, event} <- AsyncInteractions.fact(item, "reply_saved", %{"reply" => reply}),
         {:ok, _entry_id} <- append(writer, event, expected_leaf_id) do
      {:ok, %{status: :saved, reply: reply}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_async_reply_origin}
    end
  end

  defp settled_operation(run, event) do
    invocation_id = event[:invocation_id]

    with true <- is_binary(invocation_id),
         %{type: :tool, operation: operation} = intent <-
           Map.get(Map.get(run, :execution_intents, %{}), "tool:" <> invocation_id),
         true <- operation[:tool_name] in @tools,
         true <- operation[:run_id] == run.run_id,
         true <- operation[:incarnation] == run.incarnation,
         true <- operation[:invocation_id] == invocation_id,
         true <- operation[:tool_call_id] == event[:tool_call_id] do
      case {intent[:status], Map.get(Map.get(run, :tool_results, %{}), invocation_id)} do
        {:consumed, result} when is_map(result) ->
          if successful?(result),
            do: {:ok, operation},
            else: {:error, :async_invocation_failed}

        _ ->
          {:error, :async_invocation_not_settled}
      end
    else
      _ -> {:error, :invalid_async_invocation}
    end
  end

  defp recover_run(writer, state, run, anchor, counts) do
    run
    |> Map.get(:execution_intents, %{})
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, counts}, fn
      {key, %{type: :tool, operation: operation} = intent}, {:ok, counts}
      when is_map(operation) ->
        if operation[:tool_name] in @tools do
          recover_intent(writer, state, run, anchor, key, intent, counts)
        else
          {:cont, {:ok, counts}}
        end

      _, acc ->
        {:cont, acc}
    end)
  end

  defp recover_intent(writer, state, run, anchor, key, intent, counts) do
    operation = intent.operation
    invocation_id = operation[:invocation_id]
    result = Map.get(Map.get(run, :tool_results, %{}), invocation_id)

    cond do
      not is_binary(invocation_id) or key != "tool:" <> invocation_id or
          operation[:run_id] != run.run_id ->
        {:halt, {:error, :invalid_async_runtime_record}}

      intent[:status] != :consumed or not is_map(result) ->
        {:cont, {:ok, %{counts | uncertain: counts.uncertain + 1}}}

      not successful?(result) ->
        {:cont, {:ok, counts}}

      true ->
        with {:ok, event} <- received(state.session_id, anchor, operation) do
          if Map.has_key?(state.projection.events, event["event_id"]) do
            if state.projection.events[event["event_id"]] == event,
              do: {:cont, {:ok, counts}},
              else: {:halt, {:error, :async_interaction_conflict}}
          else
            case append(writer, event, state.leaf_id) do
              {:ok, _} -> {:cont, {:ok, %{counts | recovered: counts.recovered + 1}}}
              error -> {:halt, error}
            end
          end
        else
          error -> {:halt, error}
        end
    end
  end

  defp received(session_id, anchor, operation) do
    origin = Map.new(@identity, &{Atom.to_string(&1), operation[&1]})
    origin = Map.put(origin, "branch_entry_id", anchor)

    identity =
      [
        session_id,
        origin["run_id"],
        origin["incarnation"],
        origin["invocation_id"],
        origin["tool_call_id"]
      ]
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    event = %{
      "version" => 1,
      "fact" => "received",
      "event_id" => "async_received_" <> identity,
      "item_id" => "async_item_" <> identity,
      "session_id" => session_id,
      "origin" => origin
    }

    with {:ok, payload} <- payload(operation) do
      AsyncInteractions.event(Map.merge(event, payload))
    end
  end

  defp payload(%{tool_name: "request_user_input_async", arguments: arguments})
       when is_map(arguments),
       do: {:ok, %{"questions" => arguments["questions"]}}

  defp payload(%{tool_name: "send_message_to_user_async", arguments: %{"message" => message}})
       when is_binary(message),
       do: {:ok, %{"message" => String.trim(message)}}

  defp payload(_), do: {:error, :invalid_async_runtime_record}

  defp event_matches?(%{type: :async_user_input_requested} = event, received),
    do:
      received["origin"]["tool_name"] == "request_user_input_async" and
        event[:questions] == received["questions"]

  defp event_matches?(%{type: :async_user_message} = event, received),
    do:
      received["origin"]["tool_name"] == "send_message_to_user_async" and
        event[:message] == received["message"]

  defp event_matches?(_, _), do: false

  defp successful?(result),
    do:
      result[:accepted] == true and result[:is_error] in [nil, false] and
        is_nil(result[:error])

  defp selected_branch(state) do
    index = apply(Sigma.Session.Journal.Index, :build, [state.entries])

    with {:ok, {_leaf, nodes}} <-
           apply(Sigma.Session.Journal.Index, :path, [index, state.leaf_id]) do
      runs =
        Enum.reduce(nodes, %{}, fn
          %{
            entry: %{
              "type" => "message",
              "id" => id,
              "message" => %{"role" => "user", "metadata" => metadata}
            }
          },
          runs
          when is_map(metadata) ->
            case metadata["turn_id"] do
              run_id when is_binary(run_id) and run_id != "" -> Map.put_new(runs, run_id, id)
              _ -> runs
            end

          _, runs ->
            runs
        end)

      {:ok, %{runs: runs, ids: MapSet.new(nodes, & &1.entry["id"])}}
    end
  end

  defp writer_state(writer),
    do: apply(Sigma.Session.Writer, :async_interaction_state, [writer])

  defp append(writer, event, leaf),
    do: apply(Sigma.Session.Writer, :append_async_interaction, [writer, event, leaf])
end
