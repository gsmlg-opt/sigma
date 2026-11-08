defmodule Sigma.Agent.Backplane.PlainCommand do
  @moduledoc """
  Ordinary commands, with an independent native terminal for each PTY job.

  PTY commands inherit the existing Native helper environment, including its
  terminal variables. Native does not currently accept per-command environment
  overrides. Non-PTY execution retains LocalCommand's existing behavior.

  Owned Codex resources may request asynchronous startup. The stable command
  server then boots the same LocalCommand and terminal capabilities before
  serving commands, and reports the actual result to its resource owner.
  """

  use GenServer, restart: :temporary
  require Logger

  @behaviour Backplane.AgentRuntime.Command

  alias Backplane.AgentRuntime.{Command, Error}
  alias Backplane.AgentRuntime.Tools.LocalCommand
  alias Sigma.Agent.Backplane.PtyJob
  alias Sigma.Coding.Terminal.Native

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  def command(server, opts \\ []) do
    opts
    |> Map.new()
    |> Map.put(:adapter, __MODULE__)
    |> Map.put(:server, server)
    |> Map.put_new(:allowed_environment, %{})
    |> Command.new()
  end

  def stop(server) do
    with :ok <- GenServer.call(server, :close, :infinity),
         do: GenServer.stop(server, :normal, :infinity)
  end

  @impl Command
  def start(command, request, opts) do
    if Map.get(request, :tty, false) do
      GenServer.call(command.server, {:start_pty, request}, :infinity)
    else
      with {:ok, local} <- local(command), do: LocalCommand.start(local, request, opts)
    end
  end

  @impl Command
  def read(_command, invocation, %{pty_job: pid} = job, opts) do
    PtyJob.read(pid, invocation, job, Keyword.fetch!(opts, :cursor))
  end

  def read(command, invocation, job, opts) do
    with {:ok, local} <- local(command), do: LocalCommand.read(local, invocation, job, opts)
  end

  @impl Command
  def write(_command, invocation, %{pty_job: pid} = job, chars),
    do: PtyJob.write(pid, invocation, job, chars)

  def write(command, invocation, job, chars) do
    with {:ok, local} <- local(command), do: LocalCommand.write(local, invocation, job, chars)
  end

  @impl Command
  def cancel(command, invocation) do
    with {:ok, local} <- local(command),
         :ok <- LocalCommand.cancel(local, invocation) do
      GenServer.call(command.server, {:cancel, invocation})
    end
  end

  @impl Command
  def cancel_confirmed(command, invocation, timeout) do
    case GenServer.call(command.server, {:session, invocation}) do
      {:ok, nil} ->
        :ok

      {:ok, pid} ->
        PtyJob.cancel_confirmed(pid, timeout)

      :local ->
        with {:ok, local} <- local(command),
             do: LocalCommand.cancel_confirmed(local, invocation, timeout)

      error ->
        error
    end
  end

  @impl Command
  def reserve(command, invocation) do
    if Map.get(invocation, :tty, false) do
      GenServer.call(command.server, {:reserve, invocation})
    else
      with {:ok, local} <- local(command), do: LocalCommand.reserve(local, invocation)
    end
  end

  @impl Command
  def acknowledge_release(command, invocation) do
    case GenServer.call(command.server, {:acknowledge, invocation}) do
      :local ->
        with {:ok, local} <- local(command),
             do: LocalCommand.acknowledge_release(local, invocation)

      result ->
        result
    end
  end

  @impl Command
  def validate_refusal(command, invocation, error) do
    with {:ok, local} <- local(command),
         do: LocalCommand.validate_refusal(local, invocation, error)
  end

  @impl Command
  def capabilities(command), do: GenServer.call(command.server, :capabilities)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    owner = Keyword.get(opts, :owner_pid)

    state = %{
      local: nil,
      local_options: Keyword.put(Keyword.get(opts, :local, []), :name, nil),
      native: Keyword.get(opts, :native, []),
      capabilities: %{},
      startup_error: nil,
      startup_owner: owner,
      sessions: %{},
      jobs: %{},
      closed?: false,
      owner_monitor: if(is_pid(owner), do: Process.monitor(owner)),
      released_floor: 0
    }

    if Keyword.get(opts, :async_start, false) do
      {:ok, state, {:continue, :start_command}}
    else
      case start_command(state) do
        {:ok, state} -> {:ok, state}
        {:error, reason} -> {:stop, reason}
      end
    end
  end

  @impl true
  def handle_continue(:start_command, state) do
    case start_command(state) do
      {:ok, state} ->
        notify_startup(state, :ok)
        {:noreply, state}

      {:error, reason} ->
        error = startup_error(reason)
        notify_startup(state, {:error, error})
        {:noreply, %{state | startup_error: error}}
    end
  end

  @impl true
  def handle_call(:local, _from, %{startup_error: %Error{} = error} = state),
    do: {:reply, {:error, error}, state}

  def handle_call(:local, _from, state), do: {:reply, state.local, state}
  def handle_call(:capabilities, _from, state), do: {:reply, state.capabilities, state}

  def handle_call({kind, _request}, _from, %{startup_error: %Error{} = error} = state)
      when kind in [:reserve, :start_pty],
      do: {:reply, {:error, error}, state}

  def handle_call({:reserve, invocation}, _from, state) do
    case reserve_session(state, invocation) do
      {:ok, next} -> {:reply, :ok, next}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:start_pty, request}, from, state) do
    with true <- Map.has_key?(state.capabilities, :pty),
         {:ok, next} <- reserve_session(state, request),
         {:ok, %{job: nil, status: :reserved}} <- session(next, request),
         {:ok, pid} <- PtyJob.start(request, next.native, from) do
      receipt = %{Map.fetch!(next.sessions, request.session_id) | job: pid, status: :launched}

      {:noreply,
       %{
         next
         | sessions: Map.put(next.sessions, request.session_id, receipt),
           jobs: Map.put(next.jobs, pid, request.session_id)
       }}
    else
      false ->
        {:reply, error(:unsupported_capability, "PTY execution is unavailable"), state}

      {:ok, _receipt} ->
        {:reply, error(:resource_conflict, "command session already launched"), state}

      {:error, %Error{}} = error ->
        {:reply, error, state}

      {:error, reason} ->
        {:reply, error(:execution_failure, "PTY startup failed", reason), state}
    end
  end

  def handle_call({:session, invocation}, _from, state) do
    case session(state, invocation) do
      {:ok, %{job: nil} = receipt} ->
        next = %{
          state
          | sessions:
              Map.put(state.sessions, invocation.session_id, %{receipt | status: :confirmed})
        }

        {:reply, {:ok, nil}, next}

      {:ok, receipt} ->
        {:reply, {:ok, receipt.job}, state}

      other ->
        {:reply, other, state}
    end
  end

  def handle_call({:cancel, invocation}, _from, state) do
    {:reply, :ok, cancel_owner(state, invocation.owner_run_id)}
  end

  def handle_call({:acknowledge, invocation}, _from, state) do
    case session(state, invocation) do
      {:ok, %{job: nil, status: :confirmed}} ->
        {:reply, :ok, retire(state, invocation.session_id, nil)}

      {:ok, %{job: nil}} ->
        {:reply, error(:unknown_outcome, "command release is unconfirmed"), state}

      {:ok, %{job: pid}} ->
        case PtyJob.release(pid) do
          :ok ->
            {:reply, :ok, retire(state, invocation.session_id, pid)}

          error ->
            {:reply, error, state}
        end

      result ->
        {:reply, result, state}
    end
  end

  def handle_call(:close, _from, state) do
    results = Enum.map(Map.keys(state.jobs), &PtyJob.cancel_confirmed(&1, 7_000))

    case Enum.find(results, &(&1 != :ok)) do
      nil -> {:reply, :ok, %{state | closed?: true}}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_monitor: ref} = state) do
    state =
      Enum.reduce(state.sessions, state, fn {_id, receipt}, current ->
        cancel_owner(current, receipt.owner)
      end)

    {:noreply, %{state | closed?: true}}
  end

  def handle_info({:EXIT, pid, reason}, %{local: pid} = state),
    do: {:stop, {:local_command_stopped, reason}, state}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(Map.keys(state.jobs), fn pid ->
      case PtyJob.cancel_confirmed(pid, 7_000) do
        :ok ->
          case PtyJob.release(pid) do
            :ok -> :ok
            error -> Logger.warning("PTY job retirement failed: #{inspect(error)}")
          end

        error ->
          Logger.warning("PTY command shutdown is unconfirmed: #{inspect(error)}")
      end
    end)

    if is_pid(state.local) and Process.alive?(state.local),
      do: GenServer.stop(state.local, :normal, :infinity)

    :ok
  end

  defp start_command(state) do
    with {:ok, local} <- LocalCommand.start_link(state.local_options) do
      capabilities =
        # TODO(upstream): gsmlg-opt/backplane#159 — enable {:unix, :darwin} once LocalCommand runs on macOS.
        case {:os.type(), Native.capabilities(state.native)} do
          {{:unix, :linux}, {:ok, %{real_pty: true}}} ->
            %{pty: %{verified: true, platforms: [{:unix, :linux}], rows: 24, columns: 120}}

          _ ->
            %{}
        end

      {:ok, %{state | local: local, capabilities: capabilities}}
    end
  end

  defp notify_startup(%{startup_owner: owner}, result) when is_pid(owner),
    do: send(owner, {:plain_command_startup, self(), result})

  defp notify_startup(_state, _result), do: :ok

  defp startup_error(%Error{} = error), do: error

  defp startup_error(reason),
    do: Error.new(:execution_failure, "local command runtime startup failed", cause: reason)

  defp reserve_session(%{closed?: true}, _invocation),
    do: error(:cancelled, "command host is closed")

  defp reserve_session(state, %{session_id: id} = invocation) when is_integer(id) and id > 0 do
    case session(state, invocation) do
      {:ok, %{status: :reserved}} ->
        {:ok, state}

      {:ok, _} ->
        error(:cancelled, "command session no longer accepts launch")

      :local when id <= state.released_floor ->
        error(:cancelled, "command session identity has expired")

      :local ->
        receipt = %{
          owner: invocation.owner_run_id,
          incarnation: Map.get(invocation, :incarnation, 1),
          job: nil,
          status: :reserved
        }

        {:ok, %{state | sessions: Map.put(state.sessions, id, receipt)}}

      error ->
        error
    end
  end

  defp reserve_session(_state, _invocation),
    do: error(:validation, "PTY command session is required")

  defp session(state, %{session_id: id, owner_run_id: owner} = invocation) do
    case Map.get(state.sessions, id) do
      nil ->
        :local

      %{owner: ^owner, incarnation: incarnation} = receipt ->
        if incarnation == Map.get(invocation, :incarnation, 1),
          do: {:ok, receipt},
          else: error(:resource_conflict, "stale command session incarnation")

      _ ->
        error(:forbidden, "command session owner does not match")
    end
  end

  defp session(_state, _invocation), do: :local

  defp cancel_owner(state, owner) do
    sessions =
      Map.new(state.sessions, fn {id, receipt} ->
        if receipt.owner == owner do
          if is_pid(receipt.job), do: PtyJob.cancel(receipt.job)
          {id, if(is_nil(receipt.job), do: %{receipt | status: :confirmed}, else: receipt)}
        else
          {id, receipt}
        end
      end)

    %{state | sessions: sessions}
  end

  defp retire(state, id, pid),
    do: %{
      state
      | sessions: Map.delete(state.sessions, id),
        jobs: Map.delete(state.jobs, pid),
        released_floor: max(id, state.released_floor)
    }

  defp local(command) do
    case GenServer.call(command.server, :local) do
      pid when is_pid(pid) -> {:ok, %{command | adapter: LocalCommand, server: pid}}
      {:error, _} = error -> error
    end
  end

  defp error(class, message, cause \\ nil), do: {:error, Error.new(class, message, cause: cause)}
end
