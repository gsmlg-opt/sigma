defmodule Sigma.Agent.Backplane.ChildInteractionResponder do
  @moduledoc """
  Opt-in host for checkpointed managed-child interactions on the public manager API.

  `attach/2` subscribes and recovers current pending requests. The trusted
  `request_fn` receives `(correlation, request, current?)` in an owned worker;
  user-input replies must be `{:ok, answer}`, Runtime permission replies must be
  `:approved` or `:denied`. Only known envelope keys are converted from the
  manager's JSON representation; operation data stays JSON-shaped.

  Snapshot guards and `MultiAgent.resolve_interaction/3` fence answers by manager,
  child, run, incarnation and interaction. A submitted or failed request is never
  automatically replayed. Observation gaps recover live pending requests only.
  Owner/manager loss stops workers and their monitored host waits. External
  settlement stops waiting handlers; submitted workers await acknowledgement.
  An unavailable observer snapshot reports `:observation_unavailable` without removing
  active waiters. A handler that has never started may recover after a later
  authenticated snapshot. Once a handler starts, observation uncertainty is
  reported without automatically replaying its answer or callback.

  Handler cancellation, invalid answers and handler loss use the published
  `MultiAgent.cancel_interaction/3` with that same exact correlation. Success
  acknowledges terminal persistence and resource cleanup; dispatched effects
  can still produce `:unknown_outcome`. Submitted calls survive terminal
  observations until their acknowledgement arrives. Lost acknowledgements are
  reported once as uncertainty and never replayed. The embedding host retains
  responsibility for its whole owned Session lifecycle; this adapter never
  interrupts by name or reaches into private child processes. No production tools
  are enabled here.
  Sigma policy's separate `:sigma_tool_permission` replies cross the manager as
  strict JSON allow/deny/map-edit envelopes, decoded by trusted child preparation.
  They never fall through to the independent Runtime permission handler.
  """

  use GenServer

  alias Backplane.AgentRuntime.Codex.MultiAgent
  alias Backplane.AgentRuntime.{Conversation, Error}
  alias Sigma.Agent.Backplane.ChildPermission

  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def attach(pid, manager), do: GenServer.call(pid, {:attach, manager}, :infinity)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner_pid)
    request = Keyword.fetch!(opts, :request_fn)

    if is_pid(owner) and is_function(request, 3) do
      {:ok,
       %{
         owner: Process.monitor(owner),
         subscriber: Keyword.fetch!(opts, :subscriber),
         request: request,
         manager: nil,
         manager_monitor: nil,
         manager_id: nil,
         revision: 0,
         workers: %{},
         seen: MapSet.new()
       }}
    else
      {:stop, :invalid_child_interaction_options}
    end
  end

  @impl true
  def handle_call({:attach, manager}, _from, %{manager: nil} = state) when is_pid(manager) do
    case MultiAgent.subscribe(manager) do
      {:ok, snapshot} ->
        state = %{
          state
          | manager: manager,
            manager_monitor: Process.monitor(manager),
            manager_id: snapshot.manager_id
        }

        {:reply, :ok, reconcile(state, snapshot)}

      error ->
        {:reply, error, state}
    end
  catch
    :exit, _ -> {:reply, {:error, :manager_unavailable}, state}
  end

  def handle_call({:attach, _}, _from, state),
    do: {:reply, {:error, :already_attached}, state}

  def handle_call({:submit, key}, {pid, _}, state) do
    case state.workers[key] do
      %{pid: ^pid} -> {:reply, true, put_in(state, [:workers, key, :submitted], true)}
      _ -> {:reply, false, state}
    end
  end

  @impl true
  def handle_info(
        {:codex_collaboration, %{manager_id: id, revision: revision}},
        %{manager_id: id} = state
      )
      when revision > state.revision do
    # A snapshot authenticates event content and also covers missed revisions.
    case snapshot(state.manager) do
      {:ok, snapshot} ->
        {:noreply, reconcile(state, snapshot)}

      {:error, reason} ->
        send(
          state.subscriber,
          {:child_interaction_error, %{manager_id: state.manager_id},
           {:observation_unavailable, reason}}
        )

        {:noreply, state}
    end
  end

  def handle_info({:child_interaction_result, key, {:unstarted_observation_error, reason}}, state) do
    case state.workers[key] do
      nil ->
        {:noreply, state}

      worker ->
        send(
          state.subscriber,
          {:child_interaction_error, worker.pending.correlation,
           {:observation_unavailable, reason}}
        )

        state = stop_worker(state, key)
        {:noreply, %{state | seen: MapSet.delete(state.seen, key)}}
    end
  end

  def handle_info({:child_interaction_result, key, result}, state) do
    case state.workers[key] do
      nil ->
        {:noreply, state}

      worker ->
        if result != :ok,
          do:
            send(state.subscriber, {:child_interaction_error, worker.pending.correlation, result})

        {:noreply, stop_worker(state, key)}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{owner: ref} = state),
    do: {:stop, :normal, stop_workers(state)}

  def handle_info({:DOWN, ref, :process, _, _}, %{manager_monitor: ref} = state),
    do: {:stop, :normal, stop_workers(state)}

  def handle_info({:DOWN, ref, :process, _, _reason}, state) do
    case Enum.find(state.workers, fn {_, worker} -> worker.monitor == ref end) do
      nil ->
        {:noreply, state}

      {key, worker} ->
        state = %{state | workers: Map.delete(state.workers, key)}

        if worker.role == :handler and not worker.submitted do
          # A normal self-exit also abandons the request. Cancellation gets one
          # owned worker; failure after submission must never submit a second call.
          {:noreply, start_worker(state, worker.pending, :cancellation)}
        else
          send(
            state.subscriber,
            {:child_interaction_error, worker.pending.correlation, unknown_acknowledgement()}
          )

          {:noreply, state}
        end
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    stop_workers(state)
    :ok
  end

  defp reconcile(state, %{manager_id: id} = snapshot) when id == state.manager_id do
    pending =
      for %{status: :running, pending_interaction: %{correlation: correlation} = item} <-
            snapshot.agents,
          into: %{},
          do: {correlation, item}

    state =
      Enum.reduce(state.workers, state, fn {key, worker}, acc ->
        if worker.submitted or pending[key] === worker.pending,
          do: acc,
          else: stop_worker(acc, key)
      end)

    Enum.reduce(pending, %{state | revision: snapshot.revision}, fn {key, item}, acc ->
      if MapSet.member?(acc.seen, key), do: acc, else: start_worker(acc, item)
    end)
  end

  defp reconcile(state, _), do: stop_workers(state)

  defp start_worker(state, pending, role \\ :handler) do
    owner = self()
    key = pending.correlation

    {pid, monitor} =
      :erlang.spawn_opt(
        fn ->
          result =
            case role do
              :handler ->
                resolve(owner, state.manager, pending, state.request)

              :cancellation ->
                submit(owner, state.manager, key, {:cancel, "Host interaction handler failed"})
            end

          send(owner, {:child_interaction_result, key, result})
        end,
        [:link, :monitor]
      )

    worker = %{pid: pid, monitor: monitor, pending: pending, role: role, submitted: false}
    %{state | seen: MapSet.put(state.seen, key), workers: Map.put(state.workers, key, worker)}
  end

  defp resolve(owner, manager, pending, handler) do
    case current_status(manager, pending) do
      {:ok, true} ->
        case request(pending.request) do
          {:ok, request} ->
            case response(manager, pending, request, handler) do
              {action, _} = submission when action in [:answer, :cancel] ->
                submit(owner, manager, pending.correlation, submission)

              result ->
                result
            end

          error ->
            error
        end

      {:ok, false} ->
        :ok

      {:error, reason} ->
        {:unstarted_observation_error, reason}
    end
  end

  defp response(manager, pending, request, handler) do
    current? = fn ->
      case current_status(manager, pending) do
        {:ok, current?} -> current?
        {:error, reason} -> throw({:observation_unavailable, reason})
      end
    end

    with {:ok, answer} <- answer(handler.(pending.correlation, request, current?), request),
         {:ok, _public_answer} <- Conversation.public_interaction(answer),
         true <- current?.() do
      {:answer, answer}
    else
      false -> :ok
      {:error, :cancelled} -> {:cancel, "Host interaction cancelled"}
      {:error, :invalid_interaction_answer} -> {:cancel, "Host interaction answer was invalid"}
      {:error, _} -> {:cancel, "Host interaction handler failed"}
    end
  rescue
    _ -> {:cancel, "Host interaction handler failed"}
  catch
    :throw, {:observation_unavailable, reason} -> {:observation_unavailable, reason}
    _, _ -> {:cancel, "Host interaction handler failed"}
  end

  defp submit(owner, manager, correlation, action) do
    # Retain this worker across settlement observations so its acknowledgement
    # cannot be discarded. Mark before the public call, including caller death.
    if GenServer.call(owner, {:submit, correlation}, :infinity) do
      case action do
        {:answer, answer} -> MultiAgent.resolve_interaction(manager, correlation, answer)
        {:cancel, reason} -> MultiAgent.cancel_interaction(manager, correlation, reason)
      end
    else
      :ok
    end
  rescue
    _ -> unknown_acknowledgement()
  catch
    _, _ -> unknown_acknowledgement()
  end

  defp unknown_acknowledgement,
    do: {:error, Error.new(:unknown_outcome, "child interaction acknowledgement was lost")}

  defp request(%{"kind" => "request_user_input", "questions" => questions} = request)
       when map_size(request) == 2,
       do: {:ok, %{kind: :request_user_input, questions: questions}}

  defp request(%{"kind" => "permission", "operation" => operation} = request)
       when map_size(request) == 2 and is_map(operation),
       do: {:ok, %{kind: :permission, operation: operation}}

  defp request(%{"kind" => "sigma_tool_permission", "tool_call" => call} = request)
       when map_size(request) == 2 and is_map(call) and map_size(call) == 3 do
    case call do
      %{"id" => id, "name" => name, "arguments" => arguments}
      when is_binary(id) and is_binary(name) and (is_map(arguments) or is_binary(arguments)) ->
        if String.valid?(id) and String.valid?(name) and id != "" and name != "" do
          {:ok,
           %{kind: :sigma_tool_permission, tool_call: %{id: id, name: name, arguments: arguments}}}
        else
          {:error, :unsupported_interaction_request}
        end

      _ ->
        {:error, :unsupported_interaction_request}
    end
  end

  defp request(_), do: {:error, :unsupported_interaction_request}

  defp answer({:ok, %{answers: answers} = answer}, %{
         kind: :request_user_input,
         questions: questions
       })
       when is_map(answers) and map_size(answer) == 1 and is_list(questions) do
    ids = Enum.map(questions, & &1["id"])

    valid =
      ids != [] and Enum.all?(ids, &(is_binary(&1) and String.trim(&1) != "")) and
        length(Enum.uniq(ids)) == length(ids) and Enum.sort(Map.keys(answers)) == Enum.sort(ids) and
        Enum.all?(answers, fn {_, entry} ->
          case entry do
            %{answers: [text]} when map_size(entry) == 1 and is_binary(text) ->
              String.trim(text) != ""

            %{"answers" => [text]} when map_size(entry) == 1 and is_binary(text) ->
              String.trim(text) != ""

            _ ->
              false
          end
        end)

    if valid, do: {:ok, answer}, else: {:error, :invalid_interaction_answer}
  end

  defp answer(decision, %{kind: :permission}) when decision in [:approved, :denied],
    do: {:ok, decision}

  defp answer({:error, reason}, _), do: {:error, reason}

  defp answer(decision, %{kind: :sigma_tool_permission}) do
    case ChildPermission.encode(decision) do
      {:ok, envelope} -> {:ok, envelope}
      {:error, _} -> {:error, :invalid_interaction_answer}
    end
  end

  defp answer(_, _), do: {:error, :invalid_interaction_answer}

  defp current_status(manager, pending) do
    case snapshot(manager) do
      {:ok, %{manager_id: id, agents: agents}} ->
        {:ok,
         id == pending.correlation.manager_id and
           Enum.any?(agents, fn agent ->
             agent.status == :running and agent.pending_interaction === pending
           end)}

      {:error, _} = error ->
        error
    end
  end

  defp snapshot(manager) do
    MultiAgent.snapshot(manager)
  catch
    :exit, _ -> {:error, :manager_unavailable}
  end

  defp stop_workers(state),
    do: Enum.reduce(Map.keys(state.workers), state, &stop_worker(&2, &1))

  defp stop_worker(state, key) do
    {worker, workers} = Map.pop(state.workers, key)
    Process.demonitor(worker.monitor, [:flush])
    Process.exit(worker.pid, :kill)
    %{state | workers: workers}
  end
end
