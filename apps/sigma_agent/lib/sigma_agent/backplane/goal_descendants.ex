defmodule Sigma.Agent.Backplane.GoalDescendants do
  @moduledoc false

  alias Backplane.AgentRuntime.{Error, Kernel}
  alias Backplane.AgentRuntime.Store, as: RuntimeStore
  alias Sigma.Agent.Backplane.{LifetimeEvidence, RunRecovery, Store}

  def load(_writer, nil, _roots, _goal_id), do: {:ok, []}

  def load(writer, transcript, roots, goal_id) do
    with {:ok, %{admissions: admissions}} <-
           apply(Sigma.Session.Writer, :subagent_state, [writer]) do
      admissions
      |> Map.values()
      |> Enum.sort_by(& &1.intent.attempt_id)
      |> Enum.reduce_while({:ok, []}, fn admission, {:ok, loaded} ->
        case load_admission(admission, transcript, roots, goal_id) do
          {:ok, nil} -> {:cont, {:ok, loaded}}
          {:ok, child} -> {:cont, {:ok, loaded ++ [child]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  def acknowledge(%{store_path: path, snapshot: %{run: run}}) do
    with_store(path, fn store ->
      case RuntimeStore.store(Store, store, run, %{
             command:
               {:goal_outbox_acknowledged, System.system_time(:millisecond),
                %{
                  run_id: run.run_id,
                  incarnation: run.incarnation,
                  receipts: run.context.conversation.goal_outbox
                }}
           }) do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    end)
  end

  defp load_admission(%{intent: intent, receipts: receipts}, transcript, roots, goal_id) do
    cond do
      receipts == [] ->
        conflict(intent, "child Goal admission outcome is unconfirmed")

      not Enum.any?(receipts, & &1.process_started) ->
        {:ok, nil}

      true ->
        runtime_id = intent.metadata["runtime_run_id"]
        origin = intent.metadata["origin_turn_id"]
        root = Enum.find(roots, &(&1.run_id == origin))
        path = Path.join([transcript <> ".subagents", intent.child_session_id, "runtime"])

        with true <- is_binary(runtime_id) and runtime_id != "",
             {:ok, snapshot} <- with_store(path, &Store.load(&1, runtime_id)) do
          case get_in(snapshot, [:run, :context, :conversation, :goal_outbox]) do
            outbox when outbox in [nil, []] ->
              {:ok, nil}

            [%{thread_id: thread, expected_goal_id: expected} | _] = outbox ->
              if is_map(root) and is_binary(thread) and thread != "" and
                   thread != root.thread_id and expected == goal_id and
                   Enum.all?(outbox, fn receipt ->
                     is_map(receipt) and receipt[:thread_id] == thread and
                       receipt[:expected_goal_id] == goal_id and
                       receipt[:run_id] == runtime_id and
                       receipt[:incarnation] == intent.incarnation
                   end) do
                with {:ok, snapshot} <-
                       reconcile_child(path, intent, root, thread, runtime_id, snapshot),
                     :ok <-
                       terminal_snapshot(
                         intent,
                         runtime_id,
                         snapshot,
                         path,
                         transcript,
                         root,
                         thread
                       ) do
                  {:ok,
                   %{
                     parent: root,
                     identity: %{
                       thread_id: thread,
                       run_id: runtime_id,
                       incarnation: intent.incarnation,
                       authority: %{run_id: runtime_id, grants: []}
                     },
                     snapshot: snapshot,
                     store_path: path
                   }}
                end
              else
                conflict(intent, "child Goal receipt identity differs from the current Goal")
              end

            _ ->
              conflict(intent, "child Goal outbox is malformed")
          end
        else
          false -> conflict(intent, "child Goal admission has no indexed ordinary root run")
          {:error, _} = error -> error
        end
    end
  end

  defp reconcile_child(path, intent, root, thread, runtime_id, snapshot) do
    if Kernel.terminal?(snapshot.run.state) do
      {:ok, snapshot}
    else
      # Delegated Goal threads may use the runtime run ID. The component ledger
      # instead names the actual immutable child transcript header.
      transcript = Path.join(Path.dirname(path), "session.jsonl")

      with {:ok, %{header: %{"id" => child_header}}}
           when is_binary(child_header) and child_header != "" <-
             apply(Sigma.Session.Log, :snapshot, [transcript]) do
        identity = %{
          thread_id: thread,
          root_thread_id: root.thread_id,
          child_header_id: child_header,
          child_session_id: intent.child_session_id,
          run_id: runtime_id,
          incarnation: intent.incarnation
        }

        with_store(path, &RunRecovery.reconcile_child(&1, identity, snapshot))
      else
        {:error, _} = error -> error
        _ -> conflict(intent, "child recovery transcript identity is unavailable")
      end
    end
  end

  defp terminal_snapshot(
         intent,
         runtime_id,
         %{run: %{state: :unknown_outcome}} = snapshot,
         path,
         transcript,
         root,
         thread
       ) do
    with {:ok, %{header: %{"id" => child_header}}} <-
           apply(Sigma.Session.Log, :snapshot, [Path.join(Path.dirname(path), "session.jsonl")]) do
      identity = %{
        thread_id: thread,
        root_thread_id: root.thread_id,
        child_header_id: child_header,
        child_session_id: intent.child_session_id,
        run_id: runtime_id,
        incarnation: intent.incarnation
      }

      with_store(path, &LifetimeEvidence.allow_child(&1, identity, snapshot, transcript))
    end
  end

  defp terminal_snapshot(
         intent,
         runtime_id,
         %{run: run} = snapshot,
         _path,
         _transcript,
         _root,
         _thread
       ) do
    intents = Map.get(run, :execution_intents, %{})

    # A public Store fence advances the ordinary run's current incarnation.
    # Retained receipts keep the exact incarnation admitted in the Writer.
    if run.run_id == runtime_id and is_integer(run.incarnation) and
         run.incarnation >= intent.incarnation and
         run.state in [:completed, :failed, :cancelled, :timed_out] and
         Kernel.cleanup_requirements(run) ==
           %{provider: nil, tools: [], children: [], dependencies: []} and
         snapshot.effects == [] and snapshot.outbox == [] and is_map(intents) and
         Enum.all?(intents, fn {_id, entry} ->
           is_map(entry) and entry[:status] in [:consumed, :cancelled]
         end),
       do: :ok,
       else: conflict(intent, "child Goal run is not confirmed terminal and settled")
  end

  defp with_store(path, fun) do
    case Store.start_link(path: path) do
      {:ok, store} ->
        try do
          fun.(store)
        after
          GenServer.stop(store, :normal)
        end

      {:error, {:already_started, store}} ->
        fun.(store)

      {:error, _} = error ->
        error
    end
  end

  defp conflict(intent, message),
    do:
      {:error,
       Error.new(:resource_conflict, message,
         details: %{attempt_id: intent.attempt_id, run_id: intent.metadata["runtime_run_id"]}
       )}
end
