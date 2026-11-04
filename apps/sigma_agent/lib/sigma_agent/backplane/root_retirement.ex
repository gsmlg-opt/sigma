defmodule Sigma.Agent.Backplane.RootRetirement do
  @moduledoc """
  Root host component receipts, independent of Kernel and Goal settlement.

  The Agent keeps the original hook acknowledgements and SessionEnd attempt
  across receipt-write failures. Only native close and persistence are retryable;
  retrying a missing acknowledgement must never execute SessionEnd again.
  """

  require Logger

  alias Backplane.AgentRuntime.{Error, Kernel}
  alias Sigma.Agent.Backplane.{ChildIO, GoalRuns, Store}
  alias Sigma.Coding.Hooks.AsyncRuntime
  alias Sigma.Session.Writer

  def context(%{
        native_tools: true,
        writer: writer,
        transcript_path: path,
        backplane_store: store
      })
      when not is_nil(writer) and is_pid(store) and is_binary(path) and path != "" do
    with {:ok, %{entries: entries}} <- apply(Writer, :selected_journal, [writer]),
         %{"id" => header} when is_binary(header) and header != "" <-
           Enum.find(entries, &(&1["type"] == "session")) do
      {:ok,
       %{
         store: store,
         identity: %{
           root_header_id: header,
           transcript_header_id: header,
           child_session_id: nil,
           host_lifetime_id:
             "root-host-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
         }
       }}
    else
      {:error, cause} -> failure("root retirement journal is unavailable", cause)
      _ -> failure("root retirement requires its journal header", :missing_header)
    end
  catch
    :exit, cause -> failure("root retirement writer is unavailable", cause)
  end

  def context(_state), do: {:ok, nil}

  @doc "Reads only the current host's actual bindings and managed children before admission."
  def recovery_required?(%{host_retirement_facts: facts}) when map_size(facts) > 0,
    do: {:ok, true}

  def recovery_required?(state) do
    with {:ok, ledger} <- Store.host_retirement(state.backplane_store, :all),
         {:ok, root?} <- root_recovery_required?(state, ledger) do
      if root?, do: {:ok, true}, else: child_recovery_required?(state)
    end
  end

  defp root_recovery_required?(state, ledger) do
    lifetime = state.host_retirement.identity.host_lifetime_id
    host = ledger.hosts[lifetime]
    bindings = if host, do: host.bindings, else: %{}

    bindings
    |> Map.values()
    |> Enum.uniq_by(& &1.run_id)
    |> Enum.reduce_while({:ok, false}, fn binding, {:ok, required?} ->
      case Store.load(state.backplane_store, binding.run_id) do
        {:ok, snapshot} ->
          {:cont, {:ok, required? or not settled?(snapshot)}}

        {:error, %Error{class: :not_found}} = error ->
          # Goal preparation can close its reserved native binding before the
          # durable run index or Conversation exists. An indexed missing run
          # remains an error; only the exact unstarted, closed binding may pass.
          native = {binding.native_owner_id, binding.native_session_incarnation}

          with {:ok, indexed} <-
                 GoalRuns.list(state.goal_integration.root, state.goal_integration.thread_id),
               false <- Enum.any?(indexed, &(&1.run_id == binding.run_id)),
               %{status: :confirmed} <- host.native[native] do
            {:cont, {:ok, required?}}
          else
            {:error, _} = cause -> {:halt, cause}
            _ -> {:halt, error}
          end

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp child_recovery_required?(%{subagents: nil}), do: {:ok, false}

  defp child_recovery_required?(state) do
    with {:ok, sources} <- Sigma.Agent.Subagents.archive_sources(state.subagents) do
      # Old roster rows survive a replacement generation. Only children still
      # owned by this generation can require its retirement; a healthy active
      # child must remain available to ordinary followups.
      ids = MapSet.new(sources.children, & &1.identity.agent_id)

      same_host? =
        sources.root.host_lifetime_id == state.host_retirement.identity.host_lifetime_id

      unknown? =
        Enum.any?(sources.roster.agents, fn {_id, child} ->
          MapSet.member?(ids, child.agent_id) and
            (child.status in [:errored, :unknown_outcome] or child.closure == :unknown)
        end)

      cond do
        not is_nil(sources.error) ->
          failure("managed child host observation is unavailable", sources.error)

        not same_host? ->
          {:ok, false}

        unknown? ->
          {:ok, true}

        sources.generation_closed ->
          {:ok, false}

        sources.execution_closed ->
          {:ok, true}

        true ->
          Enum.reduce_while(sources.children, {:ok, false}, fn child, {:ok, required?} ->
            with {:ok, store} <- ChildIO.store(child.io),
                 {:ok, %{run: run} = snapshot} <- Store.load(store, child.identity.run_id) do
              unhealthy? =
                run.state == :unknown_outcome or
                  (Kernel.terminal?(run.state) and not settled?(snapshot))

              {:cont, {:ok, required? or unhealthy?}}
            else
              {:error, _} = error -> {:halt, error}
            end
          end)
      end
    end
  end

  defp settled?(%{run: run} = snapshot) do
    run.state in [:completed, :failed, :cancelled, :timed_out] and
      Kernel.cleanup_requirements(run) ==
        %{provider: nil, tools: [], children: [], dependencies: []} and
      snapshot.effects == [] and snapshot.outbox == [] and
      get_in(run, [:context, :conversation, :goal_outbox]) in [nil, []] and
      Enum.all?(run.execution_intents, fn {_id, intent} ->
        intent[:status] in [:consumed, :cancelled]
      end)
  end

  def close(state, previous, reason, opts \\ []) do
    native =
      confirmed(previous[:native]) ||
        call(fn ->
          if Keyword.get(opts, :native_close, true) do
            case state.subagents && Sigma.Agent.Subagents.close_execution(state.subagents) do
              nil -> {:ok, %{status: :confirmed}}
              :ok -> {:ok, %{status: :confirmed}}
              result -> result
            end
          else
            failure("active root native cleanup requires a responsive Agent", :active_termination)
          end
        end)

    hooks =
      previous[:async_hooks] ||
        call(fn -> AsyncRuntime.shutdown_confirmed(state.hook_async_runtime) end)

    session_end =
      previous[:session_end] ||
        if orderly?(reason),
          do: call(fn -> session_end(state) end),
          else: failure("SessionEnd was not dispatched after abnormal shutdown", reason)

    # A failed native close may still own an uncommitted binding. Do not seal
    # the lifetime before CodexResources has persisted that exact membership.
    {saved_hooks, saved_end} =
      if confirmed(native) do
        {persist(state.host_retirement, :async_hooks, hooks),
         persist(state.host_retirement, :session_end, session_end)}
      else
        {hooks, session_end}
      end

    result =
      with {:ok, %{status: :confirmed}} <- native,
           {:ok, %{status: :confirmed}} <- saved_hooks,
           {:ok, %{status: :confirmed}} <- saved_end do
        {:ok,
         %{status: :confirmed, capture: if(state.host_retirement, do: :durable, else: :disabled)}}
      else
        _ ->
          failure("root host components require reconciliation", %{
            native: native,
            async_hooks: saved_hooks,
            session_end: saved_end
          })
      end

    %{native: native, async_hooks: hooks, session_end: session_end, result: result}
  end

  def report(%{result: {:ok, %{status: :confirmed}}}), do: :ok

  def report(facts),
    do: Logger.error("[Sigma.Agent] Root host retirement is unconfirmed: #{inspect(facts)}")

  defp session_end(state) do
    flush =
      call(fn ->
        case state.writer && apply(Writer, :flush, [state.writer]) do
          nil -> :ok
          {:ok, _} -> :ok
          result -> result
        end
      end)

    with {:ok, runtime} <- AsyncRuntime.start(self()) do
      context =
        state
        |> Sigma.Agent.__backplane_hook_context__(state.turn_state.turn_id)
        |> Map.put(:hook_async_runtime, runtime)

      dispatch =
        call(fn ->
          {outcome, warnings} =
            Sigma.Coding.Hooks.dispatch(:session_end, state.hook_specs, context, %{
              reason: "other"
            })

          Enum.each(warnings, &Logger.warning("[hooks] #{&1}"))
          {:ok, %{status: :confirmed, dispatch: :completed, outcome: outcome, warnings: warnings}}
        end)

      cleanup = call(fn -> AsyncRuntime.shutdown_confirmed(runtime) end)

      with :ok <- flush,
           {:ok, completion} <- dispatch,
           {:ok, %{status: :confirmed}} <- cleanup do
        {:ok, completion}
      else
        _ ->
          failure("SessionEnd completion is unconfirmed", %{
            transcript_flush: flush,
            dispatch: dispatch,
            commands: cleanup
          })
      end
    end
  end

  defp persist(nil, _component, result), do: result

  defp persist(context, component, {:ok, %{status: :confirmed} = confirmation}) do
    case call(fn ->
           Store.record_host_retirement(context.store, context.identity, component, confirmation)
         end) do
      :ok -> {:ok, confirmation}
      error -> error
    end
  end

  defp persist(_context, _component, error), do: error

  defp confirmed({:ok, %{status: :confirmed}} = result), do: result
  defp confirmed(_result), do: nil

  defp call(fun) do
    fun.()
  rescue
    error -> failure("root retirement component raised", error)
  catch
    kind, cause -> failure("root retirement component is unavailable", {kind, cause})
  end

  defp orderly?(reason),
    do: reason in [:normal, :shutdown] or match?({:shutdown, _}, reason)

  defp failure(message, cause), do: {:error, Error.new(:unknown_outcome, message, cause: cause)}
end
