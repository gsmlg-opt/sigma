defmodule Sigma.Agent.SessionProcess do
  @moduledoc """
  Owns long-lived session lifecycle state around a supervised `Sigma.Agent`.
  """

  use GenServer

  defstruct [
    :repo_path,
    :session_id,
    :idle_timeout_ms,
    :idle_timer,
    :last_activity_at,
    :session_context,
    :on_state_change,
    :writer,
    messages: [],
    last_compaction: nil,
    compaction_count: 0,
    status: :starting,
    event_count: 0
  ]

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def status(pid_or_name) do
    GenServer.call(pid_or_name, :status)
  end

  def record_event(pid_or_name, event, on_event) do
    GenServer.call(pid_or_name, {:record_event, event, on_event}, :infinity)
  end

  @doc """
  Applies and persists a model change through the session mailbox.
  """
  def change_model(pid_or_name, agent, provider_id, model_id, provider, model, options)
      when is_pid(agent) and is_atom(provider) and is_map(model) do
    GenServer.call(
      pid_or_name,
      {:change_model, agent, provider_id, model_id, provider, model, options},
      :infinity
    )
  end

  def await_hibernating(pid_or_name, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_status(pid_or_name, :hibernating, deadline)
  end

  @impl true
  def init(opts) do
    now = System.monotonic_time(:millisecond)

    state = %__MODULE__{
      repo_path: Keyword.fetch!(opts, :repo_path),
      session_id: Keyword.fetch!(opts, :session_id),
      idle_timeout_ms: Keyword.fetch!(opts, :idle_timeout_ms),
      last_activity_at: now,
      session_context: Keyword.get(opts, :session_context),
      on_state_change: Keyword.get(opts, :on_state_change),
      writer: Keyword.get(opts, :writer),
      messages: Keyword.get(opts, :messages, []),
      status: :active
    }

    {:ok, schedule_idle(state)}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       repo_path: state.repo_path,
       session_id: state.session_id,
       status: state.status,
       event_count: state.event_count,
       last_activity_at: state.last_activity_at,
       message_count: length(state.messages),
       session_context?: not is_nil(state.session_context),
       compaction_count: state.compaction_count,
       last_compaction: state.last_compaction
     }, state}
  end

  def handle_call(
        {:change_model, agent, provider_id, model_id, provider, model, options},
        _from,
        state
      ) do
    event = {:model_change, provider_id, model_id}

    case state_change_persist(state, event) do
      {:ok, persist} ->
        case safely(fn -> Sigma.Agent.change_provider(agent, provider, model, options, persist) end) do
          :ok ->
            {:reply, :ok, apply_recorded_event(state, event)}

          {:ok, _result} = success ->
            {:reply, success, apply_recorded_event(state, event)}

          {:error, _reason} = error ->
            {:reply, error, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:record_event, event, on_event}, _from, state) do
    case persist_recorded_event(state, event, on_event) do
      :ok -> {:reply, :ok, apply_recorded_event(state, event)}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info(:hibernate_if_idle, state) do
    if state.status == :turn_running do
      {:noreply, schedule_idle(state)}
    else
      state = %{state | idle_timer: nil, status: :hibernating}
      {:noreply, state, :hibernate}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp safely(fun) do
    fun.()
  rescue
    exception -> {:error, {:state_change_exception, exception.__struct__}}
  catch
    kind, reason -> {:error, {:state_change_failure, kind, reason}}
  end

  defp state_change_persist(%{on_state_change: on_state_change}, event)
       when is_function(on_state_change, 1) do
    {:ok, fn -> on_state_change.(event) end}
  end

  defp state_change_persist(%{writer: writer}, event) when not is_nil(writer) do
    {:ok,
     fn ->
       case apply(Sigma.Session.Writer, :append, [writer, event]) do
         {:ok, _entry_id} = success -> success
         {:error, _reason} = error -> error
         :ignored -> {:error, :state_change_not_durable}
       end
     end}
  end

  defp state_change_persist(_state, _event),
    do: {:error, :state_change_persistence_not_configured}

  defp persist_recorded_event(%{writer: writer}, event, on_event) when not is_nil(writer) do
    case safely_writer_append(writer, event) do
      {:ok, _entry_id} ->
        notify_event(on_event, event)
        :ok

      :ignored ->
        notify_event(on_event, event)
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp persist_recorded_event(_state, event, on_event) do
    case notify_event(on_event, event) do
      {:error, _reason} = error -> error
      _result -> :ok
    end
  end

  defp safely_writer_append(writer, event) do
    apply(Sigma.Session.Writer, :append, [writer, event])
  catch
    :exit, reason -> {:error, {:session_writer_unavailable, reason}}
  end

  defp notify_event(on_event, event) when is_function(on_event, 1) do
    on_event.(event)
  rescue
    exception -> {:error, {:event_callback_exception, exception.__struct__}}
  catch
    kind, reason -> {:error, {:event_callback_failure, kind, reason}}
  end

  defp notify_event(_on_event, _event), do: :ok

  defp apply_recorded_event(state, event) do
    state
    |> apply_event(event)
    |> Map.update!(:event_count, &(&1 + 1))
  end

  defp apply_event(state, {:turn_start}) do
    touch(%{state | status: :turn_running})
  end

  defp apply_event(state, {:agent_end, messages}) do
    touch(%{state | status: :active, messages: messages})
  end

  defp apply_event(state, {:compact, summary_msg, first_kept_id}) do
    %{
      state
      | compaction_count: state.compaction_count + 1,
        last_compaction: %{
          summary_id: Map.get(summary_msg, :id),
          first_kept_id: first_kept_id
        }
    }
  end

  defp apply_event(state, {:turn_cancelled}) do
    touch(%{state | status: :active})
  end

  defp apply_event(state, {:turn_error, _reason}) do
    touch(%{state | status: :active})
  end

  defp apply_event(state, {:message_start, %{role: :user}}) do
    touch(%{state | status: :turn_running})
  end

  defp apply_event(state, {:message_end, message}) do
    messages =
      if Enum.any?(state.messages, &(&1.id == message.id)),
        do: state.messages,
        else: state.messages ++ [message]

    %{state | messages: messages}
  end

  defp apply_event(state, _event), do: state

  defp touch(state) do
    state
    |> cancel_idle()
    |> Map.put(:last_activity_at, System.monotonic_time(:millisecond))
    |> schedule_idle()
  end

  defp schedule_idle(%{idle_timeout_ms: timeout_ms} = state)
       when is_integer(timeout_ms) and timeout_ms > 0 do
    %{state | idle_timer: Process.send_after(self(), :hibernate_if_idle, timeout_ms)}
  end

  defp schedule_idle(state), do: state

  defp cancel_idle(%{idle_timer: nil} = state), do: state

  defp cancel_idle(%{idle_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | idle_timer: nil}
  end

  defp await_status(pid_or_name, expected, deadline) do
    case status(pid_or_name) do
      %{status: ^expected} ->
        :ok

      _status ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(10)
          await_status(pid_or_name, expected, deadline)
        end
    end
  end
end
