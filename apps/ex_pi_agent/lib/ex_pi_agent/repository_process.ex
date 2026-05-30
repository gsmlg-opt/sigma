defmodule PiAgent.RepositoryProcess do
  @moduledoc """
  Lightweight process that tracks runtime status for one repository.
  """

  use GenServer

  def start_link(opts) do
    repo_path = Keyword.fetch!(opts, :repo_path)
    GenServer.start_link(__MODULE__, repo_path, name: PiAgent.Runtime.via(repo_path, :process))
  end

  def get_session(pid, session_id, opts) do
    GenServer.call(pid, {:get_session, session_id, opts}, 30_000)
  end

  def status(pid) do
    GenServer.call(pid, :status)
  end

  @impl true
  def init(repo_path) do
    {:ok, %{repo_path: repo_path, sessions: %{}}}
  end

  @impl true
  def handle_call({:get_session, session_id, opts}, _from, state) do
    case Map.get(state.sessions, session_id) do
      %{session: session_pid} = handle when is_pid(session_pid) ->
        if Process.alive?(session_pid) do
          {:reply, {:ok, handle}, state}
        else
          start_session(session_id, opts, state)
        end

      _ ->
        start_session(session_id, opts, state)
    end
  end

  def handle_call(:status, _from, state) do
    sessions =
      state.sessions
      |> Enum.reject(fn {_id, handle} -> stale_session?(handle) end)
      |> Map.new(fn {id, handle} ->
        status =
          if Process.alive?(handle.session) do
            PiAgent.SessionProcess.status(handle.session)
          else
            %{status: :stopped}
          end

        {id, status}
      end)

    {:reply, %{repo_path: state.repo_path, status: :active, sessions: sessions}, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    sessions =
      Map.reject(state.sessions, fn {_session_id, handle} ->
        Map.get(handle, :monitor_ref) == ref
      end)

    {:noreply, %{state | sessions: sessions}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp start_session(session_id, opts, state) do
    repo_path = state.repo_path

    case PiAgent.RepositorySessionDynamicSupervisor.start_session(repo_path, session_id, opts) do
      {:ok, supervisor} ->
        handle = session_handle(repo_path, session_id, supervisor)
        {:reply, {:ok, handle}, put_in(state.sessions[session_id], handle)}

      {:error, {:already_started, supervisor}} ->
        handle = session_handle(repo_path, session_id, supervisor)
        {:reply, {:ok, handle}, put_in(state.sessions[session_id], handle)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp session_handle(repo_path, session_id, supervisor) do
    handle = %{
      repo_path: repo_path,
      session_id: session_id,
      repository: PiAgent.Runtime.lookup(repo_path, :process),
      session_supervisor: supervisor,
      session: PiAgent.Runtime.lookup(repo_path, session_id, :session),
      agent: PiAgent.Runtime.lookup(repo_path, session_id, :agent),
      policy: PiAgent.Runtime.lookup(repo_path, session_id, :policy),
      tasks: PiAgent.Runtime.lookup(repo_path, session_id, :tasks)
    }

    Map.put(handle, :monitor_ref, Process.monitor(supervisor))
  end

  defp stale_session?(%{session: session_pid}),
    do: not (is_pid(session_pid) and Process.alive?(session_pid))
end
