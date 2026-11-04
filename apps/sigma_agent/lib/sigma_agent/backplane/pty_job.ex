defmodule Sigma.Agent.Backplane.PtyJob do
  @moduledoc false

  use GenServer, restart: :temporary
  require Logger

  alias Backplane.AgentRuntime.Error
  alias Sigma.Coding.Terminal.Native

  @input_bytes 16 * 1024

  def start(request, native, from),
    do: GenServer.start(__MODULE__, {request, native, from, self()})

  def read(pid, invocation, job, cursor), do: call(pid, {:read, invocation, job, cursor})
  def write(pid, invocation, job, chars), do: call(pid, {:write, invocation, job, chars})
  def cancel(pid), do: GenServer.cast(pid, :cancel)
  def cancel_confirmed(pid, timeout), do: call(pid, {:cancel_confirmed, timeout}, timeout + 1_000)
  def release(pid), do: call(pid, :release)

  @impl true
  def init({request, native, from, host}) do
    Process.flag(:trap_exit, true)
    terminal = Map.get(request, :terminal) || %{rows: 24, columns: 120}

    opts =
      Keyword.merge(native,
        owner: self(),
        cwd: request.workspace,
        command: [request.executable | request.arguments],
        rows: terminal.rows,
        columns: terminal.columns
      )

    case Native.start_link(opts) do
      {:ok, backend} ->
        owner = Map.get(request, :owner_pid)

        {:ok,
         %{
           request: request,
           backend: backend,
           backend_monitor: Process.monitor(backend),
           host_monitor: Process.monitor(host),
           host_down?: false,
           backend_down?: false,
           owner_monitor: if(is_pid(owner), do: Process.monitor(owner)),
           launch_from: from,
           token: make_ref(),
           terminal: nil,
           timer: Process.send_after(self(), :deadline, request.deadline_limit),
           output: [],
           cursor: 0,
           bytes: 0,
           utf8_pending: <<>>,
           status: :starting,
           exit_status: nil,
           exit_signal: nil,
           terminal_status: nil,
           termination_status: :not_requested,
           cleanup_status: :not_started,
           cleanup_error: nil,
           cleanup_evidence: nil,
           cleanup_confirmed?: false,
           backend_error: nil,
           close_requested?: false,
           waiters: %{}
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:read, invocation, job, cursor}, _from, state) do
    with :ok <- identity(state, invocation, job) do
      output = state.output |> Enum.reverse() |> Enum.drop(cursor) |> IO.iodata_to_binary()

      result = %{
        output: if(output == "", do: [], else: [output]),
        cursor: state.cursor,
        status: state.status,
        exit_status: state.exit_status,
        exit_signal: state.exit_signal,
        termination_status: state.termination_status,
        cleanup_status: state.cleanup_status,
        cleanup_error: state.cleanup_error,
        cleanup_evidence: state.cleanup_evidence,
        output_limit_exceeded?: state.terminal_status == :output_limit_exceeded
      }

      if state.backend_error do
        {:reply,
         error(:execution_failure, "PTY output or backend failed", %{
           result: result,
           reason: inspect(state.backend_error)
         }), state}
      else
        {:reply, {:ok, result}, state}
      end
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:write, invocation, job, chars}, _from, state) do
    with :ok <- identity(state, invocation, job),
         true <- state.status == :running and not state.close_requested?,
         :ok <- input(state.backend, chars) do
      {:reply, :ok, state}
    else
      false ->
        {:reply, error(:execution_failure, "PTY command no longer accepts stdin"), state}

      {:error, %Error{}} = error ->
        {:reply, error, state}

      {:error, reason} ->
        {:reply, error(:execution_failure, "PTY stdin write failed", reason), state}
    end
  end

  def handle_call({:cancel_confirmed, _timeout}, _from, %{cleanup_status: :confirmed} = state),
    do: {:reply, :ok, state}

  def handle_call({:cancel_confirmed, _timeout}, _from, %{cleanup_status: :uncertain} = state),
    do: {:reply, cleanup_error(state), state}

  def handle_call({:cancel_confirmed, timeout}, from, state) do
    token = make_ref()
    timer = Process.send_after(self(), {:wait_timeout, token}, timeout)
    state = %{state | waiters: Map.put(state.waiters, token, {from, timer})}
    {:noreply, request_close(state, :cancelled)}
  end

  def handle_call(:release, _from, %{cleanup_status: :confirmed} = state),
    do: {:stop, :normal, :ok, state}

  def handle_call(:release, _from, state), do: {:reply, cleanup_error(state), state}

  @impl true
  def handle_cast(:cancel, state), do: {:noreply, request_close(state, :cancelled)}

  @impl true
  def handle_info({:terminal_backend, backend, {:started, resource}}, %{backend: backend} = state) do
    state = %{state | terminal: resource}

    if state.launch_from do
      GenServer.reply(
        state.launch_from,
        {:ok,
         %{
           pty_job: self(),
           token: state.token,
           owner_run_id: state.request.owner_run_id,
           owner_incarnation: Map.get(state.request, :incarnation, 1),
           session_id: state.request.session_id,
           terminal: resource,
           request: state.request
         }}
      )
    end

    {:noreply,
     %{
       state
       | launch_from: nil,
         status: if(state.close_requested?, do: state.status, else: :running)
     }}
  end

  def handle_info(
        {:terminal_backend, backend, {:output, _seq, bytes}},
        %{backend: backend} = state
      ) do
    remaining = max(state.request.output_limit - state.bytes, 0)
    accepted = binary_part(bytes, 0, min(remaining, byte_size(bytes)))

    state =
      append_output(
        %{
          state
          | bytes: state.bytes + byte_size(accepted)
        },
        accepted
      )

    state =
      if byte_size(bytes) > remaining,
        do: request_close(state, :output_limit_exceeded),
        else: state

    {:noreply, state}
  end

  def handle_info(
        {:terminal_backend, backend, {:shell_exit, status, signal}},
        %{backend: backend} = state
      ) do
    Process.cancel_timer(state.timer)
    terminal_status = state.terminal_status || :completed

    {:noreply,
     %{
       state
       | exit_status: status,
         exit_signal: signal,
         terminal_status: terminal_status,
         status: terminal_status,
         cleanup_status: :pending
     }}
  end

  def handle_info(
        {:terminal_backend, backend, {:cleanup, result, evidence}},
        %{backend: backend} = state
      ) do
    Process.cancel_timer(state.timer)

    state =
      case result do
        {:ok, :confirmed} ->
          # The helper can still report a failed output drain after cleanup.
          # Keep the public handle until its final events have been consumed.
          %{
            state
            | cleanup_confirmed?: true,
              cleanup_status: :pending,
              cleanup_evidence: evidence
          }

        _ ->
          %{
            state
            | cleanup_status: :uncertain,
              cleanup_evidence: evidence,
              cleanup_error: inspect(result),
              status: :cleanup_failed
          }
      end

    {:noreply, state |> fail_pending_launch() |> reply_waiters()}
  end

  def handle_info(
        {:terminal_backend, backend, {:backend_failed, reason}},
        %{backend: backend} = state
      ) do
    state = %{state | backend_error: reason, status: :failed}

    state =
      if state.cleanup_confirmed?,
        do: state,
        else: %{state | cleanup_status: :uncertain, cleanup_error: inspect(reason)}

    {:noreply, state |> fail_pending_launch() |> reply_waiters()}
  end

  def handle_info({:close_result, result}, state) do
    state =
      if result != {:ok, :confirmed} and state.cleanup_status != :confirmed do
        %{
          state
          | cleanup_status: :uncertain,
            cleanup_error: inspect(result),
            status: :cleanup_failed
        }
      else
        state
      end

    {:noreply, reply_waiters(state)}
  end

  def handle_info(:deadline, state), do: {:noreply, request_close(state, :timeout)}

  def handle_info({:wait_timeout, token}, state) do
    case Map.pop(state.waiters, token) do
      {nil, _} ->
        {:noreply, state}

      {{from, _timer}, waiters} ->
        GenServer.reply(from, cleanup_error(state))
        {:noreply, %{state | waiters: waiters}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{backend_monitor: ref} = state) do
    state = state |> Map.put(:backend_down?, true) |> flush_output()

    state =
      if state.cleanup_confirmed? do
        %{
          state
          | cleanup_status: :confirmed,
            status:
              if(state.backend_error, do: :failed, else: state.terminal_status || :completed)
        }
      else
        %{
          state
          | cleanup_status: :uncertain,
            cleanup_error: inspect({:backend_down, reason}),
            status: :cleanup_failed
        }
      end

    state |> fail_pending_launch() |> reply_waiters() |> finish_orphan()
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{host_monitor: ref} = state) do
    state |> Map.put(:host_down?, true) |> request_close(:cancelled) |> finish_orphan()
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_monitor: ref} = state),
    do: {:noreply, request_close(state, :cancelled)}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Process.cancel_timer(state.timer)

    if state.cleanup_status == :confirmed and Process.alive?(state.backend),
      do: GenServer.stop(state.backend, :normal)

    :ok
  end

  defp identity(state, invocation, job) do
    cond do
      Map.get(job, :token) != state.token or job.pty_job != self() ->
        error(:not_found, "PTY command job is unknown")

      invocation.owner_run_id != state.request.owner_run_id ->
        error(:forbidden, "command job owner does not match")

      Map.get(invocation, :incarnation, 1) != Map.get(state.request, :incarnation, 1) ->
        error(:resource_conflict, "stale command job incarnation")

      true ->
        :ok
    end
  end

  defp input(_backend, ""), do: :ok

  defp input(backend, bytes) when byte_size(bytes) <= @input_bytes,
    do: native_input(backend, bytes)

  defp input(backend, <<chunk::binary-size(@input_bytes), rest::binary>>) do
    with :ok <- native_input(backend, chunk), do: input(backend, rest)
  end

  defp native_input(backend, bytes) do
    Native.input(backend, bytes)
  catch
    :exit, reason -> {:error, {:backend_unavailable, reason}}
  end

  defp request_close(%{cleanup_status: :confirmed} = state, _status), do: state
  defp request_close(%{cleanup_status: :uncertain} = state, _status), do: state
  defp request_close(%{close_requested?: true} = state, _status), do: state

  defp request_close(state, status) do
    Process.cancel_timer(state.timer)
    owner = self()
    backend = state.backend

    Task.start(fn ->
      result =
        try do
          Native.close(backend)
        catch
          :exit, reason -> {:error, reason}
        end

      send(owner, {:close_result, result})
    end)

    %{
      state
      | close_requested?: true,
        terminal_status: state.terminal_status || status,
        status: state.terminal_status || status,
        termination_status: :requested,
        cleanup_status: :pending
    }
    |> fail_pending_launch()
  end

  defp append_output(state, bytes) do
    case :unicode.characters_to_binary(state.utf8_pending <> bytes, :utf8, :utf8) do
      valid when is_binary(valid) ->
        append_text(%{state | utf8_pending: <<>>}, valid)

      {:incomplete, valid, pending} ->
        append_text(%{state | utf8_pending: pending}, valid)

      {:error, valid, rest} ->
        <<_invalid, tail::binary>> = rest
        state |> Map.put(:utf8_pending, <<>>) |> append_text(valid <> "�") |> append_output(tail)
    end
  end

  defp append_text(state, ""), do: state

  defp append_text(state, bytes),
    do: %{state | output: [bytes | state.output], cursor: state.cursor + 1}

  defp flush_output(%{utf8_pending: <<>>} = state), do: state
  defp flush_output(state), do: append_text(%{state | utf8_pending: <<>>}, "�")

  defp finish_orphan(%{host_down?: true, backend_down?: true} = state) do
    if state.cleanup_status != :confirmed,
      do:
        Logger.warning(
          "PTY host stopped with unconfirmed cleanup: #{inspect(state.cleanup_error)}"
        )

    if state.backend_error,
      do:
        Logger.warning("PTY host stopped after backend failure: #{inspect(state.backend_error)}")

    {:stop, :normal, state}
  end

  defp finish_orphan(state), do: {:noreply, state}

  defp fail_pending_launch(%{launch_from: nil} = state), do: state

  defp fail_pending_launch(state) do
    GenServer.reply(
      state.launch_from,
      error(:execution_failure, "PTY command did not start", state.cleanup_error)
    )

    %{state | launch_from: nil}
  end

  defp reply_waiters(%{cleanup_status: status} = state) when status in [:confirmed, :uncertain] do
    result = if status == :confirmed, do: :ok, else: cleanup_error(state)

    Enum.each(state.waiters, fn {_token, {from, timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, result)
    end)

    %{state | waiters: %{}}
  end

  defp reply_waiters(state), do: state

  defp cleanup_error(state),
    do: error(:unknown_outcome, "PTY command cleanup is unconfirmed", state.cleanup_error)

  defp error(class, message, details \\ nil),
    do: {:error, Error.new(class, message, details: %{evidence: details})}

  defp call(pid, message, timeout \\ 5_000) do
    GenServer.call(pid, message, timeout)
  catch
    :exit, reason -> error(:unknown_outcome, "PTY job is unavailable", inspect(reason))
  end
end
