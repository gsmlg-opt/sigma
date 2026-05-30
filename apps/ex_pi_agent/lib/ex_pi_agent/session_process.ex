defmodule PiAgent.SessionProcess do
  @moduledoc """
  Owns long-lived session lifecycle state around a supervised `PiAgent`.
  """

  use GenServer

  defstruct [
    :repo_path,
    :session_id,
    :idle_timeout_ms,
    :idle_timer,
    :last_activity_at,
    :session_context,
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
    GenServer.cast(pid_or_name, {:record_event, event, on_event})
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

  @impl true
  def handle_cast({:record_event, event, on_event}, state) do
    if is_function(on_event, 1), do: on_event.(event)

    state =
      state
      |> apply_event(event)
      |> Map.update!(:event_count, &(&1 + 1))

    {:noreply, state}
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
