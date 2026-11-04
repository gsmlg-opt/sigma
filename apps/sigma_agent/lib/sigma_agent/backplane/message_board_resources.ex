defmodule Sigma.Agent.Backplane.MessageBoardResources do
  @moduledoc """
  Native message-board adapter for the actual Sigma collaboration tree.

  The current Session and trusted Subagents host select the actor, membership and
  immutable journal root. The shared writer commits first. Notifications then use
  the public manager's exact active-turn identities; they never start idle work
  or enter an ordinary queued-message path. As in Codex, a notification failure
  is reported to the host log after the post succeeds, without retrying either
  effect or changing the committed metadata result.
  """

  require Logger

  alias Backplane.AgentRuntime.Error
  alias Backplane.AgentRuntime.Codex.{MultiAgent, Session}
  alias Sigma.Agent.Backplane.MessageBoardStore
  alias Sigma.Agent.Subagents
  alias Sigma.Session.Writer

  def execute(
        %{tool_name: "collaboration::" <> name, arguments: args} = operation,
        _scope,
        %{archive: %{host: host, agent_name: agent_name} = archive, binding: binding}
      ) do
    with {:ok, _} <- Session.validate(binding, operation),
         {:ok, tree} <- Subagents.message_board_context(host, agent_name, operation),
         {:ok, root_id} <- journal_identity(tree.writer),
         {:ok, store} <-
           MessageBoardStore.open(root_transcript: archive.root_transcript, root_id: root_id),
         metadata <- %{
           root_id: root_id,
           agent_id: tree.caller.agent_id,
           agent_path: tree.caller.agent_path,
           agents: tree.agents,
           timestamp: DateTime.to_iso8601(DateTime.utc_now()),
           invocation_id: operation.invocation_id,
           message_id: if(name == "post", do: uuid())
         },
         {:ok, result, intents} <-
           MessageBoardStore.execute(store, %{name: name, arguments: args}, metadata) do
      deliver(tree, operation, intents)
      {:ok, result}
    else
      {:error, %Error{}} = error -> error
      {:error, reason} -> error(:execution_failure, "message-board host is unavailable", reason)
    end
  catch
    :exit, reason ->
      error(:unknown_outcome, "message-board host call did not acknowledge", reason)
  end

  def execute(_operation, _scope, _context),
    do: error(:unsupported_capability, "message board requires the current root archive")

  defp journal_identity(writer) do
    with {:ok, %{entries: entries}} <- apply(Writer, :selected_journal, [writer]) do
      case Enum.filter(entries, &(&1["type"] == "session")) do
        [%{"id" => id}] when is_binary(id) and id != "" -> {:ok, id}
        _ -> error(:malformed_result, "message board requires an immutable journal header")
      end
    end
  end

  defp deliver(_tree, _operation, []), do: :ok

  defp deliver(tree, operation, intents) do
    case manager_snapshot(tree.manager) do
      {:ok, snapshot} ->
        Enum.each(intents, fn intent ->
          case recipient(tree, snapshot, intent["recipient_id"]) do
            nil -> :ok
            identity -> notify(tree.manager, operation, identity, intent)
          end
        end)

      {:error, reason} ->
        delivery_error(reason)
    end
  catch
    :exit, reason -> delivery_error(reason)
  end

  defp manager_snapshot(nil), do: {:ok, nil}
  defp manager_snapshot(manager), do: MultiAgent.snapshot(manager)

  defp recipient(_tree, nil, _id), do: nil

  defp recipient(%{root_agent_id: id, root_binding: binding}, snapshot, id)
       when is_map(binding),
       do: %{
         manager_id: snapshot.manager_id,
         agent_id: snapshot.root.agent_id,
         run_id: binding.run_id,
         incarnation: binding.run_incarnation
       }

  defp recipient(_tree, snapshot, id) do
    Enum.find_value(snapshot.agents, fn agent ->
      if get_in(agent, [:host_metadata, :agent_id]) == id do
        agent
        |> Map.take([:agent_id, :run_id, :incarnation])
        |> Map.put(:manager_id, snapshot.manager_id)
      end
    end)
  end

  defp notify(manager, operation, recipient, intent) do
    post = intent["post"]

    id =
      [post["message_id"], intent["recipient_id"]]
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    notification = %{
      id: "board-" <> id,
      text:
        "<agent_message_board_notification>\n" <>
          Jason.encode!(post) <>
          "\n</agent_message_board_notification>",
      metadata: %{"message_board" => post}
    }

    case MultiAgent.notify_active(manager, operation, recipient, notification) do
      {:ok, _receipt} -> :ok
      {:error, reason} -> delivery_error(reason)
    end
  catch
    :exit, reason -> delivery_error(reason)
  end

  defp delivery_error(reason) do
    Logger.warning("Message-board post committed; active notification failed: #{inspect(reason)}")
    :ok
  end

  defp uuid do
    <<prefix::48, _::4, middle::12, _::2, suffix::62>> = :crypto.strong_rand_bytes(16)

    <<prefix::48, 4::4, middle::12, 2::2, suffix::62>>
    |> Base.encode16(case: :lower)
    |> then(fn <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
                 e::binary-size(12)>> ->
      Enum.join([a, b, c, d, e], "-")
    end)
  end

  defp error(class, message, cause \\ nil),
    do: {:error, Error.new(class, message, cause: cause)}
end
