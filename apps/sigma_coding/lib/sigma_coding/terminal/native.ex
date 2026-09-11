defmodule Sigma.Coding.Terminal.Native do
  @moduledoc "Managed PTY adapter for the packaged sigma terminal helper."

  use GenServer, restart: :temporary

  @behaviour Sigma.Coding.Terminal.Backend

  @max_input_bytes 16 * 1024
  @min_columns 2
  @max_columns 500
  @min_rows 1
  @max_rows 300
  @max_protocol_line_bytes 4 * 1024 * 1024
  @cleanup_timeout_ms 6_000

  defstruct [
    :port,
    :owner,
    :owner_ref,
    :helper_pid,
    :resource,
    :cleanup_result,
    :cleanup_timer,
    phase: :starting,
    close_waiters: []
  ]

  @impl true
  def capabilities(opts \\ []) do
    with :ok <- supported_platform(),
         {:ok, helper} <- helper_path(opts),
         :ok <- executable(helper) do
      {:ok,
       %{
         backend: :sigma_terminal_helper,
         helper: helper,
         managed_scope: :unix_session,
         real_pty: true,
         resize: true,
         checkpoints: true,
         independent_control_eof_cleanup: true,
         abrupt_helper_cleanup: false
       }}
    end
  end

  @impl true
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, Keyword.put_new(opts, :owner, self()))

  @impl true
  def resource(server), do: GenServer.call(server, :resource)

  @impl true
  def input(server, bytes) when is_binary(bytes), do: GenServer.call(server, {:input, bytes})

  @impl true
  def resize(server, columns, rows), do: GenServer.call(server, {:resize, columns, rows})

  @impl true
  def checkpoint(server, request_id) when is_binary(request_id),
    do: GenServer.call(server, {:checkpoint, request_id})

  @impl true
  def close(server, timeout \\ @cleanup_timeout_ms + 1_000),
    do: GenServer.call(server, :close, timeout)

  @impl true
  def init(opts) do
    owner = Keyword.get(opts, :owner, self())
    cwd = opts |> Keyword.get(:cwd, File.cwd!()) |> Path.expand()
    columns = Keyword.get(opts, :columns, 120)
    rows = Keyword.get(opts, :rows, 24)

    with {:ok, _capabilities} <- capabilities(opts),
         :ok <- valid_directory(cwd),
         :ok <- valid_dimensions(columns, rows),
         {:ok, command} <- shell_command(opts),
         {:ok, helper} <- helper_path(opts),
         {:ok, port} <- open_port(helper, cwd, columns, rows, command) do
      owner_ref = Process.monitor(owner)
      {:os_pid, helper_pid} = Port.info(port, :os_pid)

      {:ok,
       %__MODULE__{
         port: port,
         owner: owner,
         owner_ref: owner_ref,
         helper_pid: helper_pid,
         resource: %{helper_pid: helper_pid, phase: :starting}
       }}
    else
      {:error, reason} -> {:stop, {:shutdown, reason}}
    end
  end

  @impl true
  def handle_call(:resource, _from, state), do: {:reply, {:ok, state.resource}, state}

  def handle_call({:input, bytes}, _from, %{phase: :running} = state) do
    if byte_size(bytes) <= @max_input_bytes do
      {:reply, send_command(state, %{op: "input", data: Base.encode64(bytes)}), state}
    else
      {:reply, {:error, :input_too_large}, state}
    end
  end

  def handle_call({:input, _bytes}, _from, state),
    do: {:reply, {:error, input_error(state.phase)}, state}

  def handle_call({:resize, columns, rows}, _from, %{phase: :running} = state) do
    case valid_dimensions(columns, rows) do
      :ok -> {:reply, send_command(state, %{op: "resize", cols: columns, rows: rows}), state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:resize, _columns, _rows}, _from, state),
    do: {:reply, {:error, input_error(state.phase)}, state}

  def handle_call({:checkpoint, request_id}, _from, %{phase: phase} = state)
      when phase in [:running, :exited] do
    {:reply, send_command(state, %{op: "checkpoint", request_id: request_id}), state}
  end

  def handle_call({:checkpoint, _request_id}, _from, state),
    do: {:reply, {:error, input_error(state.phase)}, state}

  def handle_call(:close, _from, %{cleanup_result: result} = state) when not is_nil(result),
    do: {:reply, result, state}

  def handle_call(:close, from, %{phase: :closing} = state),
    do: {:noreply, %{state | close_waiters: [from | state.close_waiters]}}

  def handle_call(:close, from, state) do
    case send_command(state, %{op: "close"}) do
      :ok ->
        timer = Process.send_after(self(), :cleanup_timeout, @cleanup_timeout_ms)

        {:noreply, %{state | phase: :closing, cleanup_timer: timer, close_waiters: [from]}}

      {:error, _reason} ->
        result = {:error, :cleanup_unconfirmed}
        {:reply, result, %{state | phase: :failed, cleanup_result: result}}
    end
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    case Jason.decode(line) do
      {:ok, event} -> handle_helper_event(event, state)
      {:error, error} -> fail_protocol(state, {:invalid_helper_event, Exception.message(error)})
    end
  end

  def handle_info({port, {:data, {:noeol, _line}}}, %{port: port} = state),
    do: fail_protocol(state, :helper_event_too_large)

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    state =
      if is_nil(state.cleanup_result) do
        result = {:error, :cleanup_unconfirmed}
        notify(state, {:backend_failed, {:helper_exit, status}})
        finish_cleanup(state, result)
      else
        state
      end

    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info(:cleanup_timeout, %{cleanup_result: nil} = state) do
    result = {:error, :cleanup_unconfirmed}
    notify(state, {:cleanup, result, %{reason: :timeout}})
    {:noreply, finish_cleanup(%{state | cleanup_timer: nil}, result)}
  end

  def handle_info(:cleanup_timeout, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_reference(state.cleanup_timer), do: Process.cancel_timer(state.cleanup_timer)
    if is_port(state.port), do: safe_close(state.port)
    :ok
  end

  defp handle_helper_event(%{"event" => "started"} = event, state) do
    resource = %{
      helper_pid: state.helper_pid,
      pid: event["pid"],
      sid: event["sid"],
      started_at: event["started_at"],
      columns: event["cols"],
      rows: event["rows"],
      phase: :running
    }

    notify(state, {:started, resource})
    {:noreply, %{state | phase: :running, resource: resource}}
  end

  defp handle_helper_event(%{"event" => "output", "seq" => seq, "data" => data}, state) do
    case Base.decode64(data) do
      {:ok, bytes} ->
        notify(state, {:output, seq, bytes})
        {:noreply, state}

      :error ->
        fail_protocol(state, :invalid_output_base64)
    end
  end

  defp handle_helper_event(%{"event" => "resized", "cols" => columns, "rows" => rows}, state) do
    notify(state, {:resized, columns, rows})
    {:noreply, %{state | resource: Map.merge(state.resource, %{columns: columns, rows: rows})}}
  end

  defp handle_helper_event(%{"event" => "checkpoint"} = event, state) do
    case Base.decode64(event["data"]) do
      {:ok, bytes} ->
        notify(
          state,
          {:checkpoint, event["request_id"], event["seq"], event["cols"], event["rows"], bytes}
        )

        {:noreply, state}

      :error ->
        fail_protocol(state, :invalid_checkpoint_base64)
    end
  end

  defp handle_helper_event(%{"event" => "checkpoint_failed"} = event, state) do
    reason =
      case event["error"] do
        "snapshot_too_large" -> :snapshot_too_large
        _unknown -> :snapshot_unavailable
      end

    notify(
      state,
      {:checkpoint_failed, event["request_id"], reason, %{maximum_bytes: event["maximum_bytes"]}}
    )

    {:noreply, state}
  end

  defp handle_helper_event(%{"event" => "shell_exit"} = event, state) do
    notify(state, {:shell_exit, event["status"], event["signal"]})
    {:noreply, %{state | phase: :exited, resource: Map.put(state.resource, :phase, :exited)}}
  end

  defp handle_helper_event(%{"event" => "cleanup", "result" => evidence}, state) do
    result =
      if evidence["complete"] == true, do: {:ok, :confirmed}, else: {:error, :cleanup_unconfirmed}

    notify(state, {:cleanup, result, normalize_cleanup_evidence(evidence)})
    {:noreply, finish_cleanup(state, result)}
  end

  defp handle_helper_event(%{"event" => "fatal", "error" => error}, state) do
    notify(state, {:backend_failed, {:helper_fatal, error}})
    {:noreply, %{state | phase: :failed}}
  end

  defp handle_helper_event(event, state),
    do: fail_protocol(state, {:unknown_helper_event, event["event"]})

  defp finish_cleanup(state, result) do
    if is_reference(state.cleanup_timer), do: Process.cancel_timer(state.cleanup_timer)
    Enum.each(state.close_waiters, &GenServer.reply(&1, result))

    phase = if result == {:ok, :confirmed}, do: :closed, else: :failed

    %{
      state
      | cleanup_result: result,
        cleanup_timer: nil,
        close_waiters: [],
        phase: phase,
        resource: Map.put(state.resource, :phase, phase)
    }
  end

  defp fail_protocol(state, reason) do
    notify(state, {:backend_failed, reason})
    result = {:error, :cleanup_unconfirmed}
    {:noreply, finish_cleanup(%{state | phase: :failed}, result)}
  end

  defp normalize_cleanup_evidence(evidence) do
    %{
      complete: evidence["complete"] == true,
      elapsed_ms: evidence["elapsed_ms"],
      remaining: evidence["remaining"] || [],
      identity_conflict: evidence["identity_conflict"] == true
    }
  end

  defp notify(state, event), do: send(state.owner, {:terminal_backend, self(), event})

  defp send_command(%{port: port}, command) do
    Port.command(port, [Jason.encode_to_iodata!(command), ?\n])
    :ok
  rescue
    ArgumentError -> {:error, :backend_unavailable}
  end

  defp open_port(helper, cwd, columns, rows, command) do
    args = ["--cwd", cwd, "--rows", to_string(rows), "--cols", to_string(columns), "--" | command]

    {:ok,
     Port.open({:spawn_executable, helper}, [
       :binary,
       :exit_status,
       :use_stdio,
       {:line, @max_protocol_line_bytes},
       args: args
     ])}
  rescue
    error in ArgumentError -> {:error, {:startup_failed, Exception.message(error)}}
  end

  defp shell_command(opts) do
    case Keyword.get(opts, :command) do
      command when is_list(command) and command != [] and is_binary(hd(command)) -> {:ok, command}
      nil -> default_shell_command(opts)
      _ -> {:error, :invalid_command}
    end
  end

  defp default_shell_command(opts) do
    shell =
      Keyword.get(opts, :shell) || System.get_env("SHELL") || System.find_executable("zsh") ||
        System.find_executable("bash") || System.find_executable("sh")

    cond do
      is_nil(shell) -> {:error, :shell_unavailable}
      not File.regular?(shell) -> {:error, :shell_unavailable}
      true -> {:ok, [shell | default_shell_args(shell)]}
    end
  end

  defp default_shell_args(shell) do
    case shell |> Path.basename() |> String.downcase() do
      name when name in ["bash", "fish", "zsh", "sh"] -> ["-i"]
      _ -> []
    end
  end

  defp helper_path(opts) do
    path =
      Keyword.get(opts, :helper_path) ||
        Application.get_env(:sigma_coding, :terminal_helper_path) || packaged_helper_path()

    if is_binary(path), do: {:ok, Path.expand(path)}, else: {:error, :backend_unavailable}
  end

  defp packaged_helper_path do
    case :code.priv_dir(:sigma_agent) do
      path when is_list(path) -> Path.join(List.to_string(path), "native/sigma-terminal-helper")
      {:error, _reason} -> nil
    end
  end

  defp executable(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, mode: mode}} when Bitwise.band(mode, 0o111) != 0 -> :ok
      _ -> {:error, :backend_unavailable}
    end
  end

  defp supported_platform do
    case :os.type() do
      {:unix, platform} when platform in [:darwin, :linux] -> :ok
      _ -> {:error, :unsupported_platform}
    end
  end

  defp valid_directory(path) do
    if File.dir?(path), do: :ok, else: {:error, :invalid_working_directory}
  end

  defp valid_dimensions(columns, rows)
       when is_integer(columns) and columns >= @min_columns and columns <= @max_columns and
              is_integer(rows) and rows >= @min_rows and rows <= @max_rows,
       do: :ok

  defp valid_dimensions(_columns, _rows), do: {:error, :invalid_dimensions}

  defp input_error(:starting), do: :not_started
  defp input_error(_phase), do: :input_revoked

  defp safe_close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
